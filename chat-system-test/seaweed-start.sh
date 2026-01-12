#!/bin/bash

# Simple SeaweedFS Startup Script for Chat System Testing
# This script starts SeaweedFS services in the background for quick testing

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
MASTER_PORT=9333
VOLUME_PORT=8080
FILER_PORT=8888
VOLUME_DIR="/tmp/seaweed-vol1"

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}➜ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

check_weed() {
    if ! command -v weed &> /dev/null; then
        print_error "SeaweedFS (weed) is not installed"
        echo ""
        echo "Install with:"
        echo "  wget https://github.com/seaweedfs/seaweedfs/releases/download/3.61/linux_amd64_full.tar.gz"
        echo "  tar -xzf linux_amd64_full.tar.gz"
        echo "  sudo mv weed /usr/local/bin/"
        exit 1
    fi
}

start_seaweed() {
    print_info "Starting SeaweedFS services..."
    
    # Check if already running
    if pgrep -f "weed master" > /dev/null; then
        print_error "SeaweedFS master is already running"
        echo "Run './seaweed-start.sh stop' first"
        exit 1
    fi
    
    # Create volume directory
    mkdir -p "$VOLUME_DIR"
    
    # Start master
    print_info "Starting SeaweedFS Master on port $MASTER_PORT..."
    weed master -port=$MASTER_PORT > /tmp/seaweed-master.log 2>&1 &
    echo $! > /tmp/seaweed-master.pid
    sleep 2
    
    if pgrep -f "weed master" > /dev/null; then
        print_success "Master started (PID: $(cat /tmp/seaweed-master.pid))"
    else
        print_error "Failed to start master. Check /tmp/seaweed-master.log"
        exit 1
    fi
    
    # Start volume
    print_info "Starting SeaweedFS Volume on port $VOLUME_PORT..."
    weed volume -port=$VOLUME_PORT -mserver=localhost:$MASTER_PORT -dir=$VOLUME_DIR > /tmp/seaweed-volume.log 2>&1 &
    echo $! > /tmp/seaweed-volume.pid
    sleep 2
    
    if pgrep -f "weed volume" > /dev/null; then
        print_success "Volume started (PID: $(cat /tmp/seaweed-volume.pid))"
    else
        print_error "Failed to start volume. Check /tmp/seaweed-volume.log"
        stop_seaweed
        exit 1
    fi
    
    # Start filer
    print_info "Starting SeaweedFS Filer on port $FILER_PORT..."
    weed filer -port=$FILER_PORT -master=localhost:$MASTER_PORT > /tmp/seaweed-filer.log 2>&1 &
    echo $! > /tmp/seaweed-filer.pid
    sleep 2
    
    if pgrep -f "weed filer" > /dev/null; then
        print_success "Filer started (PID: $(cat /tmp/seaweed-filer.pid))"
    else
        print_error "Failed to start filer. Check /tmp/seaweed-filer.log"
        stop_seaweed
        exit 1
    fi
    
    echo ""
    print_success "SeaweedFS is running!"
    echo ""
    echo "Services:"
    echo "  Master: http://localhost:$MASTER_PORT"
    echo "  Volume: http://localhost:$VOLUME_PORT"
    echo "  Filer:  http://localhost:$FILER_PORT"
    echo ""
    echo "Logs:"
    echo "  Master: /tmp/seaweed-master.log"
    echo "  Volume: /tmp/seaweed-volume.log"
    echo "  Filer:  /tmp/seaweed-filer.log"
    echo ""
    echo "To stop: ./seaweed-start.sh stop"
}

stop_seaweed() {
    print_info "Stopping SeaweedFS services..."
    
    # Stop processes
    if [ -f /tmp/seaweed-filer.pid ]; then
        kill $(cat /tmp/seaweed-filer.pid) 2>/dev/null || true
        rm /tmp/seaweed-filer.pid
        print_success "Filer stopped"
    fi
    
    if [ -f /tmp/seaweed-volume.pid ]; then
        kill $(cat /tmp/seaweed-volume.pid) 2>/dev/null || true
        rm /tmp/seaweed-volume.pid
        print_success "Volume stopped"
    fi
    
    if [ -f /tmp/seaweed-master.pid ]; then
        kill $(cat /tmp/seaweed-master.pid) 2>/dev/null || true
        rm /tmp/seaweed-master.pid
        print_success "Master stopped"
    fi
    
    # Kill any remaining processes
    pkill -f "weed master" 2>/dev/null || true
    pkill -f "weed volume" 2>/dev/null || true
    pkill -f "weed filer" 2>/dev/null || true
    
    print_success "SeaweedFS stopped"
}

status_seaweed() {
    echo "SeaweedFS Status:"
    echo ""
    
    if pgrep -f "weed master" > /dev/null; then
        print_success "Master: Running (PID: $(pgrep -f 'weed master'))"
        curl -s http://localhost:$MASTER_PORT/cluster/status | jq '.' 2>/dev/null || echo "  (jq not installed for pretty output)"
    else
        print_error "Master: Not running"
    fi
    
    echo ""
    
    if pgrep -f "weed volume" > /dev/null; then
        print_success "Volume: Running (PID: $(pgrep -f 'weed volume'))"
    else
        print_error "Volume: Not running"
    fi
    
    echo ""
    
    if pgrep -f "weed filer" > /dev/null; then
        print_success "Filer: Running (PID: $(pgrep -f 'weed filer'))"
        echo "  Filer URL: http://localhost:$FILER_PORT"
    else
        print_error "Filer: Not running"
    fi
}

logs_seaweed() {
    echo "SeaweedFS Logs:"
    echo ""
    echo "=== Master Log ==="
    tail -n 20 /tmp/seaweed-master.log 2>/dev/null || echo "No log file"
    echo ""
    echo "=== Volume Log ==="
    tail -n 20 /tmp/seaweed-volume.log 2>/dev/null || echo "No log file"
    echo ""
    echo "=== Filer Log ==="
    tail -n 20 /tmp/seaweed-filer.log 2>/dev/null || echo "No log file"
}

case "${1:-start}" in
    start)
        check_weed
        start_seaweed
        ;;
    stop)
        stop_seaweed
        ;;
    restart)
        stop_seaweed
        sleep 2
        check_weed
        start_seaweed
        ;;
    status)
        status_seaweed
        ;;
    logs)
        logs_seaweed
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs}"
        echo ""
        echo "Commands:"
        echo "  start   - Start SeaweedFS services"
        echo "  stop    - Stop SeaweedFS services"
        echo "  restart - Restart SeaweedFS services"
        echo "  status  - Check service status"
        echo "  logs    - View recent logs"
        exit 1
        ;;
esac
