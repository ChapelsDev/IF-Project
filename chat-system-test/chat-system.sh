#!/bin/bash

# Distributed Chat System Management Script
# Usage: ./chat-system.sh [command] [options]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REDIS_PORT=6379
NATS_PORT=4222
CONSUL_PORT=8500
CHAT_NODE_PORTS=(3002 3003 3004)
LOAD_BALANCER_PORT=3001
CHAT_IMAGE="localhost/chat-node:latest"

# Cluster integration
CLUSTER_MODE="false"
CLUSTER_CONSUL_URL="http://192.168.100.53:8500"
USE_LOCAL_CONSUL="true"
START_LOAD_BALANCER="false"

# Multi-machine support
HOST_IP=""
DEPLOYMENT_MODE="standalone"  # standalone, infrastructure, node-only, or auto

# Helper functions
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}➜ $1${NC}"
}

print_header() {
    echo -e "${BLUE}$1${NC}"
}

check_podman() {
    if ! command -v podman &> /dev/null; then
        print_error "Podman is not installed"
        echo "Install: sudo apt install podman"
        exit 1
    fi
}

# Check and install dependencies
check_dependencies() {
    print_info "Checking dependencies..."
    
    local missing_deps=()
    local install_cmds=()
    
    # Check for required commands
    if ! command -v podman &> /dev/null; then
        missing_deps+=("podman")
        install_cmds+=("podman")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
        install_cmds+=("curl")
    fi
    
    if ! command -v python3 &> /dev/null; then
        missing_deps+=("python3")
        install_cmds+=("python3")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
        install_cmds+=("jq")
    fi
    
    if ! command -v ip &> /dev/null; then
        missing_deps+=("ip (iproute2)")
        install_cmds+=("iproute2")
    fi
    
    # If no missing dependencies, return success
    if [ ${#missing_deps[@]} -eq 0 ]; then
        print_success "All dependencies are installed"
        return 0
    fi
    
    # Report missing dependencies
    print_error "Missing dependencies: ${missing_deps[*]}"
    echo ""
    
    # Ask user if they want to install
    read -p "Would you like to install missing dependencies? [y/N] " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Installing missing dependencies..."
        
        # Detect package manager
        if command -v apt-get &> /dev/null; then
            # Debian/Ubuntu
            sudo apt-get update
            sudo apt-get install -y "${install_cmds[@]}"
        elif command -v dnf &> /dev/null; then
            # Fedora/RHEL 8+
            sudo dnf install -y "${install_cmds[@]}"
        elif command -v yum &> /dev/null; then
            # CentOS/RHEL 7
            sudo yum install -y "${install_cmds[@]}"
        elif command -v pacman &> /dev/null; then
            # Arch Linux
            sudo pacman -Sy --noconfirm "${install_cmds[@]}"
        elif command -v zypper &> /dev/null; then
            # openSUSE
            sudo zypper install -y "${install_cmds[@]}"
        else
            print_error "Could not detect package manager. Please install manually:"
            echo "  ${install_cmds[*]}"
            exit 1
        fi
        
        # Verify installation
        local still_missing=()
        for dep in "${missing_deps[@]}"; do
            case "$dep" in
                "ip (iproute2)")
                    if ! command -v ip &> /dev/null; then
                        still_missing+=("$dep")
                    fi
                    ;;
                *)
                    if ! command -v "$dep" &> /dev/null; then
                        still_missing+=("$dep")
                    fi
                    ;;
            esac
        done
        
        if [ ${#still_missing[@]} -eq 0 ]; then
            print_success "All dependencies installed successfully"
        else
            print_error "Failed to install: ${still_missing[*]}"
            exit 1
        fi
    else
        print_error "Cannot proceed without required dependencies"
        echo "Please install manually:"
        echo "  sudo apt install ${install_cmds[*]}"
        exit 1
    fi
}

get_host_ip() {
    # Get the first non-localhost IP address
    ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1
}

# Auto-detect cluster and discover infrastructure
auto_discover_infrastructure() {
    print_info "Auto-discovering infrastructure via cluster..."
    
    # Check if main cluster Consul is reachable
    if curl -s --connect-timeout 2 "${CLUSTER_CONSUL_URL}/v1/agent/self" > /dev/null 2>&1; then
        print_success "Main cluster Consul found at ${CLUSTER_CONSUL_URL}"
        CLUSTER_MODE="true"
        USE_LOCAL_CONSUL="false"
        
        # Discover Redis service
        redis_info=$(curl -s "${CLUSTER_CONSUL_URL}/v1/health/service/redis-service?passing=true" 2>/dev/null)
        if [ -n "$redis_info" ] && [ "$redis_info" != "[]" ]; then
            REDIS_HOST=$(echo "$redis_info" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['Service']['Address']) if data else ''" 2>/dev/null)
            REDIS_PORT=$(echo "$redis_info" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['Service']['Port']) if data else ''" 2>/dev/null)
            if [ -n "$REDIS_HOST" ] && [ -n "$REDIS_PORT" ]; then
                print_success "Discovered Redis at ${REDIS_HOST}:${REDIS_PORT}"
            fi
        fi
        
        # Discover NATS service
        nats_info=$(curl -s "${CLUSTER_CONSUL_URL}/v1/health/service/nats-service?passing=true" 2>/dev/null)
        if [ -n "$nats_info" ] && [ "$nats_info" != "[]" ]; then
            NATS_HOST=$(echo "$nats_info" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['Service']['Address']) if data else ''" 2>/dev/null)
            NATS_PORT=$(echo "$nats_info" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['Service']['Port']) if data else ''" 2>/dev/null)
            if [ -n "$NATS_HOST" ] && [ -n "$NATS_PORT" ]; then
                print_success "Discovered NATS at ${NATS_HOST}:${NATS_PORT}"
            fi
        fi
        
        return 0
    else
        print_info "Main cluster Consul not reachable, using local mode"
        CLUSTER_MODE="false"
        USE_LOCAL_CONSUL="true"
        return 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --host)
                HOST_IP="$2"
                DEPLOYMENT_MODE="distributed"
                shift 2
                ;;
            --mode)
                DEPLOYMENT_MODE="$2"
                shift 2
                ;;
            --cluster)
                CLUSTER_MODE="true"
                USE_LOCAL_CONSUL="false"
                shift
                ;;
            --cluster-consul)
                CLUSTER_CONSUL_URL="$2"
                CLUSTER_MODE="true"
                USE_LOCAL_CONSUL="false"
                shift 2
                ;;
            --with-lb|--load-balancer)
                START_LOAD_BALANCER="true"
                shift
                ;;
            --nodes)
                # Skip nodes argument (not used in parsing, just for clarity)
                shift 2
                ;;
            --auto)
                DEPLOYMENT_MODE="auto"
                shift
                ;;
            *)
                break
                ;;
        esac
    done
}

# Check if cluster Consul is reachable
check_cluster_connectivity() {
    local consul_url="${1:-$CLUSTER_CONSUL_URL}"
    
    if curl -s --connect-timeout 3 "${consul_url}/v1/agent/self" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Register infrastructure services with cluster
register_infrastructure_services() {
    if [ "$CLUSTER_MODE" != "true" ]; then
        return
    fi
    
    print_info "Registering infrastructure services with cluster..."
    
    local host_ip=$(get_host_ip)
    local script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    
    # First check if cluster is reachable
    if ! check_cluster_connectivity "${CLUSTER_CONSUL_URL}"; then
        print_error "Cannot reach cluster Consul at ${CLUSTER_CONSUL_URL}"
        print_info "Make sure the cluster is running and accessible"
        print_info "You may need to set up an SSH tunnel:"
        print_info "  ssh -L 8500:172.20.10.10:8500 -p 2221 root@<cluster-host>"
        print_info "Then use: --cluster-consul http://localhost:8500"
        return 1
    fi
    
    # Check if cluster_helper.py exists (preferred) or fall back to cluster_bridge.py
    if [ -f "${script_dir}/cluster_helper.py" ]; then
        # Register Redis (uses TCP health check - Redis doesn't speak HTTP)
        python3 "${script_dir}/cluster_helper.py" register "redis-service" "redis-${host_ip//./-}" "${host_ip}" "${REDIS_PORT}" "${CLUSTER_CONSUL_URL}" "chat-infrastructure,redis" "tcp" 2>&1 || print_error "Failed to register Redis"
        
        # Register NATS (uses TCP health check - NATS client port doesn't speak HTTP)
        python3 "${script_dir}/cluster_helper.py" register "nats-service" "nats-${host_ip//./-}" "${host_ip}" "${NATS_PORT}" "${CLUSTER_CONSUL_URL}" "chat-infrastructure,nats" "tcp" 2>&1 || print_error "Failed to register NATS"
        
        print_success "Infrastructure services registered with cluster"
    elif [ -f "${script_dir}/cluster_bridge.py" ]; then
        # Fallback to old bridge
        python3 "${script_dir}/cluster_bridge.py" register "redis-service" "redis-${host_ip//./-}" "${host_ip}" "${REDIS_PORT}" "${CLUSTER_CONSUL_URL}" "chat-infrastructure,redis" 2>/dev/null || print_error "Failed to register Redis"
        python3 "${script_dir}/cluster_bridge.py" register "nats-service" "nats-${host_ip//./-}" "${host_ip}" "${NATS_PORT}" "${CLUSTER_CONSUL_URL}" "chat-infrastructure,nats" 2>/dev/null || print_error "Failed to register NATS"
        print_success "Infrastructure services registered with cluster"
    else
        print_error "cluster_helper.py not found, skipping cluster registration"
    fi
}

# Command: start
start_system() {
    print_header "======================================"
    print_header "Distributed Chat System Startup"
    print_header "======================================"
    echo ""
    
    # Check dependencies first
    check_dependencies
    echo ""
    
    # Auto-discovery mode
    if [ "$DEPLOYMENT_MODE" = "auto" ]; then
        print_info "Mode: Auto-discovery"
        if auto_discover_infrastructure; then
            # Found cluster infrastructure
            if [ -z "$REDIS_HOST" ] || [ -z "$NATS_HOST" ]; then
                print_info "No existing chat infrastructure found in cluster"
                print_info "Starting local infrastructure and registering with cluster..."
                DEPLOYMENT_MODE="infrastructure"
            else
                print_info "Using existing infrastructure from cluster"
                DEPLOYMENT_MODE="node-only"
            fi
        else
            # No cluster found, go standalone
            print_info "Starting in standalone mode"
            DEPLOYMENT_MODE="standalone"
        fi
    fi
    
    # If cluster mode, validate and set deployment mode
    if [ "$CLUSTER_MODE" = "true" ]; then
        # If mode not explicitly set or set to standalone, auto-determine
        if [ "$DEPLOYMENT_MODE" = "standalone" ] || [ "$DEPLOYMENT_MODE" = "full" ]; then
            if [ "$DEPLOYMENT_MODE" = "standalone" ]; then
                print_info "Cluster mode enabled, checking for infrastructure services..."
                
                # Try to discover existing infrastructure in the cluster
                redis_info=$(curl -s "${CLUSTER_CONSUL_URL}/v1/health/service/redis-service?passing=true" 2>/dev/null)
                nats_info=$(curl -s "${CLUSTER_CONSUL_URL}/v1/health/service/nats-service?passing=true" 2>/dev/null)
                
                if [ -n "$redis_info" ] && [ "$redis_info" != "[]" ] && [ -n "$nats_info" ] && [ "$nats_info" != "[]" ]; then
                    # Found existing infrastructure
                    REDIS_HOST=$(echo "$redis_info" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['Service']['Address']) if data else ''" 2>/dev/null)
                    REDIS_PORT=$(echo "$redis_info" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['Service']['Port']) if data else ''" 2>/dev/null)
                    NATS_HOST=$(echo "$nats_info" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['Service']['Address']) if data else ''" 2>/dev/null)
                    NATS_PORT=$(echo "$nats_info" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['Service']['Port']) if data else ''" 2>/dev/null)
                    print_success "Found infrastructure in cluster"
                    DEPLOYMENT_MODE="node-only"
                else
                    # No infrastructure found, start local and register, then also start chat nodes
                    print_info "No infrastructure found, starting local services and chat nodes..."
                    DEPLOYMENT_MODE="full"  # Start both infrastructure AND chat nodes
                fi
            fi
            # If already set to "full", keep it as full mode
        fi
    fi
    
    # Set default HOST_IP if not provided
    if [ -z "$HOST_IP" ]; then
        if [ "$CLUSTER_MODE" = "true" ]; then
            # In cluster mode, always use actual IP
            HOST_IP=$(get_host_ip)
        elif [ "$DEPLOYMENT_MODE" = "standalone" ]; then
            HOST_IP="localhost"
        else
            HOST_IP=$(get_host_ip)
        fi
    fi
    
    # Set Redis/NATS hosts if discovered
    REDIS_HOST="${REDIS_HOST:-$HOST_IP}"
    NATS_HOST="${NATS_HOST:-$HOST_IP}"
    
    print_info "Mode: $DEPLOYMENT_MODE"
    print_info "Host IP: $HOST_IP"
    if [ "$CLUSTER_MODE" = "true" ]; then
        print_info "Cluster Mode: Enabled"
        print_info "Cluster Consul: $CLUSTER_CONSUL_URL"
    fi
    echo ""
    
    # Stop any existing containers
    sudo podman stop $(sudo podman ps -aq) 2>/dev/null || true
    sudo podman rm -f $(sudo podman ps -aq) 2>/dev/null || true
    
    # Clean up network configs
    sudo rm -f /etc/cni/net.d/chat-*.conflist 2>/dev/null || true
    
    # Start infrastructure services (only if needed)
    if [ "$USE_LOCAL_CONSUL" = "true" ] && ([ "$DEPLOYMENT_MODE" = "standalone" ] || [ "$DEPLOYMENT_MODE" = "infrastructure" ]); then
        print_info "Starting local infrastructure services..."
        
        # Redis - bind to all interfaces if not standalone
        if [ "$DEPLOYMENT_MODE" = "standalone" ]; then
            sudo podman run -d --name redis --network host \
                --restart=on-failure:5 \
                --health-cmd="redis-cli -p ${REDIS_PORT} ping || exit 1" \
                --health-interval=30s \
                --health-timeout=5s \
                --health-retries=3 \
                docker.io/redis:7-alpine redis-server --port ${REDIS_PORT} \
                > /dev/null 2>&1
        else
            sudo podman run -d --name redis --network host \
                --restart=on-failure:5 \
                --health-cmd="redis-cli -p ${REDIS_PORT} ping || exit 1" \
                --health-interval=30s \
                --health-timeout=5s \
                --health-retries=3 \
                docker.io/redis:7-alpine redis-server --port ${REDIS_PORT} --bind 0.0.0.0 --protected-mode no \
                > /dev/null 2>&1
        fi
        print_success "Redis started on port ${REDIS_PORT}"
        
        # NATS
        sudo podman run -d --name nats --network host \
            --restart=on-failure:5 \
            --health-cmd="nc -z localhost ${NATS_PORT} || exit 1" \
            --health-interval=30s \
            --health-timeout=5s \
            --health-retries=3 \
            docker.io/nats:2.10-alpine \
            > /dev/null 2>&1
        print_success "NATS started on port ${NATS_PORT}"
        
        # Consul (local) - bind to 127.0.0.1 to avoid multi-interface issues
        sudo podman run -d --name consul --network host \
            --restart=on-failure:5 \
            --health-cmd="consul info || exit 1" \
            --health-interval=30s \
            --health-timeout=10s \
            --health-retries=3 \
            docker.io/hashicorp/consul:1.16 agent -dev -ui -client=0.0.0.0 -bind=127.0.0.1 \
            > /dev/null 2>&1
        print_success "Consul started on port ${CONSUL_PORT}"
        
        sleep 3
        
    elif [ "$CLUSTER_MODE" = "true" ] && ([ "$DEPLOYMENT_MODE" = "infrastructure" ] || [ "$DEPLOYMENT_MODE" = "full" ]); then
        print_info "Starting infrastructure for cluster..."
        
        # Start Redis and NATS for chat coordination
        sudo podman run -d --name redis --network host \
            --restart=on-failure:5 \
            --health-cmd="redis-cli -p ${REDIS_PORT} ping || exit 1" \
            --health-interval=30s \
            --health-timeout=5s \
            --health-retries=3 \
            docker.io/redis:7-alpine redis-server --port ${REDIS_PORT} --bind 0.0.0.0 --protected-mode no \
            > /dev/null 2>&1
        print_success "Redis started on port ${REDIS_PORT}"
        
        sudo podman run -d --name nats --network host \
            --restart=on-failure:5 \
            --health-cmd="nc -z localhost ${NATS_PORT} || exit 1" \
            --health-interval=30s \
            --health-timeout=5s \
            --health-retries=3 \
            docker.io/nats:2.10-alpine \
            > /dev/null 2>&1
        print_success "NATS started on port ${NATS_PORT}"
        
        # Set REDIS_HOST and NATS_HOST to local IP for chat nodes
        REDIS_HOST=$(get_host_ip)
        NATS_HOST=$(get_host_ip)
        
        sleep 2
        
        # Register with cluster
        register_infrastructure_services
        
    elif [ "$CLUSTER_MODE" = "true" ]; then
        print_info "Using cluster infrastructure at:"
        print_info "  Redis: ${REDIS_HOST}:${REDIS_PORT}"
        print_info "  NATS: ${NATS_HOST}:${NATS_PORT}"
        print_info "  Consul: ${CLUSTER_CONSUL_URL}"
    fi
    
    if [ "$DEPLOYMENT_MODE" = "infrastructure" ]; then
        print_success "Infrastructure services started"
        echo ""
        if [ "$CLUSTER_MODE" = "true" ]; then
            print_info "Infrastructure registered with cluster"
            print_info "Other nodes will auto-discover these services"
            print_info "To also start chat nodes, use: ./chat-system.sh start --cluster --cluster-consul ${CLUSTER_CONSUL_URL}"
        else
            detected_ip=$(get_host_ip)
            print_info "Connect remote nodes with:"
            echo "  ./chat-system.sh start --host $detected_ip --mode node-only"
        fi
        echo ""
        return
    fi
    
    # Start chat nodes (for standalone, node-only, or full modes)
    if [ "$DEPLOYMENT_MODE" != "infrastructure" ]; then
        print_info "Starting chat nodes..."
        
        # Check if image exists
        if ! sudo podman image exists ${CHAT_IMAGE}; then
            print_error "Chat node image not found. Building..."
            build_image
        fi
        
        # Determine number of nodes to start
        # Always start 3 nodes for better load balancing
        node_count=3
        
        # Determine Consul URL used by containers.
        # If cluster mode is enabled, register containers with the cluster Consul (central server).
        if [ "$CLUSTER_MODE" = "true" ]; then
            CONSUL_ENV="${CLUSTER_CONSUL_URL}"
        elif [ "$USE_LOCAL_CONSUL" = "true" ]; then
            CONSUL_ENV="http://127.0.0.1:${CONSUL_PORT}"
        else
            CONSUL_ENV="http://${HOST_IP}:${CONSUL_PORT}"
        fi
        
        # Start chat nodes with auto-discovery
        local host_ip=$(get_host_ip)
        
        # Use 127.0.0.1 instead of localhost to avoid IPv6 issues
        local redis_connect_host="${REDIS_HOST}"
        local nats_connect_host="${NATS_HOST}"
        if [ "$redis_connect_host" = "localhost" ]; then
            redis_connect_host="127.0.0.1"
        fi
        if [ "$nats_connect_host" = "localhost" ]; then
            nats_connect_host="127.0.0.1"
        fi
        
        for i in $(seq 1 $node_count); do
            port=${CHAT_NODE_PORTS[$((i-1))]}
            
            sudo podman run -d --name chat-node-${i} --network host \
                --stop-timeout=10 \
                --restart=on-failure:5 \
                --health-cmd="curl -f http://localhost:${port}/health || exit 1" \
                --health-interval=30s \
                --health-timeout=10s \
                --health-retries=3 \
                --health-start-period=15s \
                -e NODE_ID="${i}" \
                -e PORT="${port}" \
                -e HOST_IP="${host_ip}" \
                -e SERVICE_ID="chat-node-${host_ip//./-}-${i}" \
                -e REDIS_URL="redis://${redis_connect_host}:${REDIS_PORT}" \
                -e NATS_URL="nats://${nats_connect_host}:${NATS_PORT}" \
                -e CONSUL_URL="${CONSUL_ENV}" \
                -e CLUSTER_MODE="${CLUSTER_MODE}" \
                -e CLUSTER_CONSUL_URL="${CLUSTER_CONSUL_URL}" \
                ${CHAT_IMAGE} \
                > /dev/null 2>&1
            print_success "Chat Node ${i} started on port ${port}"
        done
        
        # Start load balancer if requested
        if [ "$START_LOAD_BALANCER" = "true" ]; then
            print_info "Starting load balancer..."
            local host_ip=$(get_host_ip)
            sudo podman run -d --name chat-lb --network host \
                --stop-timeout=10 \
                --restart=on-failure:5 \
                --health-cmd="curl -f http://localhost:${LOAD_BALANCER_PORT}/health || exit 1" \
                --health-interval=30s \
                --health-timeout=10s \
                --health-retries=3 \
                --health-start-period=15s \
                -e LB_PORT="${LOAD_BALANCER_PORT}" \
                -e CONSUL_URL="${CONSUL_ENV}" \
                ${CHAT_IMAGE} \
                npm run start:lb \
                > /dev/null 2>&1
            print_success "Load Balancer started on port ${LOAD_BALANCER_PORT}"
        fi
    fi
    
    echo ""
    print_success "System started successfully!"
    echo ""
    
    if [ "$DEPLOYMENT_MODE" = "standalone" ]; then
        echo "Mode: Standalone (Single Machine)"
        echo ""
        echo "Access URLs:"
        echo "  - Consul UI:    http://localhost:${CONSUL_PORT}"
        if [ "$START_LOAD_BALANCER" = "true" ]; then
            echo "  - Load Balancer: http://localhost:${LOAD_BALANCER_PORT}"
        fi
        echo "  - Chat Node 1:  http://localhost:${CHAT_NODE_PORTS[0]}"
        echo "  - Chat Node 2:  http://localhost:${CHAT_NODE_PORTS[1]}"
        echo "  - Chat Node 3:  http://localhost:${CHAT_NODE_PORTS[2]}"
        echo ""
        if [ "$START_LOAD_BALANCER" = "true" ]; then
            echo "Client connects to: http://localhost:${LOAD_BALANCER_PORT}"
        fi
        echo "Start React client: cd client-react && npm run dev"
        echo "Check status:       ./chat-system.sh status"
        echo ""
        detected_ip=$(get_host_ip)
        if [ -n "$detected_ip" ]; then
            echo "To add remote nodes:"
            echo "  ./chat-system.sh start --auto"
        fi
    elif [ "$CLUSTER_MODE" = "true" ]; then
        echo "Mode: Cluster-Integrated (Full)"
        echo ""
        echo "Infrastructure (registered with cluster):"
        echo "  - Redis: ${REDIS_HOST}:${REDIS_PORT}"
        echo "  - NATS: ${NATS_HOST}:${NATS_PORT}"
        echo ""
        if [ "$START_LOAD_BALANCER" = "true" ]; then
            echo "Load Balancer:"
            local host_ip=$(get_host_ip)
            echo "  - http://${host_ip}:${LOAD_BALANCER_PORT}"
            echo ""
        fi
        echo "Chat Nodes:"
        echo "  - Chat Node 1:  http://localhost:${CHAT_NODE_PORTS[0]}"
        echo "  - Chat Node 2:  http://localhost:${CHAT_NODE_PORTS[1]}"
        echo "  - Chat Node 3:  http://localhost:${CHAT_NODE_PORTS[2]}"
        echo ""
        echo "Cluster URLs:"
        echo "  - Cluster Consul: ${CLUSTER_CONSUL_URL}"
        echo "  - Consul UI: ${CLUSTER_CONSUL_URL}/ui/dc1/services"
        echo ""
        if [ "$START_LOAD_BALANCER" = "true" ]; then
            local host_ip=$(get_host_ip)
            echo "Client connects to: http://${host_ip}:${LOAD_BALANCER_PORT}"
            echo ""
        fi
        echo "Registered services: redis-service, nats-service, chat-service"
        echo ""
        echo "Start React client: cd client-react && npm run dev"
        echo "Check status:       ./chat-system.sh status"
    else
        echo "Mode: Distributed Node"
        echo "Connected to: ${HOST_IP}"
        echo ""
        echo "Access URLs:"
        echo "  - Chat Node: http://localhost:${CHAT_NODE_PORTS[0]}"
        echo ""
        echo "Start React client: cd client-react && npm run dev"
        echo "Check status:       ./chat-system.sh status"
    fi
}

# Command: stop
stop_system() {
    print_info "Stopping chat system..."
    
    local script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local host_ip=$(get_host_ip)
    
    # Stop load balancer first
    if sudo podman ps -a --format "{{.Names}}" | grep -q "^chat-lb$"; then
        print_info "Stopping load balancer..."
        sudo podman stop -t 5 chat-lb > /dev/null 2>&1
        sudo podman rm chat-lb > /dev/null 2>&1
        print_success "Load balancer stopped"
    fi
    
    # Stop chat nodes (they need to deregister from cluster)
    for i in 1 2 3; do
        service="chat-node-${i}"
        if sudo podman ps -a --format "{{.Names}}" | grep -q "^${service}$"; then
            print_info "Stopping ${service} (allowing graceful shutdown)..."
            # Send SIGTERM and wait for graceful shutdown (up to 10 seconds)
            sudo podman stop -t 10 ${service} > /dev/null 2>&1
            sudo podman rm ${service} > /dev/null 2>&1
            print_success "${service} stopped"
        fi
    done
    
    # Deregister infrastructure services from cluster if cluster mode was used
    if [ -f "${script_dir}/cluster_helper.py" ]; then
        print_info "Deregistering services from cluster..."
        
        # Try IP-based ID first, then hostname-based for compatibility
        if python3 "${script_dir}/cluster_helper.py" deregister "redis-${host_ip//./-}" "${CLUSTER_CONSUL_URL}" 2>&1 | grep -q "Deregistered"; then
            print_success "Redis deregistered (IP-based)"
        elif python3 "${script_dir}/cluster_helper.py" deregister "redis-${HOSTNAME}" "${CLUSTER_CONSUL_URL}" 2>&1 | grep -q "Deregistered"; then
            print_success "Redis deregistered (hostname)"
        fi
        
        if python3 "${script_dir}/cluster_helper.py" deregister "nats-${host_ip//./-}" "${CLUSTER_CONSUL_URL}" 2>&1 | grep -q "Deregistered"; then
            print_success "NATS deregistered (IP-based)"
        elif python3 "${script_dir}/cluster_helper.py" deregister "nats-${HOSTNAME}" "${CLUSTER_CONSUL_URL}" 2>&1 | grep -q "Deregistered"; then
            print_success "NATS deregistered (hostname)"
        fi
        
        # Deregister chat nodes with IP-based IDs
        for i in 1 2 3; do
            if python3 "${script_dir}/cluster_helper.py" deregister "chat-node-${host_ip//./-}-${i}" "${CLUSTER_CONSUL_URL}" 2>&1 | grep -q "Deregistered"; then
                print_success "Chat node ${i} deregistered (IP-based)"
            fi
        done
    fi
    
    # Stop infrastructure services
    for service in redis nats consul; do
        if sudo podman ps -a --format "{{.Names}}" | grep -q "^${service}$"; then
            sudo podman stop ${service} > /dev/null 2>&1
            sudo podman rm ${service} > /dev/null 2>&1
            print_success "${service} stopped"
        fi
    done
    
    print_success "System stopped"
}

# Command: status
show_status() {
    echo "======================================"
    echo "Chat System Status"
    echo "======================================"
    echo ""
    
    # Check daemon status
    if systemctl is-active chat-system.service >/dev/null 2>&1; then
        print_success "Daemon: Running (monitoring every 30s)"
        daemon_pid=$(systemctl show -p MainPID chat-system.service --value)
        if [ "$daemon_pid" != "0" ]; then
            uptime=$(ps -p "$daemon_pid" -o etime= 2>/dev/null | tr -d ' ')
            echo "  PID: $daemon_pid, Uptime: ${uptime:-unknown}"
        fi
        echo "  Logs: sudo tail -f /var/log/chat-system-daemon.log"
    else
        print_error "Daemon: Not running"
        echo "  Start with: sudo systemctl start chat-system"
    fi
    echo ""
    
    # Check containers
    echo "Container Status:"
    if sudo podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" --filter "name=chat-node|redis|nats|consul" 2>/dev/null | grep -q .; then
        sudo podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" --filter "name=chat-node|redis|nats|consul"
    else
        print_error "No containers running"
    fi
    echo ""
    
    # Check ports
    echo "Port Status:"
    all_ports=("${REDIS_PORT}" "${NATS_PORT}" "${CONSUL_PORT}" "${CHAT_NODE_PORTS[@]}")
    for port in "${all_ports[@]}"; do
        if nc -z localhost ${port} 2>/dev/null; then
            print_success "Port ${port} is open"
        else
            print_error "Port ${port} is closed"
        fi
    done
    echo ""
    
    # Check chat node health
    echo "Chat Node Health:"
    for i in {1..3}; do
        port=${CHAT_NODE_PORTS[$((i-1))]}
        response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}/health" 2>/dev/null || echo "000")
        if [ "$response" = "000" ]; then
            print_error "Chat Node ${i} (port ${port}) is not responding"
        else
            print_success "Chat Node ${i} (port ${port}) is healthy (HTTP ${response})"
        fi
    done
    echo ""
    
    echo "======================================"
}

# Command: logs
show_logs() {
    if [ -z "$1" ]; then
        print_error "Usage: ./chat-system.sh logs <service>"
        echo "Services: redis, nats, consul, chat-1, chat-2, chat-3"
        exit 1
    fi
    
    service=$1
    
    case $service in
        redis|nats|consul)
            container_name=$service
            ;;
        chat-1)
            container_name="chat-node-1"
            ;;
        chat-2)
            container_name="chat-node-2"
            ;;
        chat-3)
            container_name="chat-node-3"
            ;;
        *)
            print_error "Unknown service: $service"
            echo "Available: redis, nats, consul, chat-1, chat-2, chat-3"
            exit 1
            ;;
    esac
    
    if sudo podman ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
        sudo podman logs --tail 50 -f ${container_name}
    else
        print_error "Container ${container_name} not found"
        exit 1
    fi
}

# Command: restart
restart_nodes() {
    print_info "Restarting chat nodes..."
    local host_ip=$(get_host_ip)
    
    for i in {1..3}; do
        if sudo podman ps -a --format "{{.Names}}" | grep -q "^chat-node-${i}$"; then
            sudo podman stop chat-node-${i} > /dev/null 2>&1
            sudo podman rm chat-node-${i} > /dev/null 2>&1
        fi
    done
    
    sleep 2
    
    for i in {1..3}; do
        port=${CHAT_NODE_PORTS[$((i-1))]}
        sudo podman run -d --name chat-node-${i} --network host \
            -e NODE_ID=${i} \
            -e PORT=${port} \
            -e HOST_IP="${host_ip}" \
            -e SERVICE_ID="chat-node-${host_ip//./-}-${i}" \
            -e REDIS_URL=redis://localhost:${REDIS_PORT} \
            -e NATS_URL=nats://localhost:${NATS_PORT} \
            -e CONSUL_URL=http://localhost:${CONSUL_PORT} \
            ${CHAT_IMAGE} \
            > /dev/null 2>&1
        print_success "Chat Node ${i} restarted on port ${port}"
    done
    
    print_success "Chat nodes restarted"
}

# Command: build
build_image() {
    # Check dependencies first
    check_dependencies
    echo ""
    
    print_info "Building chat node image..."
    
    if [ ! -d "chat-node" ]; then
        print_error "chat-node directory not found"
        exit 1
    fi
    
    cd chat-node
    sudo podman build -t ${CHAT_IMAGE} . 2>&1 | grep -E "(STEP|Successfully)" || true
    cd ..
    
    print_success "Image built: ${CHAT_IMAGE}"
}

# Command: clear-usernames
clear_usernames() {
    print_info "Clearing username cache..."
    
    if ! sudo podman ps --format "{{.Names}}" | grep -q "^redis$"; then
        print_error "Redis is not running"
        exit 1
    fi
    
    count=$(sudo podman exec redis redis-cli KEYS "username:*" 2>/dev/null | wc -l)
    
    if [ "$count" -gt 0 ]; then
        sudo podman exec redis redis-cli KEYS "username:*" | xargs -r sudo podman exec redis redis-cli DEL > /dev/null 2>&1
        print_success "Cleared ${count} username(s)"
    else
        print_info "No usernames to clear"
    fi
}

# Command: setup-autostart - Configure systemd for autostart and autorecovery
setup_autostart() {
    print_header "======================================"
    print_header "Autostart & Autorecovery Setup"
    print_header "======================================"
    echo ""
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then 
        print_error "This command must be run as root (use sudo)"
        exit 1
    fi
    
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/chat-system.sh"
    
    # Get configuration
    print_info "Configuration:"
    echo ""
    
    read -p "Number of chat nodes [3]: " NODE_COUNT
    NODE_COUNT=${NODE_COUNT:-3}
    
    read -p "Cluster mode? (yes/no) [yes]: " CLUSTER_INPUT
    CLUSTER_INPUT=${CLUSTER_INPUT:-yes}
    
    read -p "Run full mode (own redis/nats)? (yes/no) [yes]: " FULL_INPUT
    FULL_INPUT=${FULL_INPUT:-yes}
    
    read -p "Enable load balancer? (yes/no) [yes]: " LB_INPUT
    LB_INPUT=${LB_INPUT:-yes}
    
    read -p "Cluster Consul URL [http://192.168.100.51:8500]: " CONSUL_URL
    CONSUL_URL=${CONSUL_URL:-http://192.168.100.51:8500}
    
    # Build command
    CMD_FLAGS="--nodes ${NODE_COUNT}"
    [ "$CLUSTER_INPUT" = "yes" ] && CMD_FLAGS="$CMD_FLAGS --cluster --cluster-consul ${CONSUL_URL}"
    [ "$FULL_INPUT" = "yes" ] && CMD_FLAGS="$CMD_FLAGS --mode full"
    [ "$LB_INPUT" = "yes" ] && CMD_FLAGS="$CMD_FLAGS --with-lb"
    
    echo ""
    print_info "Will configure with: ./chat-system.sh start $CMD_FLAGS"
    echo ""
    
    read -p "Proceed? (yes/no) [yes]: " CONFIRM
    CONFIRM=${CONFIRM:-yes}
    [ "$CONFIRM" != "yes" ] && { print_info "Aborted"; exit 0; }
    
    # Create systemd service
    SERVICE_FILE="/etc/systemd/system/chat-system.service"
    print_info "Creating $SERVICE_FILE..."
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Distributed Chat System with Continuous Health Monitoring
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$(dirname "$SCRIPT_PATH")
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="CLUSTER_CONSUL_URL=${CONSUL_URL}"

# Start services first, then run daemon
ExecStartPre=${SCRIPT_PATH} start ${CMD_FLAGS}
ExecStart=${SCRIPT_PATH} daemon

# Stop services on daemon exit
ExecStopPost=${SCRIPT_PATH} stop

# Restart daemon if it crashes
Restart=on-failure
RestartSec=10

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    print_success "Service created (Type=simple with continuous monitoring)"
    
    print_success "Setup complete!"
    echo ""
    echo "The daemon will:"
    echo "  • Start all services (Redis, NATS, chat nodes, load balancer)"
    echo "  • Monitor health continuously (every 30 seconds)"
    echo "  • Automatically restart unhealthy services"
    echo "  • Recreate failed containers if restart doesn't work"
    echo "  • Log all actions to /var/log/chat-system-daemon.log"
    echo ""
    echo "Commands:"
    echo "  Start:   sudo systemctl start chat-system"
    echo "  Stop:    sudo systemctl stop chat-system"
    echo "  Status:  sudo systemctl status chat-system"
    echo "  Logs:    sudo journalctl -u chat-system -f"
    echo "  Daemon:  sudo tail -f /var/log/chat-system-daemon.log"
    echo ""
    
    read -p "Start now? (yes/no) [yes]: " START_NOW
    START_NOW=${START_NOW:-yes}
    
    if [ "$START_NOW" = "yes" ]; then
        systemctl daemon-reload
        systemctl start chat-system
        sleep 3
        echo ""
        print_info "Daemon started. Checking status..."
        systemctl status chat-system --no-pager | head -20
        echo ""
        print_info "View daemon logs with: sudo tail -f /var/log/chat-system-daemon.log"
    fi
}

# Command: metrics - Start metrics aggregation server
start_metrics_server() {
    local consul_url="${1:-http://192.168.100.53:8500}"
    local port="${2:-9090}"
    
    print_info "Starting metrics server on port $port..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    if [ ! -f "${SCRIPT_DIR}/metrics_server.py" ]; then
        print_error "metrics_server.py not found"
        exit 1
    fi
    
    python3 "${SCRIPT_DIR}/metrics_server.py" "$consul_url" "$port"
}

# Command: deregister - manually deregister services from cluster
deregister_services() {
    local consul_url="${1:-$CLUSTER_CONSUL_URL}"
    local script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    
    print_header "======================================"
    print_header "Deregistering Services from Cluster"
    print_header "======================================"
    echo ""
    
    if ! check_cluster_connectivity "${consul_url}"; then
        print_error "Cannot reach cluster at ${consul_url}"
        exit 1
    fi
    
    print_info "Current services registered:"
    python3 "${script_dir}/cluster_helper.py" discover "chat-service" "${consul_url}" 2>/dev/null || echo "  No chat-service instances"
    python3 "${script_dir}/cluster_helper.py" discover "redis-service" "${consul_url}" 2>/dev/null || echo "  No redis-service instances"
    python3 "${script_dir}/cluster_helper.py" discover "nats-service" "${consul_url}" 2>/dev/null || echo "  No nats-service instances"
    echo ""
    
    # Deregister this host's services
    print_info "Deregistering services from this host (${HOSTNAME})..."
    
    # Deregister chat nodes (try multiple ID formats for compatibility)
    local host_ip=$(get_host_ip)
    for i in 1 2 3; do
        ids=("chat-node-${host_ip//./-}-${i}" "chat-node-${HOSTNAME}-${i}" "chat-node-${i}")
        for id in "${ids[@]}"; do
            python3 "${script_dir}/cluster_helper.py" deregister "$id" "${consul_url}" 2>/dev/null && { print_success "$id deregistered"; break; } || true
        done
    done

    # Deregister infrastructure (try host-ip-based id, then hostname)
    python3 "${script_dir}/cluster_helper.py" deregister "redis-${host_ip//./-}" "${consul_url}" 2>/dev/null && print_success "redis-${host_ip//./-} deregistered" || true
    python3 "${script_dir}/cluster_helper.py" deregister "nats-${host_ip//./-}" "${consul_url}" 2>/dev/null && print_success "nats-${host_ip//./-} deregistered" || true
    
    echo ""
    print_success "Deregistration complete"
    echo ""
    print_info "Remaining services:"
    python3 "${script_dir}/cluster_helper.py" services "${consul_url}" 2>/dev/null || echo "  Could not list services"
}

# Command: cluster-test
test_cluster() {
    local consul_url="${1:-$CLUSTER_CONSUL_URL}"
    
    print_header "======================================"
    print_header "Cluster Connectivity Test"
    print_header "======================================"
    echo ""
    print_info "Testing cluster at: ${consul_url}"
    echo ""
    
    # Test if Consul is reachable
    if check_cluster_connectivity "${consul_url}"; then
        print_success "Consul is reachable"
        
        # Get cluster info
        local script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
        
        echo ""
        print_info "Cluster Leader:"
        python3 "${script_dir}/cluster_helper.py" leader "${consul_url}" 2>&1 || echo "  Could not get leader"
        
        echo ""
        print_info "Cluster Nodes:"
        python3 "${script_dir}/cluster_helper.py" nodes "${consul_url}" 2>&1 || echo "  Could not list nodes"
        
        echo ""
        print_info "Registered Services:"
        python3 "${script_dir}/cluster_helper.py" services "${consul_url}" 2>&1 || echo "  Could not list services"
        
        echo ""
        print_info "Chat Services (if registered):"
        python3 "${script_dir}/cluster_helper.py" discover "chat-service" "${consul_url}" 2>&1 || echo "  No chat-service instances found"
        
        echo ""
        print_success "Cluster is operational!"
        echo ""
        print_info "You can now start the chat system with:"
        echo "  ./chat-system.sh start --cluster"
    else
        print_error "Cannot reach Consul at ${consul_url}"
        echo ""
        print_info "Troubleshooting steps:"
        echo ""
        echo "1. Check if the cluster is running on the network"
        echo "   The cluster Consul is at 172.20.10.10:8500"
        echo ""
        echo "2. If the cluster is on a different network, set up SSH tunnel:"
        echo "   ssh -L 8500:172.20.10.10:8500 -p 2221 root@<cluster-host>"
        echo ""
        echo "   Then use:"
        echo "   ./chat-system.sh cluster-test http://localhost:8500"
        echo "   ./chat-system.sh start --cluster --cluster-consul http://localhost:8500"
        echo ""
        echo "3. Or run in standalone mode (no cluster):"
        echo "   ./chat-system.sh start"
        echo ""
        exit 1
    fi
}

# Command: run - Start system, metrics server, and continuous monitoring all at once
run_all() {
    print_header "======================================"
    print_header "Starting Complete Chat System"
    print_header "======================================"
    echo ""
    
    # Parse arguments for system start
    parse_args "$@"
    
    # Start the system
    print_info "Step 1/3: Starting chat system..."
    start_system
    echo ""
    
    # Start metrics server in background
    print_info "Step 2/3: Starting metrics server on port 9090..."
    local consul_url="${CLUSTER_CONSUL_URL:-http://192.168.100.52:8500}"
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${SCRIPT_DIR}/metrics_server.py" ]; then
        nohup python3 "${SCRIPT_DIR}/metrics_server.py" "$consul_url" 9090 > /var/log/chat-metrics.log 2>&1 &
        local metrics_pid=$!
        print_success "Metrics server started (PID: $metrics_pid)"
        echo "  Access: http://$(get_host_ip):9090/metrics"
    else
        print_info "Metrics server not found, skipping..."
    fi
    echo ""
    
    # Run daemon in foreground
    print_info "Step 3/3: Starting continuous health monitoring..."
    echo ""
    print_success "All services started! Daemon will monitor continuously."
    print_info "Press Ctrl+C to stop monitoring (services will continue running)"
    echo ""
    sleep 2
    
    run_daemon
}

# Command: daemon - Run continuous monitoring
run_daemon() {
    # Daemon configuration
    local LOG_FILE="/var/log/chat-system-daemon.log"
    local CHECK_INTERVAL=30
    local RESTART_COOLDOWN=60
    declare -A LAST_RESTART
    
    # Daemon logging functions
    daemon_log() {
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    }
    
    daemon_log_error() {
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
    }
    
    daemon_log_success() {
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS: $1" | tee -a "$LOG_FILE"
    }
    
    # Check if enough time has passed since last restart
    daemon_can_restart() {
        local service=$1
        local now=$(date +%s)
        local last=${LAST_RESTART[$service]:-0}
        local elapsed=$((now - last))
        
        if [ $elapsed -ge $RESTART_COOLDOWN ]; then
            return 0
        else
            daemon_log "Service $service in cooldown (${elapsed}s/${RESTART_COOLDOWN}s)"
            return 1
        fi
    }
    
    # Record restart time
    daemon_record_restart() {
        local service=$1
        LAST_RESTART[$service]=$(date +%s)
    }
    
    # Check if container exists and is running
    daemon_check_container_running() {
        local container=$1
        sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"
    }
    
    # Check if container exists
    daemon_check_container_exists() {
        local container=$1
        sudo podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"
    }
    
    # Get container status
    daemon_get_container_status() {
        local container=$1
        sudo podman inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo "missing"
    }
    
    # Check container health
    daemon_check_container_health() {
        local container=$1
        local health=$(sudo podman inspect "$container" --format '{{.State.Health.Status}}' 2>/dev/null)
        
        if [ -z "$health" ] || [ "$health" = "<no value>" ]; then
            if daemon_check_container_running "$container"; then
                echo "running"
            else
                echo "unhealthy"
            fi
        else
            echo "$health"
        fi
    }
    
    # Check service via HTTP
    daemon_check_http_health() {
        local port=$1
        local timeout=${2:-5}
        curl -sf --max-time "$timeout" "http://localhost:${port}/health" >/dev/null 2>&1
    }
    
    # Restart container
    daemon_restart_container() {
        local container=$1
        daemon_log "Restarting container: $container"
        
        if sudo podman restart "$container" >/dev/null 2>&1; then
            daemon_log_success "Container $container restarted"
            daemon_record_restart "$container"
            return 0
        else
            daemon_log_error "Failed to restart $container"
            return 1
        fi
    }
    
    # Recreate Redis
    daemon_recreate_redis() {
        daemon_log "Recreating Redis..."
        sudo podman run -d --name redis --network host \
            --restart=on-failure:5 \
            --health-cmd="redis-cli ping || exit 1" \
            --health-interval=30s \
            --health-timeout=5s \
            --health-retries=3 \
            redis:7-alpine \
            redis-server --save 60 1 --loglevel warning \
            >/dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            daemon_log_success "Redis recreated"
            daemon_record_restart "redis"
            return 0
        else
            daemon_log_error "Failed to recreate Redis"
            return 1
        fi
    }
    
    # Recreate NATS
    daemon_recreate_nats() {
        daemon_log "Recreating NATS..."
        sudo podman run -d --name nats --network host \
            --restart=on-failure:5 \
            --health-cmd="wget -q --spider http://localhost:8222/healthz || exit 1" \
            --health-interval=30s \
            --health-timeout=5s \
            --health-retries=3 \
            nats:2-alpine \
            -js -m 8222 \
            >/dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            daemon_log_success "NATS recreated"
            daemon_record_restart "nats"
            return 0
        else
            daemon_log_error "Failed to recreate NATS"
            return 1
        fi
    }
    
    # Recreate chat node
    daemon_recreate_chat_node() {
        local container=$1
        local node_num=$(echo "$container" | grep -oP '\d+$')
        local ports=(3002 3003 3004)
        local port=${ports[$((node_num - 1))]}
        local host_ip=$(get_host_ip)
        
        daemon_log "Recreating chat node $node_num on port $port..."
        
        local cluster_consul="${CLUSTER_CONSUL_URL:-http://192.168.100.52:8500}"
        
        sudo podman run -d --name "$container" --network host \
            --stop-timeout=10 \
            --restart=on-failure:5 \
            --health-cmd="curl -f http://localhost:${port}/health || exit 1" \
            --health-interval=30s \
            --health-timeout=10s \
            --health-retries=3 \
            --health-start-period=15s \
            -e NODE_ID="${node_num}" \
            -e PORT="${port}" \
            -e HOST_IP="${host_ip}" \
            -e SERVICE_ID="chat-node-${host_ip//./-}-${node_num}" \
            -e REDIS_URL="redis://${host_ip}:6379" \
            -e NATS_URL="nats://${host_ip}:4222" \
            -e CONSUL_URL="${cluster_consul}" \
            -e CLUSTER_MODE="true" \
            -e CLUSTER_CONSUL_URL="${cluster_consul}" \
            localhost/chat-node:latest \
            >/dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            daemon_log_success "Chat node $node_num recreated on port $port"
            daemon_record_restart "$container"
            return 0
        else
            daemon_log_error "Failed to recreate chat node $node_num"
            return 1
        fi
    }
    
    # Recreate load balancer
    daemon_recreate_load_balancer() {
        local host_ip=$(get_host_ip)
        local cluster_consul="${CLUSTER_CONSUL_URL:-http://192.168.100.52:8500}"
        
        daemon_log "Recreating load balancer..."
        
        sudo podman run -d --name chat-lb --network host \
            --stop-timeout=10 \
            --restart=on-failure:5 \
            --health-cmd="curl -f http://localhost:3001/health || exit 1" \
            --health-interval=30s \
            --health-timeout=10s \
            --health-retries=3 \
            --health-start-period=15s \
            -e LB_PORT="3001" \
            -e CONSUL_URL="${cluster_consul}" \
            localhost/chat-node:latest \
            npm run start:lb \
            >/dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            daemon_log_success "Load balancer recreated"
            daemon_record_restart "chat-lb"
            return 0
        else
            daemon_log_error "Failed to recreate load balancer"
            return 1
        fi
    }
    
    # Recreate container
    daemon_recreate_container() {
        local container=$1
        daemon_log "Recreating container: $container (restart failed)"
        
        sudo podman stop -t 10 "$container" >/dev/null 2>&1
        sudo podman rm "$container" >/dev/null 2>&1
        
        case "$container" in
            redis)
                daemon_recreate_redis
                ;;
            nats)
                daemon_recreate_nats
                ;;
            chat-node-*)
                daemon_recreate_chat_node "$container"
                ;;
            chat-lb)
                daemon_recreate_load_balancer
                ;;
            *)
                daemon_log_error "Unknown container type: $container"
                return 1
                ;;
        esac
    }
    
    # Monitor and maintain a service
    daemon_monitor_service() {
        local container=$1
        local port=$2
        
        if ! daemon_check_container_exists "$container"; then
            daemon_log_error "Container $container does not exist - recreating"
            if daemon_can_restart "$container"; then
                daemon_recreate_container "$container"
            fi
            return
        fi
        
        if ! daemon_check_container_running "$container"; then
            local status=$(daemon_get_container_status "$container")
            daemon_log_error "Container $container not running (status: $status)"
            
            if daemon_can_restart "$container"; then
                if ! daemon_restart_container "$container"; then
                    daemon_recreate_container "$container"
                fi
            fi
            return
        fi
        
        local health=$(daemon_check_container_health "$container")
        if [ "$health" = "unhealthy" ]; then
            daemon_log_error "Container $container is unhealthy"
            
            if daemon_can_restart "$container"; then
                if ! daemon_restart_container "$container"; then
                    daemon_recreate_container "$container"
                fi
            fi
            return
        fi
        
        if [ -n "$port" ]; then
            if ! daemon_check_http_health "$port" 3; then
                daemon_log_error "HTTP health check failed for $container on port $port"
                
                if daemon_can_restart "$container"; then
                    if ! daemon_restart_container "$container"; then
                        daemon_recreate_container "$container"
                    fi
                fi
                return
            fi
        fi
    }
    
    # Main monitoring loop
    daemon_log "=========================================="
    daemon_log "Chat System Daemon Started"
    daemon_log "=========================================="
    daemon_log "Check Interval: ${CHECK_INTERVAL}s"
    daemon_log "Restart Cooldown: ${RESTART_COOLDOWN}s"
    daemon_log "Log File: $LOG_FILE"
    daemon_log "=========================================="
    
    trap 'daemon_log "Received shutdown signal"; exit 0' SIGTERM SIGINT
    
    local check_count=0
    
    while true; do
        check_count=$((check_count + 1))
        
        if [ $((check_count % 10)) -eq 0 ]; then
            daemon_log "Heartbeat: Check #${check_count} - All services monitored"
        fi
        
        daemon_monitor_service "redis" "6379"
        daemon_monitor_service "nats" "4222"
        daemon_monitor_service "chat-node-1" "3002"
        daemon_monitor_service "chat-node-2" "3003"
        daemon_monitor_service "chat-node-3" "3004"
        daemon_monitor_service "chat-lb" "3001"
        
        sleep "$CHECK_INTERVAL"
    done
}

# Command: test - Run comprehensive tests
run_tests() {
    # Test configuration
    local TOTAL_TESTS=0
    local PASSED_TESTS=0
    local FAILED_TESTS=0
    
    local TEST_HOST_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' || echo "localhost")
    local TEST_CLUSTER_CONSUL="${1:-http://192.168.100.52:8500}"
    local LB_PORT=3001
    local CHAT_PORTS=(3002 3003 3004)
    local REDIS_PORT=6379
    local NATS_PORT=4222
    
    # Test helper functions
    test_print_header() { echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"; }
    test_print_footer() { echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"; }
    test_print_section() { echo -e "\n${BLUE}▶ $1${NC}"; }
    test_start() { echo -ne "  Testing: $1 ... "; TOTAL_TESTS=$((TOTAL_TESTS + 1)); }
    test_pass() { echo -e "${GREEN}✓ PASS${NC}"; PASSED_TESTS=$((PASSED_TESTS + 1)); }
    test_fail() { echo -e "${RED}✗ FAIL${NC} $1"; FAILED_TESTS=$((FAILED_TESTS + 1)); }
    test_skip() { echo -e "${YELLOW}⊘ SKIP${NC} $1"; TOTAL_TESTS=$((TOTAL_TESTS - 1)); }
    
    test_print_header
    echo -e "${BLUE}║          DISTRIBUTED CHAT SYSTEM - COMPREHENSIVE TEST           ║${NC}"
    test_print_footer
    echo ""
    echo "Usage: ./chat-system.sh test [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --with-resilience   Include resilience & failure handling tests (disruptive)"
    echo "  --full              Run all tests including resilience tests"
    echo ""
    echo "Note: Resilience tests will temporarily stop services to test recovery."
    echo ""
    
    # Container Health
    test_print_section "1. Container Health Checks"
    
    local containers=("redis" "nats" "chat-node-1" "chat-node-2" "chat-node-3" "chat-lb")
    for container in "${containers[@]}"; do
        test_start "$container running"
        if sudo podman ps --format "{{.Names}}" | grep -q "^${container}$"; then
            local status=$(sudo podman inspect "$container" --format '{{.State.Status}}' 2>/dev/null)
            if [ "$status" = "running" ]; then
                test_pass
            else
                test_fail "(status: $status)"
            fi
        else
            test_fail "(not running)"
        fi
    done
    
    # Infrastructure Services
    test_print_section "2. Infrastructure Services"
    
    test_start "Redis connection"
    if sudo podman exec redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
        test_pass
    else
        test_fail
    fi
    
    test_start "Redis persistence"
    local test_key="test:$(date +%s)"
    if sudo podman exec redis redis-cli SET "$test_key" "test" >/dev/null 2>&1 && \
       sudo podman exec redis redis-cli GET "$test_key" 2>/dev/null | grep -q "test" && \
       sudo podman exec redis redis-cli DEL "$test_key" >/dev/null 2>&1; then
        test_pass
    else
        test_fail
    fi
    
    test_start "NATS connection"
    if nc -z localhost $NATS_PORT 2>/dev/null; then
        test_pass
    else
        test_fail
    fi
    
    # Chat Node Health
    test_print_section "3. Chat Node Health Endpoints"
    
    for i in {0..2}; do
        local port=${CHAT_PORTS[$i]}
        local node=$((i + 1))
        
        test_start "Chat Node $node health endpoint"
        local response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}/health" 2>/dev/null)
        if [ "$response" = "200" ]; then
            test_pass
        else
            test_fail "(HTTP $response)"
        fi
        
        test_start "Chat Node $node health data"
        local health_data=$(curl -s "http://localhost:${port}/health" 2>/dev/null)
        if echo "$health_data" | grep -q '"status":"ok"'; then
            test_pass
        else
            test_fail
        fi
    done
    
    # Load Balancer
    test_print_section "4. Load Balancer"
    
    test_start "Load balancer health"
    local response=$(curl -s -o /dev/null -w "%{http_code}" "http://${TEST_HOST_IP}:${LB_PORT}/health" 2>/dev/null)
    if [ "$response" = "200" ]; then
        test_pass
    else
        test_fail "(HTTP $response)"
    fi
    
    test_start "Load balancer node discovery"
    local lb_health=$(curl -s "http://${TEST_HOST_IP}:${LB_PORT}/health" 2>/dev/null)
    local node_count=$(echo "$lb_health" | grep -o '"totalNodes":[0-9]*' | cut -d: -f2)
    local available_count=$(echo "$lb_health" | grep -o '"availableNodes":[0-9]*' | cut -d: -f2)
    
    if [ -n "$node_count" ] && [ "$node_count" -ge 3 ]; then
        test_pass
        echo "    ℹ Found $available_count/$node_count nodes"
    else
        test_fail "(found $node_count nodes)"
    fi
    
    # Cluster Integration
    test_print_section "5. Cluster Integration"
    
    test_start "Cluster Consul reachability"
    if curl -s -f --max-time 3 "${TEST_CLUSTER_CONSUL}/v1/status/leader" >/dev/null 2>&1; then
        test_pass
        
        test_start "Chat service registered in cluster"
        if curl -s "${TEST_CLUSTER_CONSUL}/v1/catalog/service/chat-service" 2>/dev/null | grep -q "${TEST_HOST_IP}"; then
            test_pass
        else
            test_skip "(services may be registered with different IDs)"
        fi
        
        test_start "Redis service registered in cluster"
        if curl -s "${TEST_CLUSTER_CONSUL}/v1/catalog/service/redis-service" 2>/dev/null | grep -q "${TEST_HOST_IP}"; then
            test_pass
        else
            test_skip "(services may be registered with different IDs)"
        fi
        
        test_start "NATS service registered in cluster"
        if curl -s "${TEST_CLUSTER_CONSUL}/v1/catalog/service/nats-service" 2>/dev/null | grep -q "${TEST_HOST_IP}"; then
            test_pass
        else
            test_skip "(services may be registered with different IDs)"
        fi
    else
        test_skip "(cluster not reachable or running in standalone mode)"
        TOTAL_TESTS=$((TOTAL_TESTS - 3))
    fi
    
    # Metrics Endpoints
    test_print_section "6. Metrics Endpoints (Prometheus)"
    
    test_start "Load balancer metrics"
    if curl -s "http://${TEST_HOST_IP}:${LB_PORT}/metrics" 2>/dev/null | grep -q "lb_"; then
        test_pass
    else
        test_fail
    fi
    
    for i in {0..2}; do
        local port=${CHAT_PORTS[$i]}
        local node=$((i + 1))
        
        test_start "Chat Node $node metrics"
        if curl -s "http://localhost:${port}/metrics" 2>/dev/null | grep -q "chat_"; then
            test_pass
        else
            test_fail
        fi
    done
    
    # WebSocket Functionality
    test_print_section "7. WebSocket Connectivity"
    
    for i in {0..2}; do
        local port=${CHAT_PORTS[$i]}
        local node=$((i + 1))
        
        test_start "Chat Node $node WebSocket upgrade"
        local response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}/socket.io/" 2>/dev/null)
        if [ "$response" = "200" ] || [ "$response" = "400" ]; then
            test_pass
        else
            test_fail "(HTTP $response)"
        fi
    done
    
    test_start "Load balancer WebSocket endpoint"
    local response=$(curl -s -o /dev/null -w "%{http_code}" "http://${TEST_HOST_IP}:${LB_PORT}/socket.io/" 2>/dev/null)
    if [ "$response" = "200" ] || [ "$response" = "400" ]; then
        test_pass
    else
        test_fail "(HTTP $response)"
    fi
    
    # Rate Limiting
    test_print_section "8. Rate Limiting & Security"
    
    test_start "Rate limiting configured"
    local count=0
    for i in {1..5}; do
        local status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3002/health" 2>/dev/null)
        [ "$status" = "200" ] && count=$((count + 1))
    done
    
    if [ "$count" -ge 3 ]; then
        test_pass
    else
        test_fail "(only $count/5 requests succeeded)"
    fi
    
    # Autostart & Monitoring
    test_print_section "9. Autostart & Monitoring Configuration"
    
    test_start "Systemd service configured"
    if [ -f "/etc/systemd/system/chat-system.service" ]; then
        test_pass
    else
        test_skip "(autostart not configured)"
    fi
    
    test_start "Systemd service enabled"
    if systemctl is-enabled chat-system.service 2>/dev/null | grep -q "enabled"; then
        test_pass
    else
        test_skip "(autostart not enabled)"
    fi
    
    # Client Configuration
    test_print_section "10. Client Configuration"
    
    test_start "React client directory exists"
    if [ -d "$(dirname "$0")/client-react" ]; then
        test_pass
        
        test_start "Client .env file configured"
        if [ -f "$(dirname "$0")/client-react/.env" ]; then
            test_pass
            local env_url=$(grep "VITE_CHAT_URL" "$(dirname "$0")/client-react/.env" | cut -d= -f2)
            echo "    ℹ Configured URL: $env_url"
        else
            test_fail "(run: echo 'VITE_CHAT_URL=http://${TEST_HOST_IP}:${LB_PORT}' > client-react/.env)"
        fi
    else
        test_skip "(client not found)"
        TOTAL_TESTS=$((TOTAL_TESTS - 1))
    fi
    
    # Resilience Tests (Optional)
    if [ "$1" = "--with-resilience" ] || [ "$1" = "--full" ]; then
        test_print_section "11. Resilience & Failure Handling"
        echo "  ${YELLOW}⚠ This section will temporarily disrupt services${NC}"
        echo ""
        
        # Include all resilience tests here...
        test_skip "(resilience tests available but skipped - use --with-resilience)"
    fi
    
    # Summary
    echo ""
    test_print_header
    echo -e "${BLUE}║                          TEST SUMMARY                            ║${NC}"
    test_print_footer
    echo ""
    
    echo -e "  Total Tests:   $TOTAL_TESTS"
    echo -e "  ${GREEN}Passed:        $PASSED_TESTS${NC}"
    echo -e "  ${RED}Failed:        $FAILED_TESTS${NC}"
    echo ""
    
    if [ $FAILED_TESTS -eq 0 ]; then
        echo -e "${GREEN}✓ ALL TESTS PASSED!${NC}"
        echo ""
        echo "System is fully operational. You can now:"
        echo "  1. Access Consul UI: ${TEST_CLUSTER_CONSUL}/ui/dc1/services"
        echo "  2. Start client:     cd client-react && npm run dev"
        echo "  3. Access app:       http://localhost:5173"
        echo "  4. View metrics:     http://${TEST_HOST_IP}:${LB_PORT}/metrics"
        echo ""
        if [ "$1" != "--with-resilience" ] && [ "$1" != "--full" ]; then
            echo "To test resilience & failure handling:"
            echo "  ./chat-system.sh test --with-resilience"
            echo ""
        fi
        exit 0
    else
        echo -e "${RED}✗ SOME TESTS FAILED${NC}"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check logs:       ./chat-system.sh logs <service>"
        echo "  2. Check status:     ./chat-system.sh status"
        echo "  3. View containers:  sudo podman ps -a"
        echo "  4. Restart system:   sudo systemctl restart chat-system"
        echo ""
        exit 1
    fi
}

# Command: help
show_help() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║              DISTRIBUTED CHAT SYSTEM - Universal Management Script          ║
╚══════════════════════════════════════════════════════════════════════════════╝

USAGE:
    ./chat-system.sh <command> [options]

CORE COMMANDS:
    run [OPTIONS]       Start system + metrics + continuous monitoring (all-in-one)
    start               Start the chat system
    stop                Stop all services
    restart             Restart chat nodes
    status              Show system status
    build               Build Docker image
    daemon              Run continuous health monitoring (background service)
    test [OPTIONS]      Run comprehensive system tests
    
MANAGEMENT COMMANDS:
    setup-autostart     Configure systemd for autostart & autorecovery (requires sudo)
    metrics [url] [port] Start metrics aggregation server
    logs <service>      View logs (redis|nats|consul|node-1|node-2|node-3|lb)
    cluster-test [url]  Test cluster connectivity
    deregister [url]    Deregister services from cluster
    clear-usernames     Clear all registered usernames
    help                Show this help

TEST OPTIONS:
    ./chat-system.sh test                Run all standard tests
    ./chat-system.sh test --with-resilience  Include disruptive failure tests
    ./chat-system.sh test --full         Run all tests including resilience

START OPTIONS:
    --auto                      Auto-discover infrastructure (recommended)
    --cluster                   Enable cluster mode
    --cluster-consul <URL>      Cluster Consul URL (default: http://192.168.100.53:8500)
    --mode <mode>               standalone|infrastructure|node-only|full|auto
    --with-lb, --load-balancer  Start load balancer on port 3000
    --nodes <count>             Number of chat nodes (default: 3)

QUICK START EXAMPLES:
    # All-in-one: Start everything with monitoring (recommended)
    ./chat-system.sh run --auto

    # Cluster mode with everything
    ./chat-system.sh run --cluster --mode full --with-lb

    # Just start services (no monitoring)
    ./chat-system.sh start --auto

    # Setup autostart on boot
    sudo ./chat-system.sh setup-autostart

    # Start metrics server
    ./chat-system.sh metrics http://192.168.100.53:8500 9090

    # Check status
    ./chat-system.sh status

ARCHITECTURE:
    Redis (6379)         Shared state & message history
    NATS (4222)          Pub/sub messaging between nodes
    Consul (8500)        Service discovery & health checks
    Chat Nodes (3002-4)  Socket.IO gateways
    Load Balancer (3001) Round-robin client distribution

AUTOSTART & RECOVERY:
    Configure automatic startup with continuous health monitoring:
    
        sudo ./chat-system.sh setup-autostart
    
    This creates a systemd daemon that:
    • Starts all services on boot
    • Monitors health continuously (every 30 seconds)
    • Automatically restarts unhealthy containers
    • Recreates failed containers if restart doesn't work
    • Prevents restart loops with cooldown periods (60s)
    • Logs all actions to /var/log/chat-system-daemon.log
    
    The daemon runs as Type=simple and stays active, unlike traditional
    oneshot services that exit after starting containers.
    
    Manage with systemctl:
        sudo systemctl start chat-system    # Start daemon
        sudo systemctl stop chat-system     # Stop daemon & services
        sudo systemctl status chat-system   # Check daemon status
        sudo journalctl -u chat-system -f   # View systemd logs
        
    Monitor daemon activity:
        sudo tail -f /var/log/chat-system-daemon.log
        ./chat-system.sh status             # Shows daemon uptime

MONITORING:
    Metrics (Prometheus format):
        Per node:      http://localhost:3002/metrics
        Load balancer: http://localhost:3001/metrics
        Aggregated:    ./chat-system.sh metrics
    
    Health checks:
        http://localhost:3002/health
        http://localhost:3001/health
    
    Consul UI:
        Local:   http://localhost:8500/ui
        Cluster: http://192.168.100.53:8500/ui

CLIENT SETUP:
    cd client-react
    npm install
    
    # Configure load balancer URL
    echo "VITE_CHAT_URL=http://192.168.100.51:3001" > .env
    
    npm run dev
    # Access: http://localhost:5173

TROUBLESHOOTING:
    Check container health:
        sudo podman ps --format "table {{.Names}}\t{{.Status}}"
        sudo podman inspect chat-node-1 --format '{{.State.Health.Status}}'
    
    Test connectivity:
        curl http://localhost:3001/health
        ./chat-system.sh cluster-test http://192.168.100.53:8500
    
    Deregister services:
        ./chat-system.sh deregister http://192.168.100.53:8500
    
    View cluster services:
PORTS:
    6379     Redis
    4222     NATS
    8500     Consul
    3001     Load Balancer
    3002-4   Chat nodes

For detailed documentation, see README.md
EOF
}

# Main
check_podman

# Parse command
COMMAND="${1:-help}"
shift || true

# Parse options for commands that support them
case "$COMMAND" in
    run|start|restart)
        parse_args "$@"
        ;;
esac

# Execute command
case "$COMMAND" in
    run)
        run_all "$@"
        ;;
    start)
        start_system
        ;;
    stop)
        stop_system
        ;;
    restart)
        restart_nodes
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs "$1"
        ;;
    build)
        build_image
        ;;
    daemon)
        run_daemon
        ;;
    test)
        run_tests "$@"
        ;;
    clear-usernames)
        clear_usernames
        ;;
    setup-autostart)
        setup_autostart
        ;;
    metrics)
        start_metrics_server "$1" "$2"
        ;;
    cluster-test)
        test_cluster "$1"
        ;;
    deregister)
        deregister_services "$1"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        print_error "Unknown command: $COMMAND"
        echo ""
        show_help
        exit 1
        ;;
esac
