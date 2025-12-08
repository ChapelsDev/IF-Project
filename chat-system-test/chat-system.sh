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

# Multi-machine support
HOST_IP="localhost"
DEPLOYMENT_MODE="standalone"  # standalone or distributed

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
            *)
                break
                ;;
        esac
    done
}

# Command: start
start_system() {
    print_header "======================================"
    print_header "Distributed Chat System Startup"
    print_header "======================================"
    echo ""
    
    if [ "$DEPLOYMENT_MODE" = "distributed" ]; then
        print_info "Mode: Distributed (Multi-machine)"
        print_info "Host: $HOST_IP"
    else
        print_info "Mode: Standalone (Single machine)"
        print_info "Host: localhost"
    fi
    echo ""
    
    # Stop any existing containers
    sudo podman stop $(sudo podman ps -aq) 2>/dev/null || true
    sudo podman rm -f $(sudo podman ps -aq) 2>/dev/null || true
    
    # Clean up network configs
    sudo rm -f /etc/cni/net.d/chat-*.conflist 2>/dev/null || true
    
    # Start infrastructure services (only in standalone or if explicitly infrastructure mode)
    if [ "$DEPLOYMENT_MODE" = "standalone" ] || [ "$DEPLOYMENT_MODE" = "infrastructure" ]; then
        print_info "Starting infrastructure services..."
        
        # Redis - bind to all interfaces in distributed mode
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
        
        # NATS - already binds to all interfaces
        sudo podman run -d --name nats --network host \
            docker.io/nats:2.10-alpine \
            > /dev/null 2>&1
        print_success "NATS started on port ${NATS_PORT}"
        
        # Consul - bind to all interfaces in distributed mode
        sudo podman run -d --name consul --network host \
            docker.io/hashicorp/consul:1.16 agent -dev -ui -client=0.0.0.0 -bind=0.0.0.0 \
            > /dev/null 2>&1
        print_success "Consul started on port ${CONSUL_PORT}"
        
        sleep 3
        
        if [ "$DEPLOYMENT_MODE" = "infrastructure" ]; then
            print_success "Infrastructure services started"
            echo ""
            print_info "Connect remote nodes with:"
            detected_ip=$(get_host_ip)
            echo "  ./chat-system.sh start --host $detected_ip --mode node-only"
            echo ""
            return
        fi
    fi
    
    # Start chat nodes (skip if infrastructure-only mode)
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
            # In standalone mode, start 3 nodes
            node_count=3
        fi
        
        # Start chat nodes
        for i in $(seq 1 $node_count); do
            port=${CHAT_NODE_PORTS[$((i-1))]}
            sudo podman run -d --name chat-node-${i} --network host \
                -e NODE_ID=${i} \
                -e PORT=${port} \
                -e REDIS_URL=redis://${HOST_IP}:${REDIS_PORT} \
                -e NATS_URL=nats://${HOST_IP}:${NATS_PORT} \
                -e CONSUL_URL=http://${HOST_IP}:${CONSUL_PORT} \
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
            echo "  ./chat-system.sh start --host $detected_ip --mode infrastructure"
            echo "  Then on remote machine:"
            echo "  ./chat-system.sh start --host $detected_ip --mode node-only"
        fi
    elif [ "$DEPLOYMENT_MODE" = "distributed" ] || [ "$DEPLOYMENT_MODE" = "node-only" ]; then
        echo "Mode: Distributed Node"
        echo "Connected to: ${HOST_IP}"
        echo ""
        echo "Access URLs:"
        echo "  - Consul UI:    http://${HOST_IP}:${CONSUL_PORT}"
        echo "  - Chat Node 1:  http://localhost:${CHAT_NODE_PORTS[0]}"
        echo ""
        echo "This node is connected to infrastructure at ${HOST_IP}"
    fi
}

# Command: stop
stop_system() {
    print_info "Stopping chat system..."
    
    services=("redis" "nats" "consul" "chat-node-1" "chat-node-2" "chat-node-3")
    
    for service in "${services[@]}"; do
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

# Command: help
show_help() {
    cat << EOF
Distributed Chat System Management

Usage: ./chat-system.sh [command] [options]

Commands:
    start [options]    Start services
    stop               Stop all services
    restart [options]  Restart chat nodes only
    status             Show system status
    logs <service>     Show logs for a service
                       Services: redis, nats, consul, chat-1, chat-2, chat-3
    build              Build chat node Docker image
    clear-usernames    Clear all registered usernames from Redis
    help               Show this help message

Options:
    --host <IP>        Connect to remote infrastructure at specified IP
    --mode <mode>      Deployment mode:
                       - standalone:      All services on one machine (default)
                       - infrastructure:  Only Redis/NATS/Consul (no chat nodes)
                       - node-only:       Only chat nodes (requires --host)

Deployment Scenarios:

  Single Machine (Standalone):
    ./chat-system.sh start

  Multi-Machine Setup:
    On infrastructure host:
      ./chat-system.sh start --mode infrastructure
    
    On remote machines:
      ./chat-system.sh start --host <infrastructure-ip> --mode node-only

Examples:
    # Standalone on one machine
    ./chat-system.sh start
    ./chat-system.sh status
    ./chat-system.sh logs chat-1

    # Infrastructure host (192.168.1.100)
    ./chat-system.sh start --mode infrastructure
    
    # Remote node connecting to infrastructure
    ./chat-system.sh start --host 192.168.1.100 --mode node-only
    
    # Stop and restart
    ./chat-system.sh stop
    ./chat-system.sh restart

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
