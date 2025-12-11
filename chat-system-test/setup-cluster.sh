#!/bin/bash

# Setup script for chat system cluster integration
# This script helps prepare the environment for cluster integration

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_header() {
    echo -e "${YELLOW}$1${NC}"
}

echo ""
print_header "======================================"
print_header "Chat System - Cluster Integration Setup"
print_header "======================================"
echo ""

# Check Python
print_info "Checking Python installation..."
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version | cut -d' ' -f2)
    print_success "Python $PYTHON_VERSION installed"
else
    print_error "Python 3 not found. Please install Python 3.x"
    exit 1
fi

# Check pip
print_info "Checking pip installation..."
if command -v pip3 &> /dev/null; then
    print_success "pip3 installed"
else
    print_error "pip3 not found. Installing..."
    sudo apt-get update && sudo apt-get install -y python3-pip || \
    sudo yum install -y python3-pip || \
    sudo dnf install -y python3-pip
fi

# Install requests library
print_info "Installing Python dependencies..."
pip3 install --user requests
print_success "Python requests library installed"

# Check for cluster_helper.py
print_info "Checking for cluster_helper.py..."
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ -f "${SCRIPT_DIR}/cluster_helper.py" ]; then
    print_success "cluster_helper.py found"
else
    print_info "cluster_helper.py not found in current directory"
    echo ""
    echo "To use cluster integration, you need the cluster_helper.py file from the"
    echo "Cluster Platform team. Options:"
    echo ""
    echo "1. Copy cluster_helper.py to this directory:"
    echo "   cp /path/to/cluster_helper.py ${SCRIPT_DIR}/"
    echo ""
    echo "2. Or add the cluster helper directory to PYTHONPATH:"
    echo "   export PYTHONPATH=/path/to/cluster_helper:\$PYTHONPATH"
    echo ""
    echo "3. Or install it as a package (if available)"
    echo ""
fi

# Check curl
print_info "Checking curl installation..."
if command -v curl &> /dev/null; then
    print_success "curl installed"
else
    print_error "curl not found. Installing..."
    sudo apt-get install -y curl || sudo yum install -y curl || sudo dnf install -y curl
fi

# Check podman/docker
print_info "Checking container runtime..."
if command -v podman &> /dev/null; then
    print_success "Podman installed"
    CONTAINER_CMD="podman"
elif command -v docker &> /dev/null; then
    print_success "Docker installed"
    CONTAINER_CMD="docker"
else
    print_error "Neither Podman nor Docker found"
    echo "Please install Podman or Docker:"
    echo "  - Podman: sudo dnf install -y podman"
    echo "  - Docker: https://docs.docker.com/engine/install/"
    exit 1
fi

# Test cluster connectivity
echo ""
print_info "Testing cluster connectivity..."
CLUSTER_CONSUL="http://172.20.10.10:8500"

if curl -s --connect-timeout 2 "${CLUSTER_CONSUL}/v1/agent/self" > /dev/null 2>&1; then
    print_success "Main cluster Consul reachable at ${CLUSTER_CONSUL}"
    
    # Check for services
    SERVICES=$(curl -s "${CLUSTER_CONSUL}/v1/catalog/services" 2>/dev/null)
    if [ -n "$SERVICES" ]; then
        print_success "Cluster is operational"
        echo ""
        echo "Available services:"
        echo "$SERVICES" | python3 -m json.tool 2>/dev/null || echo "$SERVICES"
    fi
else
    print_info "Main cluster Consul not reachable (this is OK for standalone mode)"
    echo "   The system will run in standalone mode"
fi

# Build chat node image
echo ""
print_info "Checking chat node Docker image..."
if sudo ${CONTAINER_CMD} image exists localhost/chat-node:latest 2>/dev/null; then
    print_success "Chat node image exists"
    read -p "Rebuild image? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Building chat node image..."
        cd "${SCRIPT_DIR}/chat-node"
        sudo ${CONTAINER_CMD} build -t localhost/chat-node:latest .
        print_success "Chat node image built"
    fi
else
    print_info "Chat node image not found. Building..."
    cd "${SCRIPT_DIR}/chat-node"
    sudo ${CONTAINER_CMD} build -t localhost/chat-node:latest .
    print_success "Chat node image built"
fi

# Summary
echo ""
print_header "======================================"
print_header "Setup Complete!"
print_header "======================================"
echo ""
echo "You can now start the chat system:"
echo ""
echo "  Auto-discovery mode (recommended):"
echo "    ./chat-system.sh start --auto"
echo ""
echo "  Standalone mode:"
echo "    ./chat-system.sh start"
echo ""
echo "  Cluster mode (manual):"
echo "    ./chat-system.sh start --cluster --mode infrastructure"
echo ""
echo "For more information, see CLUSTER_INTEGRATION.md"
echo ""
