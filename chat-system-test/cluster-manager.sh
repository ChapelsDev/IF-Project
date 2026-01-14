#!/bin/bash

# Cluster Manager - View and control chat services across all nodes
# Usage: ./cluster-manager.sh [command]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Default Consul URL
CONSUL_URL="${CONSUL_URL:-http://localhost:8500}"

# Print functions
print_header() { echo -e "${BLUE}$1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info() { echo -e "${CYAN}ℹ $1${NC}"; }

# Check if jq is installed
check_jq() {
    if ! command -v jq &> /dev/null; then
        print_error "jq is required but not installed"
        echo "Install with: sudo apt-get install jq"
        exit 1
    fi
}

# Check Consul connectivity
check_consul() {
    if ! curl -s --connect-timeout 3 "${CONSUL_URL}/v1/agent/self" > /dev/null 2>&1; then
        print_error "Cannot connect to Consul at ${CONSUL_URL}"
        echo "Set CONSUL_URL environment variable or ensure Consul is running"
        exit 1
    fi
}

# Get all services of a specific type
get_services() {
    local service_name="$1"
    curl -s "${CONSUL_URL}/v1/catalog/service/${service_name}" 2>/dev/null
}

# Get service health
get_service_health() {
    local service_name="$1"
    curl -s "${CONSUL_URL}/v1/health/service/${service_name}" 2>/dev/null
}

# Display all chat-related services across the cluster
show_services() {
    print_header "=========================================="
    print_header "Chat System Cluster Overview"
    print_header "=========================================="
    echo ""
    print_info "Consul: ${CONSUL_URL}"
    echo ""
    
    # Define service types to check
    local services=("chat-service" "redis-service" "nats-service" "consul")
    
    for service in "${services[@]}"; do
        print_header "--- ${service} ---"
        
        local data=$(get_service_health "$service")
        
        if [ -z "$data" ] || [ "$data" = "[]" ]; then
            print_warning "No instances found"
            echo ""
            continue
        fi
        
        # Parse and display service instances
        echo "$data" | jq -r '.[] | 
            "Node: \(.Node.Node)\n" +
            "  Address: \(.Service.Address // .Node.Address):\(.Service.Port)\n" +
            "  Service ID: \(.Service.ID)\n" +
            "  Status: \(if all(.Checks[]; .Status == "passing") then "✓ HEALTHY" else "✗ UNHEALTHY" end)\n" +
            "  Tags: \(.Service.Tags | join(", "))\n"
        '
        
        echo ""
    done
    
    # Show summary
    print_header "--- Summary ---"
    local chat_count=$(get_services "chat-service" | jq -r '. | length')
    local redis_count=$(get_services "redis-service" | jq -r '. | length')
    local nats_count=$(get_services "nats-service" | jq -r '. | length')
    
    echo "Chat Nodes: ${chat_count}"
    echo "Redis Instances: ${redis_count}"
    echo "NATS Instances: ${nats_count}"
    echo ""
}

# List all services in a selectable format
list_services_interactive() {
    print_header "All Chat Services Across Cluster:"
    echo ""
    
    local counter=1
    local services=()
    
    # Get all chat-related services
    for service_type in "chat-service" "redis-service" "nats-service"; do
        local data=$(get_services "$service_type")
        
        if [ -n "$data" ] && [ "$data" != "[]" ]; then
            while IFS= read -r line; do
                local node=$(echo "$line" | jq -r '.Node')
                local address=$(echo "$line" | jq -r '.ServiceAddress // .Address')
                local port=$(echo "$line" | jq -r '.ServicePort')
                local service_id=$(echo "$line" | jq -r '.ServiceID')
                
                echo -e "${CYAN}[$counter]${NC} ${service_type} - ${node} (${address}:${port})"
                echo "     Service ID: ${service_id}"
                
                # Store service info for later use
                services[$counter]="${node}|${service_id}|${service_type}"
                
                ((counter++))
            done < <(echo "$data" | jq -c '.[]')
        fi
    done
    
    echo ""
    echo "${services[@]}"
}

# Shutdown a specific service
shutdown_service() {
    local node="$1"
    local service_id="$2"
    local service_type="$3"
    
    print_info "Shutting down ${service_type} on node ${node}..."
    print_info "Service ID: ${service_id}"
    
    # For chat services, we can stop the container
    if [[ "$service_type" == "chat-service" ]]; then
        # Extract node number from service_id (e.g., chat-node-192-168-100-54-1 -> node 1)
        local container_name=$(echo "$service_id" | sed 's/chat-node-.*-\([0-9]\+\)$/chat-node-\1/')
        
        print_info "Attempting to stop container: ${container_name}"
        
        # Try to stop via SSH if not local node
        local local_ip=$(hostname -I | awk '{print $1}')
        local node_ip=$(echo "$service_id" | grep -oP '\d+-\d+-\d+-\d+' | tr '-' '.')
        
        if [[ "$node_ip" == *"$local_ip"* ]] || [ -z "$node_ip" ]; then
            # Local node - stop directly
            sudo podman stop "$container_name" 2>/dev/null && print_success "Stopped ${container_name}" || print_error "Failed to stop ${container_name}"
        else
            print_warning "Remote node detected: ${node_ip}"
            print_info "To stop remotely, run on that node:"
            echo "  ssh user@${node_ip} 'sudo podman stop ${container_name}'"
        fi
    fi
    
    # Deregister from Consul
    print_info "Deregistering from Consul..."
    
    # Use cluster_helper.py if available
    if [ -f "./cluster_helper.py" ]; then
        python3 ./cluster_helper.py deregister "$service_id" "${CONSUL_URL}" && \
            print_success "Deregistered ${service_id} from Consul" || \
            print_error "Failed to deregister from Consul"
    else
        print_warning "cluster_helper.py not found, skipping Consul deregistration"
    fi
}

# Interactive shutdown menu
interactive_shutdown() {
    print_header "=========================================="
    print_header "Interactive Service Shutdown"
    print_header "=========================================="
    echo ""
    
    local counter=1
    declare -A services
    
    # Get all chat-related services
    for service_type in "chat-service" "redis-service" "nats-service"; do
        local data=$(get_services "$service_type")
        
        if [ -n "$data" ] && [ "$data" != "[]" ]; then
            while IFS= read -r line; do
                local node=$(echo "$line" | jq -r '.Node')
                local address=$(echo "$line" | jq -r '.ServiceAddress // .Address')
                local port=$(echo "$line" | jq -r '.ServicePort')
                local service_id=$(echo "$line" | jq -r '.ServiceID')
                
                echo -e "${CYAN}[$counter]${NC} ${service_type} @ ${node} (${address}:${port})"
                
                # Store service info
                services[$counter]="${node}|${service_id}|${service_type}"
                
                ((counter++))
            done < <(echo "$data" | jq -c '.[]')
        fi
    done
    
    if [ ${#services[@]} -eq 0 ]; then
        print_warning "No services found"
        return
    fi
    
    echo ""
    echo -e "${CYAN}[0]${NC} Cancel"
    echo ""
    read -p "Select service to shutdown (0-$((counter-1))): " selection
    
    if [ "$selection" = "0" ]; then
        print_info "Cancelled"
        return
    fi
    
    if [ -z "${services[$selection]}" ]; then
        print_error "Invalid selection"
        return
    fi
    
    IFS='|' read -r node service_id service_type <<< "${services[$selection]}"
    
    echo ""
    print_warning "About to shutdown:"
    echo "  Service Type: ${service_type}"
    echo "  Node: ${node}"
    echo "  Service ID: ${service_id}"
    echo ""
    read -p "Are you sure? (yes/no): " confirm
    
    if [ "$confirm" = "yes" ]; then
        shutdown_service "$node" "$service_id" "$service_type"
    else
        print_info "Cancelled"
    fi
}

# Show detailed service info
show_service_details() {
    local service_id="$1"
    
    if [ -z "$service_id" ]; then
        print_error "Service ID required"
        echo "Usage: $0 details <service-id>"
        return 1
    fi
    
    print_header "Service Details: ${service_id}"
    echo ""
    
    # Search all service types for this ID
    for service_type in "chat-service" "redis-service" "nats-service"; do
        local data=$(get_service_health "$service_type")
        local service_data=$(echo "$data" | jq -r ".[] | select(.Service.ID == \"${service_id}\")")
        
        if [ -n "$service_data" ]; then
            echo "$service_data" | jq -r '
                "Service Type: \(.Service.Service)\n" +
                "Node: \(.Node.Node)\n" +
                "Address: \(.Service.Address // .Node.Address):\(.Service.Port)\n" +
                "Service ID: \(.Service.ID)\n" +
                "Tags: \(.Service.Tags | join(", "))\n" +
                "\nHealth Checks:\n" +
                (.Checks | map("  - \(.Name): \(.Status) (\(.Output // "N/A"))") | join("\n"))
            '
            return 0
        fi
    done
    
    print_error "Service not found: ${service_id}"
}

# Test connectivity to all services
test_connectivity() {
    print_header "Testing Connectivity to All Services"
    echo ""
    
    # Test chat nodes
    print_info "Testing Chat Nodes..."
    local chat_data=$(get_services "chat-service")
    
    if [ -n "$chat_data" ] && [ "$chat_data" != "[]" ]; then
        while IFS= read -r line; do
            local address=$(echo "$line" | jq -r '.ServiceAddress // .Address')
            local port=$(echo "$line" | jq -r '.ServicePort')
            local node=$(echo "$line" | jq -r '.Node')
            
            if curl -s --connect-timeout 2 "http://${address}:${port}/health" > /dev/null 2>&1; then
                print_success "${node} (${address}:${port}) - OK"
            else
                print_error "${node} (${address}:${port}) - FAILED"
            fi
        done < <(echo "$chat_data" | jq -c '.[]')
    fi
    
    echo ""
    
    # Test Redis
    print_info "Testing Redis..."
    local redis_data=$(get_services "redis-service")
    
    if [ -n "$redis_data" ] && [ "$redis_data" != "[]" ]; then
        while IFS= read -r line; do
            local address=$(echo "$line" | jq -r '.ServiceAddress // .Address')
            local port=$(echo "$line" | jq -r '.ServicePort')
            local node=$(echo "$line" | jq -r '.Node')
            
            if redis-cli -h "$address" -p "$port" ping 2>/dev/null | grep -q "PONG"; then
                print_success "${node} (${address}:${port}) - PONG"
            else
                print_error "${node} (${address}:${port}) - FAILED"
            fi
        done < <(echo "$redis_data" | jq -c '.[]')
    fi
    
    echo ""
    
    # Test NATS
    print_info "Testing NATS..."
    local nats_data=$(get_services "nats-service")
    
    if [ -n "$nats_data" ] && [ "$nats_data" != "[]" ]; then
        while IFS= read -r line; do
            local address=$(echo "$line" | jq -r '.ServiceAddress // .Address')
            local port=$(echo "$line" | jq -r '.ServicePort')
            local node=$(echo "$line" | jq -r '.Node')
            
            if nc -z -w2 "$address" "$port" 2>/dev/null; then
                print_success "${node} (${address}:${port}) - LISTENING"
            else
                print_error "${node} (${address}:${port}) - FAILED"
            fi
        done < <(echo "$nats_data" | jq -c '.[]')
    fi
}

# Show help
show_help() {
    cat << EOF
Cluster Manager - Manage chat services across all nodes

Usage: $0 [command] [options]

Commands:
    list, ls           Show all services across the cluster
    shutdown           Interactive shutdown menu
    stop <service-id>  Stop a specific service
    details <id>       Show detailed info about a service
    test               Test connectivity to all services
    help               Show this help message

Environment Variables:
    CONSUL_URL         Consul URL (default: http://localhost:8500)

Examples:
    # Show all services
    $0 list

    # Interactive shutdown
    $0 shutdown

    # Stop specific service
    $0 stop chat-node-192-168-100-54-1

    # Test all services
    $0 test

    # Use different Consul
    CONSUL_URL=http://192.168.100.53:8500 $0 list

EOF
}

# Main script
main() {
    check_jq
    check_consul
    
    local command="${1:-list}"
    
    case "$command" in
        list|ls)
            show_services
            ;;
        shutdown)
            interactive_shutdown
            ;;
        stop)
            if [ -z "$2" ]; then
                print_error "Service ID required"
                echo "Usage: $0 stop <service-id>"
                exit 1
            fi
            # Extract info from service ID and shutdown
            shutdown_service "" "$2" "chat-service"
            ;;
        details)
            show_service_details "$2"
            ;;
        test)
            test_connectivity
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Run main
main "$@"
