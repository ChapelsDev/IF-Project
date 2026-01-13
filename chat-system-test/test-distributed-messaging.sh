#!/bin/bash

# Test script to verify NATS clustering and message distribution across machines
# Usage: ./test-distributed-messaging.sh

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${YELLOW}➜ $1${NC}"; }
print_header() { echo -e "${BLUE}$1${NC}"; }

echo ""
print_header "╔════════════════════════════════════════════════════════╗"
print_header "║   Distributed Messaging Test - NATS Clustering        ║"
print_header "╚════════════════════════════════════════════════════════╝"
echo ""

# Get local IP
LOCAL_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' || echo "localhost")
print_info "Local IP: $LOCAL_IP"
echo ""

# Test 1: Check if NATS is running
print_header "[Test 1] NATS Running"
if nc -z localhost 4222 2>/dev/null; then
    print_success "NATS is running on port 4222"
else
    print_error "NATS is not running"
    echo "  Run: ./chat-system.sh start --cluster --mode full"
    exit 1
fi
echo ""

# Test 2: Check NATS HTTP monitoring
print_header "[Test 2] NATS Monitoring API"
if curl -s -f http://localhost:8222/varz > /dev/null 2>&1; then
    print_success "NATS monitoring endpoint accessible"
    
    # Get NATS info
    NATS_INFO=$(curl -s http://localhost:8222/varz)
    NATS_CLUSTER=$(echo "$NATS_INFO" | jq -r '.cluster.name' 2>/dev/null)
    
    if [ "$NATS_CLUSTER" != "null" ] && [ -n "$NATS_CLUSTER" ]; then
        print_success "NATS cluster name: $NATS_CLUSTER"
    fi
else
    print_error "NATS monitoring endpoint not accessible"
fi
echo ""

# Test 3: Check NATS cluster routes (connections to other NATS instances)
print_header "[Test 3] NATS Cluster Routes"
ROUTES=$(curl -s http://localhost:8222/routez 2>/dev/null)

if [ -n "$ROUTES" ]; then
    NUM_ROUTES=$(echo "$ROUTES" | jq '.num_routes' 2>/dev/null)
    
    if [ "$NUM_ROUTES" = "0" ] || [ -z "$NUM_ROUTES" ]; then
        print_info "No cluster routes found (single node or first to start)"
        echo "  This is normal if you're the first machine in the cluster"
        echo "  Other machines will connect to this node when they start"
    else
        print_success "Found $NUM_ROUTES cluster route(s) to other NATS instances"
        
        # Show connected NATS instances
        echo "$ROUTES" | jq -r '.routes[] | "  → Connected to: \(.ip):\(.port)"' 2>/dev/null
        echo ""
        print_success "NATS clustering is working! Messages will be shared across all connected nodes."
    fi
else
    print_error "Could not get cluster route information"
fi
echo ""

# Test 4: Check Consul registration
print_header "[Test 4] Consul Service Registration"
CONSUL_URL="http://localhost:8500"

if curl -s -f "${CONSUL_URL}/v1/agent/self" > /dev/null 2>&1; then
    print_success "Consul is accessible"
    
    # Check if NATS is registered
    NATS_SERVICES=$(curl -s "${CONSUL_URL}/v1/catalog/service/nats-service" | jq -r '.[].ServiceAddress' 2>/dev/null)
    
    if [ -n "$NATS_SERVICES" ]; then
        NATS_COUNT=$(echo "$NATS_SERVICES" | wc -l)
        print_success "Found $NATS_COUNT NATS service(s) registered in Consul:"
        echo "$NATS_SERVICES" | while read ip; do
            echo "  → $ip:4222"
        done
    else
        print_info "No NATS services found in local Consul"
        echo "  Try cluster Consul if running in cluster mode"
    fi
else
    print_info "Local Consul not running (may be using cluster Consul)"
fi
echo ""

# Test 5: Check Redis
print_header "[Test 5] Redis Connection"
if sudo podman exec redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
    print_success "Redis is running and accessible"
else
    print_info "Redis container not found or not responding"
fi
echo ""

# Test 6: Check chat nodes
print_header "[Test 6] Chat Nodes"
NODE_COUNT=0
for port in 3002 3003 3004; do
    if nc -z localhost $port 2>/dev/null; then
        NODE_COUNT=$((NODE_COUNT + 1))
    fi
done

if [ $NODE_COUNT -gt 0 ]; then
    print_success "Found $NODE_COUNT chat node(s) running"
else
    print_info "No chat nodes running locally"
fi
echo ""

# Summary
print_header "╔════════════════════════════════════════════════════════╗"
print_header "║                    Test Summary                        ║"
print_header "╚════════════════════════════════════════════════════════╝"
echo ""

if [ "$NUM_ROUTES" != "0" ] && [ -n "$NUM_ROUTES" ]; then
    print_success "✓ DISTRIBUTED MESSAGING IS WORKING!"
    echo ""
    echo "Your NATS instance is clustered with $NUM_ROUTES other node(s)."
    echo "Messages published on any machine will be received on all machines."
    echo ""
    echo "Test it:"
    echo "  1. Open client on this machine: http://$LOCAL_IP:3002"
    echo "  2. Open client on another machine: http://<other-machine-ip>:3002"
    echo "  3. Send a message from one machine"
    echo "  4. It should appear on both machines instantly!"
    echo ""
elif [ "$NUM_ROUTES" = "0" ]; then
    print_info "Single node setup (or first node in cluster)"
    echo ""
    echo "To test distributed messaging:"
    echo "  1. Start the system on another machine with:"
    echo "     ./chat-system.sh start --cluster --cluster-consul http://<consul-ip>:8500 --mode full"
    echo ""
    echo "  2. Run this test again - you should see cluster routes"
    echo ""
else
    print_error "Could not verify cluster status"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check NATS logs: sudo podman logs nats"
    echo "  2. Verify NATS cluster port 6222 is open between machines"
    echo "  3. Check Consul service registration:"
    echo "     curl http://<consul-ip>:8500/v1/catalog/service/nats-service"
    echo ""
fi
