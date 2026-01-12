#!/bin/bash

# Chat System Daemon - Continuous Health Monitoring and Recovery
# This script runs continuously, monitoring all services and restarting/recreating them as needed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/chat-system-daemon.log"
CHECK_INTERVAL=30  # Check every 30 seconds
RESTART_COOLDOWN=60  # Wait 60 seconds before restarting same service again

# Track last restart times to prevent restart loops
declare -A LAST_RESTART

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS: $1" | tee -a "$LOG_FILE"
}

# Get host IP
get_host_ip() {
    ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' || echo "localhost"
}

# Check if enough time has passed since last restart
can_restart() {
    local service=$1
    local now=$(date +%s)
    local last=${LAST_RESTART[$service]:-0}
    local elapsed=$((now - last))
    
    if [ $elapsed -ge $RESTART_COOLDOWN ]; then
        return 0
    else
        log "Service $service in cooldown (${elapsed}s/${RESTART_COOLDOWN}s)"
        return 1
    fi
}

# Record restart time
record_restart() {
    local service=$1
    LAST_RESTART[$service]=$(date +%s)
}

# Check if container exists and is running
check_container_running() {
    local container=$1
    sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"
}

# Check if container exists (running or stopped)
check_container_exists() {
    local container=$1
    sudo podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"
}

# Get container status
get_container_status() {
    local container=$1
    sudo podman inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo "missing"
}

# Check container health
check_container_health() {
    local container=$1
    local health=$(sudo podman inspect "$container" --format '{{.State.Health.Status}}' 2>/dev/null)
    
    if [ -z "$health" ] || [ "$health" = "<no value>" ]; then
        # No health check defined, check if running
        if check_container_running "$container"; then
            echo "running"
        else
            echo "unhealthy"
        fi
    else
        echo "$health"
    fi
}

# Check service via HTTP health endpoint
check_http_health() {
    local port=$1
    local timeout=${2:-5}
    curl -sf --max-time "$timeout" "http://localhost:${port}/health" >/dev/null 2>&1
}

# Restart container
restart_container() {
    local container=$1
    log "Restarting container: $container"
    
    if sudo podman restart "$container" >/dev/null 2>&1; then
        log_success "Container $container restarted"
        record_restart "$container"
        return 0
    else
        log_error "Failed to restart $container"
        return 1
    fi
}

# Recreate container (for when restart doesn't work)
recreate_container() {
    local container=$1
    log "Recreating container: $container (restart failed)"
    
    # Stop and remove
    sudo podman stop -t 10 "$container" >/dev/null 2>&1
    sudo podman rm "$container" >/dev/null 2>&1
    
    # Recreate based on container type
    case "$container" in
        redis)
            recreate_redis
            ;;
        nats)
            recreate_nats
            ;;
        chat-node-*)
            recreate_chat_node "$container"
            ;;
        chat-lb)
            recreate_load_balancer
            ;;
        *)
            log_error "Unknown container type: $container"
            return 1
            ;;
    esac
}

# Recreate Redis
recreate_redis() {
    log "Recreating Redis..."
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
        log_success "Redis recreated"
        record_restart "redis"
        return 0
    else
        log_error "Failed to recreate Redis"
        return 1
    fi
}

# Recreate NATS
recreate_nats() {
    log "Recreating NATS..."
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
        log_success "NATS recreated"
        record_restart "nats"
        return 0
    else
        log_error "Failed to recreate NATS"
        return 1
    fi
}

# Recreate chat node
recreate_chat_node() {
    local container=$1
    local node_num=$(echo "$container" | grep -oP '\d+$')
    local ports=(3001 3002 3003)
    local port=${ports[$((node_num - 1))]}
    local host_ip=$(get_host_ip)
    
    log "Recreating chat node $node_num on port $port..."
    
    # Read environment from existing systemd service or use defaults
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
        log_success "Chat node $node_num recreated on port $port"
        record_restart "$container"
        return 0
    else
        log_error "Failed to recreate chat node $node_num"
        return 1
    fi
}

# Recreate load balancer
recreate_load_balancer() {
    local host_ip=$(get_host_ip)
    local cluster_consul="${CLUSTER_CONSUL_URL:-http://192.168.100.52:8500}"
    
    log "Recreating load balancer..."
    
    sudo podman run -d --name chat-lb --network host \
        --stop-timeout=10 \
        --restart=on-failure:5 \
        --health-cmd="curl -f http://localhost:3000/health || exit 1" \
        --health-interval=30s \
        --health-timeout=10s \
        --health-retries=3 \
        --health-start-period=15s \
        -e LB_PORT="3000" \
        -e CONSUL_URL="${cluster_consul}" \
        localhost/chat-node:latest \
        npm run start:lb \
        >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_success "Load balancer recreated"
        record_restart "chat-lb"
        return 0
    else
        log_error "Failed to recreate load balancer"
        return 1
    fi
}

# Monitor and maintain a service
monitor_service() {
    local container=$1
    local port=$2
    
    # Check if container exists
    if ! check_container_exists "$container"; then
        log_error "Container $container does not exist - recreating"
        if can_restart "$container"; then
            recreate_container "$container"
        fi
        return
    fi
    
    # Check if container is running
    if ! check_container_running "$container"; then
        local status=$(get_container_status "$container")
        log_error "Container $container not running (status: $status)"
        
        if can_restart "$container"; then
            if ! restart_container "$container"; then
                # Restart failed, try recreate
                recreate_container "$container"
            fi
        fi
        return
    fi
    
    # Check container health (if health check is defined)
    local health=$(check_container_health "$container")
    if [ "$health" = "unhealthy" ]; then
        log_error "Container $container is unhealthy"
        
        if can_restart "$container"; then
            if ! restart_container "$container"; then
                recreate_container "$container"
            fi
        fi
        return
    fi
    
    # For services with HTTP endpoints, also check HTTP health
    if [ -n "$port" ]; then
        if ! check_http_health "$port" 3; then
            log_error "HTTP health check failed for $container on port $port"
            
            if can_restart "$container"; then
                if ! restart_container "$container"; then
                    recreate_container "$container"
                fi
            fi
            return
        fi
    fi
}

# Main monitoring loop
main() {
    log "=========================================="
    log "Chat System Daemon Started"
    log "=========================================="
    log "Check Interval: ${CHECK_INTERVAL}s"
    log "Restart Cooldown: ${RESTART_COOLDOWN}s"
    log "Log File: $LOG_FILE"
    log "=========================================="
    
    # Trap signals for graceful shutdown
    trap 'log "Received shutdown signal"; exit 0' SIGTERM SIGINT
    
    local check_count=0
    
    while true; do
        check_count=$((check_count + 1))
        
        # Log periodic heartbeat (every 10 checks = 5 minutes at 30s interval)
        if [ $((check_count % 10)) -eq 0 ]; then
            log "Heartbeat: Check #${check_count} - All services monitored"
        fi
        
        # Monitor infrastructure services
        monitor_service "redis" "6379"
        monitor_service "nats" "4222"
        
        # Monitor chat nodes
        monitor_service "chat-node-1" "3001"
        monitor_service "chat-node-2" "3002"
        monitor_service "chat-node-3" "3003"
        
        # Monitor load balancer
        monitor_service "chat-lb" "3000"
        
        # Sleep until next check
        sleep "$CHECK_INTERVAL"
    done
}

# Run main loop
main
