# Distributed Chat System

Universal management script for distributed real-time chat with automatic service discovery, load balancing, and self-healing.

**Stack:** Node.js, Redis, NATS, Consul, Socket.IO, React

## ✨ One Script Does Everything

```bash
./chat-system.sh <command> [options]
```

All functionality is now in a single universal script. No need for separate setup scripts!

## 🚀 Quick Start

```bash
# Make executable  
chmod +x chat-system.sh

# Auto-discover and start
./chat-system.sh start --auto

# Start client
cd client-react && npm install && npm run dev
```

Access: http://localhost:5173

## 📋 Universal Script Commands

### Core Operations
- `start` - Start the chat system
- `stop` - Stop all services
- `restart` - Restart chat nodes
- `status` - Show system status
- `build` - Build Docker image

### System Management
- `setup-autostart` - Configure autostart & auto-recovery (requires sudo)
- `metrics [url] [port]` - Start metrics aggregation server
- `logs <service>` - View logs (redis|nats|consul|node-1|node-2|node-3|lb)
- `cluster-test [url]` - Test cluster connectivity
- `deregister [url]` - Deregister services from cluster
- `clear-usernames` - Clear all registered usernames

### Get Help
- `help` - Show detailed help

## 🎯 Common Use Cases

### Single Machine Development
```bash
./chat-system.sh start
cd client-react && npm run dev
```

### Production with Autostart
```bash
# Setup once
sudo ./chat-system.sh setup-autostart

# System now starts on boot and self-heals!
# Manage with: sudo systemctl start/stop/status chat-system
```

### Cluster with Load Balancer
```bash
./chat-system.sh start --cluster --mode full --with-lb --cluster-consul http://192.168.100.53:8500
```

### Start Metrics Monitoring
```bash
./chat-system.sh metrics http://192.168.100.53:8500 9090
```

## ⚙️ Start Options

- `--auto` - Auto-discover infrastructure (recommended)
- `--cluster` - Enable cluster mode
- `--cluster-consul <URL>` - Cluster Consul URL (default: http://192.168.100.53:8500)
- `--mode <mode>` - standalone|infrastructure|node-only|full|auto
- `--with-lb` - Start load balancer on port 3000
- `--nodes <count>` - Number of chat nodes (default: 3)

## 🏗️ Architecture

```
Load Balancer (3000) → Discovers nodes via Consul
        ↓
Chat Nodes (3001-3003) → Socket.IO gateways
        ↓
Redis (6379) + NATS (4222) → State & messaging
        ↓
Consul (8500) → Service discovery
```

| Component | Port | Purpose |
|-----------|------|---------|
| Redis | 6379 | Shared state & message history |
| NATS | 4222 | Pub/sub messaging between nodes |
| Consul | 8500 | Service discovery & health checks |
| Chat Nodes | 3001-3003 | Socket.IO gateways |
| Load Balancer | 3000 | Round-robin distribution |
| Metrics | 9090 | Aggregated Prometheus metrics |

## 🔄 Autostart & Auto-Recovery

### Continuous Monitoring Daemon

The system uses a **continuously running daemon** that monitors all services 24/7:

```bash
sudo ./chat-system.sh setup-autostart
```

**What the daemon does:**
- ✅ Starts all services on boot
- ✅ Monitors health **every 30 seconds**
- ✅ Automatically restarts unhealthy containers
- ✅ Recreates failed containers if restart doesn't work
- ✅ Prevents restart loops with 60s cooldown periods
- ✅ Logs all actions to `/var/log/chat-system-daemon.log`

**Unlike traditional oneshot services**, this daemon stays active and provides intelligent recovery.

### Manage After Setup

```bash
# Control daemon
sudo systemctl start chat-system
sudo systemctl stop chat-system  
sudo systemctl restart chat-system
sudo systemctl status chat-system

# View daemon logs
sudo tail -f /var/log/chat-system-daemon.log

# View systemd journal
sudo journalctl -u chat-system -f

# Check status with daemon info
./chat-system.sh status
```

### What Gets Auto-Recovered

| Scenario | Daemon Response | Time to Recover |
|----------|----------------|-----------------|
| Container stopped | Restarts container | 30-60s |
| Health check fails | Restarts container | 30-60s |
| Restart fails | Recreates from scratch | 30-90s |
| Server reboots | Starts all services | On boot |
| Network issues | Circuit breakers + reconnect | Automatic |

### How Recovery Works

1. **Detection:** Daemon checks every 30s
2. **Restart:** Attempts to restart unhealthy container
3. **Recreate:** If restart fails, removes and recreates container
4. **Cooldown:** Waits 60s before next restart to prevent loops
5. **Logging:** All actions logged with timestamps

### Health Check Configuration

All containers have health checks:
- **Interval:** 30 seconds
- **Timeout:** 5-10 seconds  
- **Retries:** 3 failures before marked unhealthy
- **Start period:** 15 seconds (for chat nodes)
- **Restart policy:** on-failure:5 (max 5 auto-restarts)

## 📊 Monitoring

### Test Suite

Comprehensive testing script validates all components:

```bash
# Quick validation (all functional tests)
./test-system.sh

# Full resilience testing (includes disruptive failure tests)
./test-system.sh --with-resilience
```

**Test Coverage (36+ tests):**
- Container health (Redis, NATS, chat nodes, load balancer)
- Infrastructure connectivity
- HTTP health endpoints
- Load balancer node discovery
- Cluster integration and service registration
- Prometheus metrics endpoints
- WebSocket connectivity
- Rate limiting
- Autostart configuration
- Client setup
- **Resilience tests** (--with-resilience):
  - Redis/NATS circuit breaker activation
  - Automatic recovery from failures
  - Container restart policies
  - Load balancer failure detection
  - Graceful degradation

### Metrics (Prometheus Format)

```bash
# Per-node metrics
curl http://localhost:3001/metrics

# Aggregated metrics server
./chat-system.sh metrics http://192.168.100.53:8500 9090
curl http://localhost:9090/metrics
```

### Health Checks

```bash
# Individual nodes
curl http://localhost:3001/health | jq
curl http://localhost:3002/health | jq
curl http://localhost:3003/health | jq

# Load balancer
curl http://localhost:3000/health | jq

# Check all
for port in 3001 3002 3003; do
    curl -s http://localhost:$port/health | jq '.status, .connections'
done
```

### Container Health

```bash
# List with status
sudo podman ps --format "table {{.Names}}\t{{.Status}}"

# Check specific container
sudo podman inspect chat-node-1 --format '{{.State.Health.Status}}'

# Health check history
sudo podman inspect chat-node-1 --format '{{json .State.Health}}' | jq
```

### Consul UI

- **Local:** http://localhost:8500/ui
- **Cluster:** http://192.168.100.53:8500/ui

## 💻 Client Configuration

```bash
cd client-react
npm install

# Configure load balancer URL
echo "VITE_CHAT_URL=http://192.168.100.51:3000" > .env

npm run dev
```

Access: http://localhost:5173

## 🔧 Deployment Modes

### Standalone
```bash
./chat-system.sh start
```
Starts everything on one machine.

### Infrastructure Only
```bash
./chat-system.sh start --cluster --mode infrastructure
```
Starts Redis + NATS, registers with cluster.

### Nodes Only
```bash
./chat-system.sh start --cluster --mode node-only  
```
Uses existing infrastructure, starts chat nodes.

### Full Stack
```bash
./chat-system.sh start --cluster --mode full --with-lb
```
Starts everything + load balancer.

## 🔍 Troubleshooting

### Quick Diagnostics

```bash
# System overview
./chat-system.sh status

# Test all components
./test-system.sh

# Test with resilience checks (disrupts services temporarily)
./test-system.sh --with-resilience
```

### Check Status

```bash
# System overview
./chat-system.sh status

# Detailed container status
sudo podman ps

# Health checks
curl http://localhost:3001/health | jq
```

### View Logs

```bash
# Via script
./chat-system.sh logs node-1
./chat-system.sh logs lb

# Systemd logs
sudo journalctl -u chat-system -f

# Container logs
sudo podman logs chat-node-1 -f
```

### Test Cluster

```bash
# Test connectivity
./chat-system.sh cluster-test http://192.168.100.53:8500

# View services
curl http://192.168.100.53:8500/v1/catalog/services | jq
```

### Common Issues

#### Port in Use
```bash
sudo ss -tulpn | grep :3001
sudo podman stop <container-name>
```

#### Container Won't Start
```bash
sudo podman logs chat-node-1 --tail 100
sudo podman restart chat-node-1
```

#### Health Check Failing
```bash
curl -v http://localhost:3001/health
curl http://localhost:6379  # Check Redis
nc -zv localhost 4222       # Check NATS
```

#### Can't Reach Cluster
```bash
curl -v http://192.168.100.53:8500/v1/agent/self
# Check firewall if needed
```

## 📁 File Structure

```
chat-system-test/
├── chat-system.sh           ⭐ Universal script (all you need)
├── chat-node/               # Chat service
│   ├── src/
│   │   ├── gateway.ts       # Socket.IO gateway
│   │   ├── load-balancer.ts # Load balancer
│   │   ├── redis.ts, nats.ts, consul.ts
│   │   └── ...
│   ├── package.json
│   └── Dockerfile
├── client-react/            # React frontend
│   ├── src/
│   └── package.json
├── cluster_helper.py        # Cluster operations
├── metrics_server.py        # Metrics aggregator
└── README.md               # This file
```

## ✨ Features

- ✅ Real-time messaging with Socket.IO
- ✅ Horizontal scaling across multiple nodes
- ✅ Automatic service discovery via Consul
- ✅ Load balancing with automatic failover
- ✅ Persistent message history
- ✅ Multi-room support (general, tech, random, games, projects)
- ✅ Username uniqueness enforcement
- ✅ Online/offline presence tracking
- ✅ Private messaging between users
- ✅ Typing indicators
- ✅ Circuit breakers for resilience
- ✅ Rate limiting (connections & messages)
- ✅ Input sanitization & validation
- ✅ Automatic dependency installation
- ✅ Autostart on boot
- ✅ Container auto-recovery
- ✅ Health monitoring
- ✅ Prometheus metrics
- ✅ Comprehensive logging

## 🔐 Security

- Rate limiting on connections and messages
- Input sanitization (XSS protection)
- Token validation (optional)
- Protected Redis mode in production
- Circuit breakers prevent cascading failures
- Health checks with automatic recovery
- Consul ACLs support (configurable)

## 📚 Help

```bash
# Detailed help
./chat-system.sh help

# Quick reference
./chat-system.sh --help
```

## 🎓 Learn More

This project demonstrates:
- Distributed systems architecture
- Service discovery with Consul
- Pub/sub messaging with NATS
- WebSocket scaling
- Container orchestration
- Health monitoring
- Auto-recovery patterns
- Load balancing strategies

Perfect for learning modern distributed systems!

---

**Quick Start:** `./chat-system.sh start --auto`

**Production:** `sudo ./chat-system.sh setup-autostart`

**Help:** `./chat-system.sh help`
