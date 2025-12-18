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
CHAT_NODE_PORTS=(3001 3002 3003)
CHAT_IMAGE="localhost/chat-node:latest"

# Cluster integration
CLUSTER_MODE="false"
CLUSTER_CONSUL_URL="http://192.168.100.53:8500"
USE_LOCAL_CONSUL="true"

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
        python3 "${script_dir}/cluster_helper.py" register "redis-service" "redis-${HOSTNAME}" "${host_ip}" "${REDIS_PORT}" "${CLUSTER_CONSUL_URL}" "chat-infrastructure,redis" "tcp" 2>&1 || print_error "Failed to register Redis"
        
        # Register NATS (uses TCP health check - NATS client port doesn't speak HTTP)
        python3 "${script_dir}/cluster_helper.py" register "nats-service" "nats-${HOSTNAME}" "${host_ip}" "${NATS_PORT}" "${CLUSTER_CONSUL_URL}" "chat-infrastructure,nats" "tcp" 2>&1 || print_error "Failed to register NATS"
        
        print_success "Infrastructure services registered with cluster"
    elif [ -f "${script_dir}/cluster_bridge.py" ]; then
        # Fallback to old bridge
        python3 "${script_dir}/cluster_bridge.py" register "redis-service" "redis-${HOSTNAME}" "${host_ip}" "${REDIS_PORT}" "${CLUSTER_CONSUL_URL}" "chat-infrastructure,redis" 2>/dev/null || print_error "Failed to register Redis"
        python3 "${script_dir}/cluster_bridge.py" register "nats-service" "nats-${HOSTNAME}" "${host_ip}" "${NATS_PORT}" "${CLUSTER_CONSUL_URL}" "chat-infrastructure,nats" 2>/dev/null || print_error "Failed to register NATS"
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
    
    # If cluster mode but no explicit mode set, check if we need local infrastructure
    if [ "$CLUSTER_MODE" = "true" ] && [ "$DEPLOYMENT_MODE" = "standalone" ]; then
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
    
    # Set default HOST_IP if not provided
    if [ -z "$HOST_IP" ]; then
        if [ "$DEPLOYMENT_MODE" = "standalone" ] || [ "$USE_LOCAL_CONSUL" = "true" ]; then
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
                docker.io/redis:7-alpine redis-server --port ${REDIS_PORT} \
                > /dev/null 2>&1
        else
            sudo podman run -d --name redis --network host \
                docker.io/redis:7-alpine redis-server --port ${REDIS_PORT} --bind 0.0.0.0 --protected-mode no \
                > /dev/null 2>&1
        fi
        print_success "Redis started on port ${REDIS_PORT}"
        
        # NATS
        sudo podman run -d --name nats --network host \
            docker.io/nats:2.10-alpine \
            > /dev/null 2>&1
        print_success "NATS started on port ${NATS_PORT}"
        
        # Consul (local) - bind to 127.0.0.1 to avoid multi-interface issues
        sudo podman run -d --name consul --network host \
            docker.io/hashicorp/consul:1.16 agent -dev -ui -client=0.0.0.0 -bind=127.0.0.1 \
            > /dev/null 2>&1
        print_success "Consul started on port ${CONSUL_PORT}"
        
        sleep 3
        
    elif [ "$CLUSTER_MODE" = "true" ] && ([ "$DEPLOYMENT_MODE" = "infrastructure" ] || [ "$DEPLOYMENT_MODE" = "full" ]); then
        print_info "Starting infrastructure for cluster..."
        
        # Start Redis and NATS for chat coordination
        sudo podman run -d --name redis --network host \
            docker.io/redis:7-alpine redis-server --port ${REDIS_PORT} --bind 0.0.0.0 --protected-mode no \
            > /dev/null 2>&1
        print_success "Redis started on port ${REDIS_PORT}"
        
        sudo podman run -d --name nats --network host \
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
        if [ "$DEPLOYMENT_MODE" = "node-only" ]; then
            # In node-only mode, start just 1 node
            node_count=1
        else
            # In standalone or full mode, start 3 nodes
            node_count=3
        fi
        
        # Determine Consul URL
        if [ "$CLUSTER_MODE" = "true" ]; then
            CONSUL_ENV="${CLUSTER_CONSUL_URL}"
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
                -e NODE_ID="${i}" \
                -e PORT="${port}" \
                -e HOST_IP="${host_ip}" \
                -e REDIS_URL="redis://${redis_connect_host}:${REDIS_PORT}" \
                -e NATS_URL="nats://${nats_connect_host}:${NATS_PORT}" \
                -e CONSUL_URL="${CONSUL_ENV}" \
                -e CLUSTER_MODE="${CLUSTER_MODE}" \
                -e CLUSTER_CONSUL_URL="${CLUSTER_CONSUL_URL}" \
                ${CHAT_IMAGE} \
                > /dev/null 2>&1
            print_success "Chat Node ${i} started on port ${port}"
        done
    fi
    
    echo ""
    print_success "System started successfully!"
    echo ""
    
    if [ "$DEPLOYMENT_MODE" = "standalone" ]; then
        echo "Mode: Standalone (Single Machine)"
        echo ""
        echo "Access URLs:"
        echo "  - Consul UI:    http://localhost:${CONSUL_PORT}"
        echo "  - Chat Node 1:  http://localhost:${CHAT_NODE_PORTS[0]}"
        echo "  - Chat Node 2:  http://localhost:${CHAT_NODE_PORTS[1]}"
        echo "  - Chat Node 3:  http://localhost:${CHAT_NODE_PORTS[2]}"
        echo ""
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
        echo "Chat Nodes:"
        echo "  - Chat Node 1:  http://localhost:${CHAT_NODE_PORTS[0]}"
        echo "  - Chat Node 2:  http://localhost:${CHAT_NODE_PORTS[1]}"
        echo "  - Chat Node 3:  http://localhost:${CHAT_NODE_PORTS[2]}"
        echo ""
        echo "Cluster URLs:"
        echo "  - Cluster Consul: ${CLUSTER_CONSUL_URL}"
        echo "  - Consul UI: ${CLUSTER_CONSUL_URL}/ui/dc1/services"
        echo ""
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
    
    # Stop chat nodes first (they need to deregister from cluster)
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
        python3 "${script_dir}/cluster_helper.py" deregister "redis-${HOSTNAME}" "${CLUSTER_CONSUL_URL}" 2>/dev/null && print_success "Redis deregistered" || true
        python3 "${script_dir}/cluster_helper.py" deregister "nats-${HOSTNAME}" "${CLUSTER_CONSUL_URL}" 2>/dev/null && print_success "NATS deregistered" || true
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
    
    # Deregister chat nodes
    for i in 1 2 3; do
        python3 "${script_dir}/cluster_helper.py" deregister "chat-node-${i}" "${consul_url}" 2>/dev/null && print_success "chat-node-${i} deregistered" || true
    done
    
    # Deregister infrastructure
    python3 "${script_dir}/cluster_helper.py" deregister "redis-${HOSTNAME}" "${consul_url}" 2>/dev/null && print_success "redis-${HOSTNAME} deregistered" || true
    python3 "${script_dir}/cluster_helper.py" deregister "nats-${HOSTNAME}" "${consul_url}" 2>/dev/null && print_success "nats-${HOSTNAME} deregistered" || true
    
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

# Command: help
show_help() {
    cat << EOF
Distributed Chat System Management

Usage: ./chat-system.sh [command] [options]

Commands:
    start [options]    Start services
    stop               Stop all services (deregisters from cluster)
    restart [options]  Restart chat nodes only
    status             Show system status
    logs <service>     Show logs for a service
                       Services: redis, nats, consul, chat-1, chat-2, chat-3
    build              Build chat node Docker image
    clear-usernames    Clear all registered usernames from Redis
    cluster-test [url] Test connectivity to cluster Consul
    deregister [url]   Manually deregister all services from cluster
    help               Show this help message

Options:
    --auto             Auto-discover cluster and infrastructure (recommended)
    --cluster          Force cluster mode (use main cluster Consul)
    --cluster-consul <URL>  Main cluster Consul URL (default: http://172.20.10.10:8500)
    --host <IP>        Connect to remote infrastructure at specified IP
    --mode <mode>      Deployment mode:
                       - standalone:      All services on one machine
                       - infrastructure:  Only Redis/NATS (registers with cluster)
                       - node-only:       Only chat nodes (requires --host or --auto)
                       - auto:            Auto-discover (recommended)

Deployment Scenarios:

  Auto-Discovery (Recommended):
    # Just run this on any node - it figures out what to do
    ./chat-system.sh start --auto
    
    The system will:
    - Check if main cluster is available
    - Discover existing chat infrastructure
    - Start missing services as needed
    - Register everything automatically

  Single Machine (Standalone):
    ./chat-system.sh start

  Multi-Machine with Cluster Integration:
    # First node (starts infrastructure and registers)
    ./chat-system.sh start --cluster --mode infrastructure
    
    # Additional nodes (auto-discover infrastructure)
    ./chat-system.sh start --auto

  Manual Multi-Machine:
    # Infrastructure host
    ./chat-system.sh start --mode infrastructure
    
    # Worker nodes
    ./chat-system.sh start --host <infra-ip> --mode node-only

Examples:
    # Simplest - let it auto-discover
    ./chat-system.sh start --auto
    
    # Standalone on one machine
    ./chat-system.sh start
    
    # First node in cluster
    ./chat-system.sh start --cluster --mode infrastructure
    
    # Additional cluster nodes
    ./chat-system.sh start --auto
    
    # Check what's running
    ./chat-system.sh status

How Auto-Discovery Works:
    1. Checks if main cluster Consul (172.20.10.10:8500) is reachable
    2. If yes, looks for existing redis-service and nats-service
    3. If found, uses them; if not, starts local infrastructure
    4. Registers all services with cluster for others to discover
    5. If no cluster found, runs in standalone mode

Benefits:
    - No manual IP configuration needed
    - Nodes automatically find each other
    - Infrastructure services shared across nodes
    - Seamless scaling - just add more nodes with --auto
    - Works offline (falls back to standalone)

Firewall Requirements (for multi-machine):
    Open these ports on infrastructure host:
    - 6379  (Redis)
    - 4222  (NATS)
    - 8500  (Consul)
    - 3001-3003 (Chat nodes, if accessing remotely)

After starting backend:
    cd client-react
    npm install
    npm run dev

Access:
    - Frontend:     http://localhost:5173
    - Consul UI:    http://localhost:8500 (or infrastructure-ip:8500)
    - Chat Nodes:   http://localhost:3001, 3002, 3003
EOF
}

# Main
check_podman

# Parse command
COMMAND="${1:-help}"
shift || true

# Parse options for commands that support them
case "$COMMAND" in
    start|restart)
        parse_args "$@"
        ;;
esac

# Execute command
case "$COMMAND" in
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
    clear-usernames)
        clear_usernames
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
