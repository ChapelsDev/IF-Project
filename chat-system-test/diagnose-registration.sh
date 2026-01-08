#!/bin/bash

# Diagnostic script for chat system registration issues

CONSUL_IP=${1:-"192.168.100.53"}
CONSUL_URL="http://${CONSUL_IP}:8500"

echo "=== Chat System Registration Diagnostics ==="
echo ""
echo "Consul Server: $CONSUL_URL"
echo ""

# Test Consul connectivity
echo "1. Testing Consul connectivity..."
if curl -sf "$CONSUL_URL/v1/status/leader" > /dev/null 2>&1; then
    echo "   ✓ Consul is reachable"
else
    echo "   ❌ Cannot reach Consul at $CONSUL_URL"
    echo "   Please verify:"
    echo "   - Consul is running"
    echo "   - Firewall allows port 8500"
    echo "   - IP address is correct"
    exit 1
fi
echo ""

# Check running containers
echo "2. Checking running chat-node containers..."
CONTAINERS=$(sudo podman ps --filter "name=chat-node" --format "{{.Names}}")
if [ -z "$CONTAINERS" ]; then
    echo "   ❌ No chat-node containers are running"
    echo "   Run: ./chat-system.sh start --cluster --cluster-consul $CONSUL_URL"
    exit 1
fi

echo "   Found containers:"
for container in $CONTAINERS; do
    echo "   - $container"
done
echo ""

# Check environment variables in containers
echo "3. Checking container environment variables..."
for container in $CONTAINERS; do
    echo "   === $container ==="
    sudo podman exec "$container" env | grep -E "CONSUL_URL|SERVICE_ID|HOST_IP|PORT|CLUSTER_MODE|NODE_ID" | sort
    echo ""
done

# Check if containers can reach Consul
echo "4. Testing Consul connectivity from containers..."
for container in $CONTAINERS; do
    echo "   === $container ==="
    if sudo podman exec "$container" curl -sf "$CONSUL_URL/v1/status/leader" > /dev/null 2>&1; then
        echo "   ✓ Can reach Consul"
    else
        echo "   ❌ Cannot reach Consul from container"
        echo "   Check network configuration (should use --network host)"
    fi
done
echo ""

# Check container logs for registration messages
echo "5. Checking container logs for registration..."
for container in $CONTAINERS; do
    echo "   === $container ==="
    echo "   Last 30 lines:"
    sudo podman logs --tail 30 "$container" 2>&1 | grep -E "Registering|Registered|Failed to register|CONSUL|SERVICE_ID"
    echo ""
done

# Check what's actually registered in Consul
echo "6. Services registered in Consul..."
echo "   === chat-service instances ==="
curl -s "$CONSUL_URL/v1/catalog/service/chat-service" | jq -r '.[] | "   - ID: \(.ServiceID), Address: \(.ServiceAddress):\(.ServicePort), Node: \(.Node)"'
echo ""
echo "   === redis-service instances ==="
curl -s "$CONSUL_URL/v1/catalog/service/redis-service" | jq -r '.[] | "   - ID: \(.ServiceID), Address: \(.ServiceAddress):\(.ServicePort), Node: \(.Node)"'
echo ""
echo "   === nats-service instances ==="
curl -s "$CONSUL_URL/v1/catalog/service/nats-service" | jq -r '.[] | "   - ID: \(.ServiceID), Address: \(.ServiceAddress):\(.ServicePort), Node: \(.Node)"'
echo ""

# Check health status
echo "7. Health status of registered services..."
echo "   === Passing health checks ==="
curl -s "$CONSUL_URL/v1/health/state/passing" | jq -r '.[] | select(.ServiceName | test("chat|redis|nats")) | "   - \(.ServiceID) (\(.ServiceName)): \(.Status)"'
echo ""
echo "   === Failing health checks ==="
curl -s "$CONSUL_URL/v1/health/state/critical" | jq -r '.[] | select(.ServiceName | test("chat|redis|nats")) | "   - \(.ServiceID) (\(.ServiceName)): \(.Status) - \(.Output)"'
echo ""

echo "=== Diagnostics Complete ==="
echo ""
echo "Expected service IDs should look like:"
echo "  - chat-node-192-168-X-X-1"
echo "  - redis-192-168-X-X"
echo "  - nats-192-168-X-X"
echo ""
echo "If services are not appearing:"
echo "1. Rebuild the image: ./chat-system.sh build"
echo "2. Restart with cluster mode: ./chat-system.sh start --cluster --cluster-consul $CONSUL_URL"
echo "3. Check logs: sudo podman logs chat-node-1"
echo ""
echo "For more help, see: TROUBLESHOOTING-REGISTRATION.md"
