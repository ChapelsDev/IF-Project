#!/bin/bash

# Setup script for Consul cluster node with integrated chat stack
# Installs: Redis + NATS + Chat Node on each Consul server
# Run this on each Consul server machine

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}" >&2; }
print_info() { echo -e "${YELLOW}➜ $1${NC}"; }
print_header() { echo -e "${BLUE}$1${NC}"; }

# Configuration
INSTALL_DIR="/opt/chat-system"
REDIS_PORT=6379
NATS_PORT=4222
NATS_CLUSTER_PORT=6222
CHAT_PORT=3001
CLUSTER_NAME="chat-cluster"
AUTO_CLUSTER=false
CONSUL_DC=""

usage() {
    cat << EOF
Setup Consul Chat Stack (Redis + NATS + Chat Node)

This script installs a complete chat stack on each Consul server:
  - Local Redis instance (port 6379)
  - Local NATS instance (port 4222)
  - Chat node (port 3001)
  - All start automatically with Consul

Usage: $0 [options]

Options:
    --redis-port <port>        Redis port (default: 6379)
    --nats-port <port>         NATS client port (default: 4222)
    --nats-cluster-port <port> NATS cluster port (default: 6222)
    --chat-port <port>         Chat node port (default: 3001)
    --auto-cluster             Automatically discover and cluster NATS nodes via Consul
    --consul-dc <name>         Consul datacenter name (for auto-cluster)
    --help                     Show this help

Example:
    # Simple install (manual NATS clustering)
    $0

    # Automatic NATS clustering via Consul service discovery
    $0 --auto-cluster

    # Custom ports
    $0 --chat-port 3002 --auto-cluster

This will:
  1. Install Redis, NATS, and Chat Node as systemd services
  2. All services start automatically with Consul
  3. Auto-restart on failure
  4. Chat node connects to LOCAL Redis and NATS
  5. Register all services with Consul
  6. (Optional) Auto-configure NATS clustering
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --redis-port)
            REDIS_PORT="$2"
            shift 2
            ;;
        --nats-port)
            NATS_PORT="$2"
            shift 2
            ;;
        --nats-cluster-port)
            NATS_CLUSTER_PORT="$2"
            shift 2
            ;;
        --chat-port)
            CHAT_PORT="$2"
            shift 2
            ;;
        --auto-cluster)
            AUTO_CLUSTER=true
            shift
            ;;
        --consul-dc)
            CONSUL_DC="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

print_header "======================================"
print_header "Consul Chat Stack Setup"
print_header "======================================"
echo ""
print_info "Redis port: $REDIS_PORT (local)"
print_info "NATS port: $NATS_PORT (local)"
print_info "Chat port: $CHAT_PORT"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root or with sudo"
    exit 1
fi

# Check dependencies
print_info "Checking dependencies..."
if ! command -v podman &> /dev/null; then
    print_error "Podman not found. Installing..."
    apt-get update
    apt-get install -y podman
fi
print_success "Podman installed"

# Check and setup Consul
if ! command -v consul &> /dev/null; then
    print_info "Consul not found. Installing..."
    
    # Detect architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) CONSUL_ARCH="amd64" ;;
        aarch64) CONSUL_ARCH="arm64" ;;
        armv7l) CONSUL_ARCH="arm" ;;
        *) print_error "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    
    # Download and install Consul
    CONSUL_VERSION="1.16.0"
    cd /tmp
    wget -q "https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_${CONSUL_ARCH}.zip"
    unzip -q consul_${CONSUL_VERSION}_linux_${CONSUL_ARCH}.zip
    mv consul /usr/local/bin/
    chmod +x /usr/local/bin/consul
    rm consul_${CONSUL_VERSION}_linux_${CONSUL_ARCH}.zip
    
    print_success "Consul installed"
else
    print_success "Consul found"
fi

# Check if Consul service is running or starting
CONSUL_STATE=$(systemctl is-active consul 2>/dev/null || echo "inactive")
if [[ "$CONSUL_STATE" != "active" && "$CONSUL_STATE" != "activating" ]]; then
    print_info "Consul not running. Setting up..."
    
    # Create Consul user and directories
    if ! id -u consul &> /dev/null; then
        useradd --system --home /etc/consul.d --shell /bin/false consul
    fi
    
    mkdir -p /opt/consul /etc/consul.d
    chown -R consul:consul /opt/consul /etc/consul.d
    
    # Get primary non-localhost IP
    BIND_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)
    if [ -z "$BIND_IP" ]; then
        BIND_IP="127.0.0.1"
    fi
    
    print_info "Binding Consul to: $BIND_IP"
    
    # Create basic Consul configuration
    cat > /etc/consul.d/consul.hcl << EOF
datacenter = "dc1"
data_dir = "/opt/consul"
client_addr = "0.0.0.0"
bind_addr = "$BIND_IP"
advertise_addr = "$BIND_IP"
ui_config {
  enabled = true
}
server = true
bootstrap_expect = 1
EOF
    
    # Create systemd service
    cat > /etc/systemd/system/consul.service << 'EOF'
[Unit]
Description=Consul
Documentation=https://www.consul.io/
Requires=network-online.target
After=network-online.target

[Service]
Type=simple
User=consul
Group=consul
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
KillSignal=SIGTERM
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
    
    # Start Consul
    systemctl daemon-reload
    systemctl enable consul
    systemctl start consul
    
    # Wait for Consul to be ready
    print_info "Waiting for Consul to start..."
    for i in {1..60}; do
        if curl -s http://localhost:8500/v1/status/leader 2>/dev/null | grep -q ":"; then
            break
        fi
        sleep 1
    done
    
    # Verify Consul is actually responsive
    if ! curl -s http://localhost:8500/v1/status/leader 2>/dev/null | grep -q ":"; then
        print_error "Consul API not responding after 60 seconds"
        print_info "Check status: systemctl status consul"
        print_info "Check logs: journalctl -u consul -n 50"
        exit 1
    fi
    
    print_success "Consul started"
else
    if [ "$CONSUL_STATE" = "activating" ]; then
        print_info "Consul is starting, waiting for it to be ready..."
        # Wait for it to become fully active
        for i in {1..30}; do
            if curl -s http://localhost:8500/v1/status/leader 2>/dev/null | grep -q ":"; then
                break
            fi
            sleep 1
        done
    fi
    print_success "Consul service is running"
fi

# Final check - verify Consul API is responding
if ! curl -s http://localhost:8500/v1/status/leader 2>/dev/null | grep -q ":"; then
    print_error "Consul API not responding"
    print_info "Check status: systemctl status consul"
    print_info "Check logs: journalctl -u consul -n 50"
    exit 1
fi
print_success "Consul API is ready"

# Create installation directory
print_info "Creating installation directory..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Copy chat-node source (if not already there)
if [ ! -d "$INSTALL_DIR/chat-node" ]; then
    print_info "Copying chat-node source..."
    if [ -d "/home/$SUDO_USER/Documents/UA/IF/chat-system-test/chat-node" ]; then
        cp -r "/home/$SUDO_USER/Documents/UA/IF/chat-system-test/chat-node" "$INSTALL_DIR/"
    else
        print_error "Chat node source not found. Please copy it to $INSTALL_DIR/chat-node"
        exit 1
    fi
fi

# Build chat node image
print_info "Building chat node image..."
cd "$INSTALL_DIR/chat-node"
podman build -t localhost/chat-node:latest . > /dev/null 2>&1
print_success "Chat node image built"

# Get hostname for NODE_ID
HOSTNAME=$(hostname)

# Get local IP for NATS clustering
LOCAL_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)

# Discover other NATS nodes via Consul if auto-cluster enabled
NATS_ROUTES=""
if [ "$AUTO_CLUSTER" = true ]; then
    print_info "Auto-discovering NATS nodes via Consul..."
    
    # Wait a moment for Consul to be fully ready
    sleep 2
    
    # Query Consul for chat-nats service
    CONSUL_QUERY="http://localhost:8500/v1/catalog/service/chat-nats"
    if [ -n "$CONSUL_DC" ]; then
        CONSUL_QUERY="${CONSUL_QUERY}?dc=${CONSUL_DC}"
    fi
    
    # Get all NATS nodes from Consul (might be empty on first node)
    NATS_NODES=$(curl -s "$CONSUL_QUERY" 2>/dev/null | grep -o '"Address":"[^"]*"' | cut -d'"' -f4 | grep -v "^$" || echo "")
    
    if [ -n "$NATS_NODES" ]; then
        # Build routes string, excluding local IP
        ROUTES_ARRAY=()
        while IFS= read -r node_ip; do
            if [ "$node_ip" != "$LOCAL_IP" ] && [ -n "$node_ip" ]; then
                ROUTES_ARRAY+=("nats://${node_ip}:${NATS_CLUSTER_PORT}")
            fi
        done <<< "$NATS_NODES"
        
        if [ ${#ROUTES_ARRAY[@]} -gt 0 ]; then
            NATS_ROUTES=$(IFS=,; echo "${ROUTES_ARRAY[*]}")
            print_success "Found ${#ROUTES_ARRAY[@]} existing NATS node(s)"
            print_info "Routes: $NATS_ROUTES"
        else
            print_info "First NATS node in cluster (no peers yet)"
        fi
    else
        print_info "First NATS node in cluster (no peers yet)"
    fi
fi

# Create Redis systemd service
print_info "Installing Redis service..."
cat > "/etc/systemd/system/chat-redis.service" << EOF
[Unit]
Description=Redis for Chat System
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/podman run --rm --name chat-redis --network host \
    docker.io/redis:7-alpine redis-server --port $REDIS_PORT --bind 0.0.0.0 --protected-mode no

ExecStop=/usr/bin/podman stop chat-redis
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
print_success "Redis service created"

# Create NATS systemd service
print_info "Installing NATS service..."

# Build NATS command with clustering if enabled
NATS_CMD="/usr/bin/podman run --rm --name chat-nats --network host docker.io/nats:2.10-alpine -p $NATS_PORT"

if [ "$AUTO_CLUSTER" = true ]; then
    NATS_CMD="${NATS_CMD} --cluster_name ${CLUSTER_NAME} --cluster nats://0.0.0.0:${NATS_CLUSTER_PORT}"
    if [ -n "$NATS_ROUTES" ]; then
        NATS_CMD="${NATS_CMD} --routes ${NATS_ROUTES}"
    fi
    print_info "NATS clustering enabled (cluster: ${CLUSTER_NAME}, port: ${NATS_CLUSTER_PORT})"
fi

cat > "/etc/systemd/system/chat-nats.service" << EOF
[Unit]
Description=NATS for Chat System
After=network-online.target consul.service
Wants=network-online.target
Requires=consul.service

[Service]
Type=simple
User=root
ExecStart=${NATS_CMD}
ExecStop=/usr/bin/podman stop chat-nats
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
print_success "NATS service created"

# Create Chat Node systemd service
print_info "Installing Chat Node service..."
cat > "/etc/systemd/system/chat-node.service" << EOF
[Unit]
Description=Distributed Chat Node
After=network-online.target consul.service chat-redis.service chat-nats.service
Wants=network-online.target
Requires=consul.service chat-redis.service chat-nats.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
Environment="NODE_ID=$HOSTNAME"
Environment="PORT=${CHAT_PORT}"
Environment="REDIS_URL=redis://localhost:${REDIS_PORT}"
Environment="NATS_URL=nats://localhost:${NATS_PORT}"
Environment="CONSUL_URL=http://localhost:8500"

ExecStart=/usr/bin/podman run --rm --name chat-node-$HOSTNAME --network host \
    -e NODE_ID=$HOSTNAME \
    -e PORT=${CHAT_PORT} \
    -e REDIS_URL=redis://localhost:${REDIS_PORT} \
    -e NATS_URL=nats://localhost:${NATS_PORT} \
    -e CONSUL_URL=http://localhost:8500 \
    localhost/chat-node:latest

ExecStop=/usr/bin/podman stop chat-node-$HOSTNAME
Restart=always
RestartSec=10
StartLimitBurst=5
StartLimitInterval=300

[Install]
WantedBy=multi-user.target
EOF
print_success "Chat Node service created"

# Register services with Consul
print_info "Registering services with Consul..."

# Register Redis service
curl -s -X PUT -d @- http://localhost:8500/v1/agent/service/register <<EOF
{
  "ID": "chat-redis-${HOSTNAME}",
  "Name": "chat-redis",
  "Tags": ["redis", "chat"],
  "Address": "${LOCAL_IP}",
  "Port": ${REDIS_PORT},
  "Check": {
    "TCP": "localhost:${REDIS_PORT}",
    "Interval": "10s",
    "Timeout": "2s"
  }
}
EOF

# Register NATS service
curl -s -X PUT -d @- http://localhost:8500/v1/agent/service/register <<EOF
{
  "ID": "chat-nats-${HOSTNAME}",
  "Name": "chat-nats",
  "Tags": ["nats", "chat", "cluster"],
  "Address": "${LOCAL_IP}",
  "Port": ${NATS_PORT},
  "Check": {
    "HTTP": "http://localhost:8222/healthz",
    "Interval": "10s",
    "Timeout": "2s"
  }
}
EOF

# Register Chat Node service
curl -s -X PUT -d @- http://localhost:8500/v1/agent/service/register <<EOF
{
  "ID": "chat-node-${HOSTNAME}",
  "Name": "chat-node",
  "Tags": ["chat", "websocket"],
  "Address": "${LOCAL_IP}",
  "Port": ${CHAT_PORT},
  "Check": {
    "HTTP": "http://localhost:${CHAT_PORT}/health",
    "Interval": "10s",
    "Timeout": "2s"
  }
}
EOF

print_success "Services registered with Consul"

# Reload systemd
print_info "Reloading systemd..."
systemctl daemon-reload
print_success "Systemd reloaded"

# Enable and start Redis
print_info "Starting Redis service..."
systemctl enable chat-redis.service
systemctl start chat-redis.service
sleep 2
if systemctl is-active --quiet chat-redis.service; then
    print_success "Redis is running"
else
    print_error "Redis failed to start"
    journalctl -u chat-redis.service -n 20
    exit 1
fi

# Enable and start NATS
print_info "Starting NATS service..."
systemctl enable chat-nats.service
systemctl start chat-nats.service
sleep 2
if systemctl is-active --quiet chat-nats.service; then
    print_success "NATS is running"
else
    print_error "NATS failed to start"
    journalctl -u chat-nats.service -n 20
    exit 1
fi

# Enable and start Chat Node
print_info "Starting Chat Node service..."
systemctl enable chat-node.service
systemctl start chat-node.service
sleep 3
if systemctl is-active --quiet chat-node.service; then
    print_success "Chat Node is running"
else
    print_error "Chat Node failed to start"
    journalctl -u chat-node.service -n 20
    exit 1
fi

echo ""
print_header "======================================"
print_success "Setup Complete!"
print_header "======================================"
echo ""
echo "Services running on this machine:"
echo "  - Redis:      localhost:$REDIS_PORT"
echo "  - NATS:       localhost:$NATS_PORT"
echo "  - Chat Node:  localhost:$CHAT_PORT"
echo "  - Node ID:    $HOSTNAME"
echo ""
echo "Service management:"
echo "  systemctl status chat-redis    # Redis status"
echo "  systemctl status chat-nats     # NATS status"
echo "  systemctl status chat-node     # Chat Node status"
echo ""
echo "View logs:"
echo "  journalctl -u chat-redis -f"
echo "  journalctl -u chat-nats -f"
echo "  journalctl -u chat-node -f"
echo ""
echo "All services will automatically:"
echo "  - Start when the server boots (after Consul)"
echo "  - Restart if they crash"
echo "  - Register with local Consul agent"
echo ""
if [ "$AUTO_CLUSTER" = true ]; then
    echo "NATS clustering: ENABLED"
    echo "  Cluster name: ${CLUSTER_NAME}"
    echo "  Cluster port: ${NATS_CLUSTER_PORT}"
    if [ -n "$NATS_ROUTES" ]; then
        echo "  Connected to: ${NATS_ROUTES}"
    else
        echo "  Status: First node (waiting for peers)"
    fi
    echo ""
    echo "New nodes will automatically join the cluster."
    echo "Check cluster: curl http://localhost:8222/routez"
else
    echo "NATS clustering: MANUAL"
    echo "  Configure clustering with:"
    echo "  sudo systemctl stop chat-nats"
    echo "  # Edit /etc/systemd/system/chat-nats.service"
    echo "  sudo systemctl daemon-reload && sudo systemctl start chat-nats"
fi
echo ""
echo "Consul service discovery: http://localhost:8500/ui/services"
