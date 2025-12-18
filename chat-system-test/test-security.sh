#!/bin/bash
# Security and Redundancy Testing Script for Chat Service

set -e

echo "🔒 Chat Service Security & Redundancy Tests"
echo "==========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CHAT_NODE_1="http://localhost:3001"
CHAT_NODE_2="http://localhost:3002"
CHAT_NODE_3="http://localhost:3003"

# Test 1: Health Checks
echo -e "${YELLOW}Test 1: Health Check Endpoints${NC}"
for port in 3001 3002 3003; do
    echo -n "  Node on port $port: "
    response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$port/health)
    if [ "$response" == "200" ]; then
        echo -e "${GREEN}✓ Healthy${NC}"
        curl -s http://localhost:$port/health | jq -c '{status, nodeId, connections, redis, nats}'
    else
        echo -e "${RED}✗ Unhealthy (HTTP $response)${NC}"
    fi
done
echo ""

# Test 2: Readiness Checks
echo -e "${YELLOW}Test 2: Readiness Check Endpoints${NC}"
for port in 3001 3002 3003; do
    echo -n "  Node on port $port: "
    response=$(curl -s http://localhost:$port/ready | jq -r '.ready')
    if [ "$response" == "true" ]; then
        echo -e "${GREEN}✓ Ready${NC}"
    else
        echo -e "${RED}✗ Not Ready${NC}"
    fi
done
echo ""

# Test 3: Circuit Breaker States
echo -e "${YELLOW}Test 3: Circuit Breaker States${NC}"
for port in 3001 3002 3003; do
    echo "  Node on port $port:"
    health=$(curl -s http://localhost:$port/health)
    redis_state=$(echo $health | jq -r '.redis')
    nats_state=$(echo $health | jq -r '.nats')
    
    echo -n "    Redis: "
    if [ "$redis_state" == "CLOSED" ]; then
        echo -e "${GREEN}$redis_state${NC}"
    else
        echo -e "${RED}$redis_state${NC}"
    fi
    
    echo -n "    NATS:  "
    if [ "$nats_state" == "CLOSED" ]; then
        echo -e "${GREEN}$nats_state${NC}"
    else
        echo -e "${RED}$nats_state${NC}"
    fi
done
echo ""

# Test 4: Active Connections
echo -e "${YELLOW}Test 4: Active Connection Counts${NC}"
total_connections=0
for port in 3001 3002 3003; do
    connections=$(curl -s http://localhost:$port/health | jq -r '.connections')
    echo "  Node on port $port: $connections connections"
    total_connections=$((total_connections + connections))
done
echo "  ${GREEN}Total: $total_connections connections${NC}"
echo ""

# Test 5: Input Sanitization
echo -e "${YELLOW}Test 5: Input Sanitization (Manual Test Required)${NC}"
echo "  To test XSS prevention, try sending:"
echo "    Username: <script>alert('xss')</script>"
echo "    Message: <img src=x onerror=alert('xss')>"
echo "  Expected: Should be encoded/rejected"
echo ""

# Test 6: Rate Limiting
echo -e "${YELLOW}Test 6: Rate Limiting Test${NC}"
echo "  Simulating rapid requests..."
echo "  Note: This requires a WebSocket client. Use the React client to test."
echo "  Expected: After 60 messages/min, should receive 'Rate limit exceeded' error"
echo ""

# Test 7: Service Discovery
echo -e "${YELLOW}Test 7: Service Discovery (Consul)${NC}"
if command -v consul &> /dev/null; then
    echo "  Registered services:"
    consul catalog services | while read service; do
        echo "    - $service"
    done
else
    echo "  Querying Consul HTTP API:"
    curl -s http://localhost:8500/v1/catalog/services | jq -r 'keys[]' | while read service; do
        echo "    - $service"
    done
fi
echo ""

# Test 8: Graceful Shutdown (Simulation)
echo -e "${YELLOW}Test 8: Graceful Shutdown Test${NC}"
echo "  To test graceful shutdown:"
echo "    1. Connect clients to a node"
echo "    2. Send SIGTERM: docker kill -s SIGTERM <container>"
echo "    3. Observe: Clients receive 'serverShutdown' event"
echo "    4. Verify: Health check returns 503 during shutdown"
echo "    5. Confirm: All connections closed gracefully"
echo ""

# Test 9: Load Distribution
echo -e "${YELLOW}Test 9: Load Distribution Across Nodes${NC}"
echo "  Connection distribution:"
for port in 3001 3002 3003; do
    connections=$(curl -s http://localhost:$port/health | jq -r '.connections')
    percentage=$((connections * 100 / (total_connections + 1)))
    bar=$(printf '█%.0s' $(seq 1 $((percentage / 5))))
    printf "  Port %d: %2d connections [%-20s] %d%%\n" $port $connections "$bar" $percentage
done
echo ""

# Test 10: Authentication (if enabled)
echo -e "${YELLOW}Test 10: Authentication${NC}"
if [ "$REQUIRE_AUTH" == "true" ]; then
    echo "  Authentication: ${GREEN}ENABLED${NC}"
    echo "  To test:"
    echo "    1. Connect without token -> Should be rejected"
    echo "    2. Connect with invalid token -> Should be rejected"
    echo "    3. Connect with valid token -> Should succeed"
else
    echo "  Authentication: ${YELLOW}DISABLED (Development Mode)${NC}"
    echo "  To enable: Set REQUIRE_AUTH=true in environment"
fi
echo ""

# Summary
echo "==========================================="
echo -e "${GREEN}✓ Security & Redundancy Test Suite Complete${NC}"
echo ""
echo "Next Steps:"
echo "  1. Review any RED warnings above"
echo "  2. Test with actual WebSocket clients"
echo "  3. Simulate failures (stop Redis/NATS containers)"
echo "  4. Monitor circuit breaker state transitions"
echo "  5. Test graceful shutdown with active connections"
echo ""
echo "For detailed documentation, see: SECURITY-AND-REDUNDANCY.md"
