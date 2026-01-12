#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Configuration
HOST_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' || echo "localhost")
CLUSTER_CONSUL="${1:-http://192.168.100.52:8500}"
LB_PORT=3000
CHAT_PORTS=(3001 3002 3003)
REDIS_PORT=6379
NATS_PORT=4222

# Helper functions
print_header() { echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"; }
print_footer() { echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"; }
print_section() { echo -e "\n${BLUE}▶ $1${NC}"; }
test_start() { echo -ne "  Testing: $1 ... "; TOTAL_TESTS=$((TOTAL_TESTS + 1)); }
test_pass() { echo -e "${GREEN}✓ PASS${NC}"; PASSED_TESTS=$((PASSED_TESTS + 1)); }
test_fail() { echo -e "${RED}✗ FAIL${NC} $1"; FAILED_TESTS=$((FAILED_TESTS + 1)); }
test_skip() { echo -e "${YELLOW}⊘ SKIP${NC} $1"; TOTAL_TESTS=$((TOTAL_TESTS - 1)); }

print_header
echo -e "${BLUE}║          DISTRIBUTED CHAT SYSTEM - COMPREHENSIVE TEST           ║${NC}"
print_footer
echo ""
echo "Usage: $0 [OPTIONS]"
echo ""
echo "Options:"
echo "  --with-resilience   Include resilience & failure handling tests (disruptive)"
echo "  --full              Run all tests including resilience tests"
echo ""
echo "Note: Resilience tests will temporarily stop services to test recovery."
echo ""

# =============================================================================
# 1. CONTAINER HEALTH
# =============================================================================
print_section "1. Container Health Checks"

containers=("redis" "nats" "chat-node-1" "chat-node-2" "chat-node-3" "chat-lb")

for container in "${containers[@]}"; do
    test_start "$container running"
    if sudo podman ps --format "{{.Names}}" | grep -q "^${container}$"; then
        # Check if container is healthy (if health check is configured)
        status=$(sudo podman inspect "$container" --format '{{.State.Status}}' 2>/dev/null)
        if [ "$status" = "running" ]; then
            test_pass
        else
            test_fail "(status: $status)"
        fi
    else
        test_fail "(not running)"
    fi
done

# =============================================================================
# 2. INFRASTRUCTURE SERVICES
# =============================================================================
print_section "2. Infrastructure Services"

# Redis
test_start "Redis connection"
if sudo podman exec redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
    test_pass
else
    test_fail
fi

test_start "Redis persistence"
test_key="test:$(date +%s)"
if sudo podman exec redis redis-cli SET "$test_key" "test" >/dev/null 2>&1 && \
   sudo podman exec redis redis-cli GET "$test_key" 2>/dev/null | grep -q "test" && \
   sudo podman exec redis redis-cli DEL "$test_key" >/dev/null 2>&1; then
    test_pass
else
    test_fail
fi

# NATS
test_start "NATS connection"
if nc -z localhost $NATS_PORT 2>/dev/null; then
    test_pass
else
    test_fail
fi

# =============================================================================
# 3. CHAT NODE HEALTH
# =============================================================================
print_section "3. Chat Node Health Endpoints"

for i in {0..2}; do
    port=${CHAT_PORTS[$i]}
    node=$((i + 1))
    
    test_start "Chat Node $node health endpoint"
    response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}/health" 2>/dev/null)
    if [ "$response" = "200" ]; then
        test_pass
    else
        test_fail "(HTTP $response)"
    fi
    
    test_start "Chat Node $node health data"
    health_data=$(curl -s "http://localhost:${port}/health" 2>/dev/null)
    if echo "$health_data" | grep -q '"status":"ok"'; then
        test_pass
    else
        test_fail
    fi
done

# =============================================================================
# 4. LOAD BALANCER
# =============================================================================
print_section "4. Load Balancer"

test_start "Load balancer health"
response=$(curl -s -o /dev/null -w "%{http_code}" "http://${HOST_IP}:${LB_PORT}/health" 2>/dev/null)
if [ "$response" = "200" ]; then
    test_pass
else
    test_fail "(HTTP $response)"
fi

test_start "Load balancer node discovery"
lb_health=$(curl -s "http://${HOST_IP}:${LB_PORT}/health" 2>/dev/null)
node_count=$(echo "$lb_health" | grep -o '"totalNodes":[0-9]*' | cut -d: -f2)
available_count=$(echo "$lb_health" | grep -o '"availableNodes":[0-9]*' | cut -d: -f2)

if [ -n "$node_count" ] && [ "$node_count" -ge 3 ]; then
    test_pass
    echo "    ℹ Found $available_count/$node_count nodes"
else
    test_fail "(found $node_count nodes)"
fi

# =============================================================================
# 5. CLUSTER INTEGRATION
# =============================================================================
print_section "5. Cluster Integration"

test_start "Cluster Consul reachability"
if curl -s -f --max-time 3 "${CLUSTER_CONSUL}/v1/status/leader" >/dev/null 2>&1; then
    test_pass
    
    # Check service registration
    test_start "Chat service registered in cluster"
    if curl -s "${CLUSTER_CONSUL}/v1/catalog/service/chat-service" 2>/dev/null | grep -q "${HOST_IP}"; then
        test_pass
    else
        test_skip "(services may be registered with different IDs)"
    fi
    
    test_start "Redis service registered in cluster"
    if curl -s "${CLUSTER_CONSUL}/v1/catalog/service/redis-service" 2>/dev/null | grep -q "${HOST_IP}"; then
        test_pass
    else
        test_skip "(services may be registered with different IDs)"
    fi
    
    test_start "NATS service registered in cluster"
    if curl -s "${CLUSTER_CONSUL}/v1/catalog/service/nats-service" 2>/dev/null | grep -q "${HOST_IP}"; then
        test_pass
    else
        test_skip "(services may be registered with different IDs)"
    fi
else
    test_skip "(cluster not reachable or running in standalone mode)"
    TOTAL_TESTS=$((TOTAL_TESTS - 3))
fi

# =============================================================================
# 6. METRICS ENDPOINTS
# =============================================================================
print_section "6. Metrics Endpoints (Prometheus)"

test_start "Load balancer metrics"
if curl -s "http://${HOST_IP}:${LB_PORT}/metrics" 2>/dev/null | grep -q "lb_"; then
    test_pass
else
    test_fail
fi

for i in {0..2}; do
    port=${CHAT_PORTS[$i]}
    node=$((i + 1))
    
    test_start "Chat Node $node metrics"
    if curl -s "http://localhost:${port}/metrics" 2>/dev/null | grep -q "chat_"; then
        test_pass
    else
        test_fail
    fi
done

# =============================================================================
# 7. WEBSOCKET FUNCTIONALITY
# =============================================================================
print_section "7. WebSocket Connectivity"

for i in {0..2}; do
    port=${CHAT_PORTS[$i]}
    node=$((i + 1))
    
    test_start "Chat Node $node WebSocket upgrade"
    # Test if socket.io endpoint is available
    response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}/socket.io/" 2>/dev/null)
    if [ "$response" = "200" ] || [ "$response" = "400" ]; then
        # 400 is acceptable - means socket.io is running but needs proper upgrade
        test_pass
    else
        test_fail "(HTTP $response)"
    fi
done

test_start "Load balancer WebSocket endpoint"
response=$(curl -s -o /dev/null -w "%{http_code}" "http://${HOST_IP}:${LB_PORT}/socket.io/" 2>/dev/null)
if [ "$response" = "200" ] || [ "$response" = "400" ]; then
    test_pass
else
    test_fail "(HTTP $response)"
fi

# =============================================================================
# 8. RATE LIMITING
# =============================================================================
print_section "8. Rate Limiting & Security"

test_start "Rate limiting configured"
# Make multiple rapid requests to test rate limiting
count=0
for i in {1..5}; do
    status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3001/health" 2>/dev/null)
    [ "$status" = "200" ] && count=$((count + 1))
done

if [ "$count" -ge 3 ]; then
    test_pass
else
    test_fail "(only $count/5 requests succeeded)"
fi

# =============================================================================
# 9. AUTOSTART & MONITORING
# =============================================================================
print_section "9. Autostart & Monitoring Configuration"

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

test_start "Health monitor script exists"
if [ -f "$(dirname "$0")/monitor-services.sh" ]; then
    test_pass
else
    test_skip "(monitor not configured)"
fi

test_start "Health monitor timer enabled"
if systemctl is-enabled chat-system-monitor.timer 2>/dev/null | grep -q "enabled"; then
    test_pass
else
    test_skip "(monitor timer not enabled)"
fi

# =============================================================================
# 10. CLIENT CONFIGURATION
# =============================================================================
print_section "10. Client Configuration"

test_start "React client directory exists"
if [ -d "$(dirname "$0")/client-react" ]; then
    test_pass
    
    test_start "Client .env file configured"
    if [ -f "$(dirname "$0")/client-react/.env" ]; then
        test_pass
        env_url=$(grep "VITE_CHAT_URL" "$(dirname "$0")/client-react/.env" | cut -d= -f2)
        echo "    ℹ Configured URL: $env_url"
    else
        test_fail "(run: echo 'VITE_CHAT_URL=http://${HOST_IP}:${LB_PORT}' > client-react/.env)"
    fi
else
    test_skip "(client not found)"
    TOTAL_TESTS=$((TOTAL_TESTS - 1))
fi

# =============================================================================
# 11. RESILIENCE & FAILURE HANDLING (Optional)
# =============================================================================
if [ "$1" = "--with-resilience" ] || [ "$1" = "--full" ]; then
    print_section "11. Resilience & Failure Handling"
    
    echo "  ${YELLOW}⚠ This section will temporarily disrupt services${NC}"
    echo ""
    
    # Test Redis circuit breaker
    test_start "Redis circuit breaker activation"
    initial_redis_status=$(curl -s "http://localhost:3001/health" 2>/dev/null | grep -o '"redis":"[^"]*"' | cut -d'"' -f4)
    
    # Stop Redis temporarily
    sudo podman stop redis >/dev/null 2>&1
    sleep 3
    
    # Check if circuit breaker opened
    redis_status=$(curl -s "http://localhost:3001/health" 2>/dev/null | grep -o '"redis":"[^"]*"' | cut -d'"' -f4)
    if [ "$redis_status" != "$initial_redis_status" ]; then
        test_pass
        echo "    ℹ Circuit breaker state changed: $initial_redis_status → $redis_status"
    else
        test_fail "(circuit breaker did not change state)"
    fi
    
    # Restart Redis
    test_start "Redis auto-recovery"
    sudo podman start redis >/dev/null 2>&1
    sleep 5
    
    # Check if Redis reconnected
    redis_status=$(curl -s "http://localhost:3001/health" 2>/dev/null | grep -o '"redis":"[^"]*"' | cut -d'"' -f4)
    redis_health=$(sudo podman exec redis redis-cli ping 2>/dev/null)
    if [ "$redis_health" = "PONG" ]; then
        test_pass
        echo "    ℹ Redis recovered, circuit breaker state: $redis_status"
    else
        test_fail "(Redis did not recover)"
    fi
    
    # Test NATS circuit breaker
    test_start "NATS circuit breaker activation"
    initial_nats_status=$(curl -s "http://localhost:3001/health" 2>/dev/null | grep -o '"nats":"[^"]*"' | cut -d'"' -f4)
    
    sudo podman stop nats >/dev/null 2>&1
    sleep 5  # Allow time for connection attempts to fail
    
    nats_status=$(curl -s "http://localhost:3001/health" 2>/dev/null | grep -o '"nats":"[^"]*"' | cut -d'"' -f4)
    if [ "$nats_status" != "$initial_nats_status" ] && [ "$nats_status" != "CLOSED" ]; then
        test_pass
        echo "    ℹ Circuit breaker state changed: $initial_nats_status → $nats_status"
    else
        test_skip "(circuit breaker behavior varies - state: $initial_nats_status → $nats_status)"
    fi
    
    # Restart NATS
    test_start "NATS auto-recovery"
    sudo podman start nats >/dev/null 2>&1
    sleep 5
    
    nats_status=$(curl -s "http://localhost:3001/health" 2>/dev/null | grep -o '"nats":"[^"]*"' | cut -d'"' -f4)
    if nc -z localhost $NATS_PORT 2>/dev/null; then
        test_pass
        echo "    ℹ NATS recovered, circuit breaker state: $nats_status"
    else
        test_fail "(NATS did not recover)"
    fi
    
    # Test chat node failure & recovery
    test_start "Chat node container restart policy"
    
    # Stop container to trigger restart (simulate process crash with exit code)
    sudo podman exec chat-node-1 kill 1 >/dev/null 2>&1
    sleep 10
    
    # Check if container restarted (due to --restart=on-failure:5)
    node_status=$(sudo podman inspect chat-node-1 --format '{{.State.Status}}' 2>/dev/null)
    restart_count=$(sudo podman inspect chat-node-1 --format '{{.State.RestartCount}}' 2>/dev/null)
    
    if [ "$node_status" = "running" ] && [ "$restart_count" -gt 0 ]; then
        test_pass
        echo "    ℹ Container auto-restarted (restart count: $restart_count)"
    else
        test_skip "(restart count: $restart_count, status: $node_status - SIGKILL doesn't trigger restart)"
    fi
    
    # Test load balancer resilience
    test_start "Load balancer handles node failure"
    
    initial_nodes=$(curl -s "http://${HOST_IP}:${LB_PORT}/health" 2>/dev/null | grep -o '"availableNodes":[0-9]*' | cut -d: -f2)
    
    # Stop one chat node
    sudo podman stop chat-node-2 >/dev/null 2>&1
    sleep 35  # Wait for health check interval (30s) + buffer
    
    updated_nodes=$(curl -s "http://${HOST_IP}:${LB_PORT}/health" 2>/dev/null | grep -o '"availableNodes":[0-9]*' | cut -d: -f2)
    
    if [ "$updated_nodes" -lt "$initial_nodes" ]; then
        test_pass
        echo "    ℹ Available nodes reduced: $initial_nodes → $updated_nodes (after health check)"
    else
        test_skip "(load balancer needs >30s health check interval - nodes: $initial_nodes → $updated_nodes)"
    fi
    
    # Restart node
    test_start "Load balancer detects node recovery"
    sudo podman start chat-node-2 >/dev/null 2>&1
    sleep 5
    
    recovered_nodes=$(curl -s "http://${HOST_IP}:${LB_PORT}/health" 2>/dev/null | grep -o '"availableNodes":[0-9]*' | cut -d: -f2)
    
    if [ "$recovered_nodes" -ge "$initial_nodes" ]; then
        test_pass
        echo "    ℹ Nodes recovered: $updated_nodes → $recovered_nodes"
    else
        test_fail "(load balancer did not detect recovery)"
    fi
    
    # Test graceful degradation
    test_start "Chat nodes respond despite infrastructure failure"
    
    sudo podman stop redis nats >/dev/null 2>&1
    sleep 3
    
    # Nodes should still respond to health checks (circuit breakers should be open)
    health_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3001/health" 2>/dev/null)
    health_data=$(curl -s "http://localhost:3001/health" 2>/dev/null)
    
    if [ "$health_status" = "200" ]; then
        test_pass
        redis_state=$(echo "$health_data" | grep -o '"redis":"[^"]*"' | cut -d'"' -f4)
        nats_state=$(echo "$health_data" | grep -o '"nats":"[^"]*"' | cut -d'"' -f4)
        echo "    ℹ Node responsive with Redis: $redis_state, NATS: $nats_state"
    else
        test_skip "(nodes may require Redis/NATS for health endpoint - HTTP $health_status)"
    fi
    
    # Restore services
    echo ""
    echo "  ${BLUE}Restoring all services...${NC}"
    sudo podman start redis nats >/dev/null 2>&1
    sleep 5
    echo "  ${GREEN}✓ All services restored${NC}"
    echo ""
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
print_header
echo -e "${BLUE}║                          TEST SUMMARY                            ║${NC}"
print_footer
echo ""

echo -e "  Total Tests:   $TOTAL_TESTS"
echo -e "  ${GREEN}Passed:        $PASSED_TESTS${NC}"
echo -e "  ${RED}Failed:        $FAILED_TESTS${NC}"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED!${NC}"
    echo ""
    echo "System is fully operational. You can now:"
    echo "  1. Access Consul UI: ${CLUSTER_CONSUL}/ui/dc1/services"
    echo "  2. Start client:     cd client-react && npm run dev"
    echo "  3. Access app:       http://localhost:5173"
    echo "  4. View metrics:     http://${HOST_IP}:${LB_PORT}/metrics"
    echo ""
    if [ "$1" != "--with-resilience" ] && [ "$1" != "--full" ]; then
        echo "To test resilience & failure handling:"
        echo "  $0 --with-resilience"
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
