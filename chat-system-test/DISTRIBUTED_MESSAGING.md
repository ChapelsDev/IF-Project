# Distributed Messaging Architecture

## Overview

Your chat system now supports **automatic message sharing across multiple machines** through NATS clustering and Redis sharing. When running in cluster mode, all machines communicate seamlessly.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                      Consul (Service Discovery)                 │
│                    Central or Each Machine                      │
└─────────────────────────────────────────────────────────────────┘
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                        │
┌───────▼──────────┐    ┌───────▼──────────┐    ┌───────▼──────────┐
│   Machine 1      │    │   Machine 2      │    │   Machine 3      │
├──────────────────┤    ├──────────────────┤    ├──────────────────┤
│ Chat Nodes 1-3   │    │ Chat Nodes 4-6   │    │ Chat Nodes 7-9   │
│   ↕ (clients)    │    │   ↕ (clients)    │    │   ↕ (clients)    │
│ ──────┬────────  │    │ ──────┬────────  │    │ ──────┬────────  │
│   NATS :4222 ◄───┼────┼──► NATS :4222 ◄──┼────┼──► NATS :4222    │
│   cluster:6222   │    │   cluster:6222   │    │   cluster:6222   │
│       │          │    │       │          │    │       │          │
│   Redis :6379    │    │   Redis :6379    │    │   Redis :6379    │
│  (or shared) ◄───┼────┼───────┴──────────┼────┼──────┘           │
└──────────────────┘    └──────────────────┘    └──────────────────┘

         NATS Cluster Mesh (port 6222)
         All NATS instances share messages automatically
         
         Redis Sharing
         All machines connect to discovered Redis instance(s)
```

## How It Works

### NATS Clustering (Message Distribution)
1. **Automatic Discovery**: Each NATS instance discovers other NATS nodes via Consul
2. **Cluster Formation**: NATS nodes connect to each other forming a mesh network on port 6222
3. **Message Propagation**: Messages published on one machine are automatically forwarded to ALL other machines
4. **Transparent to Chat Nodes**: Chat nodes connect to their local NATS (port 4222), but messages reach all nodes across all machines

### Redis (Shared State)
- All machines discover available Redis instances via Consul
- User sessions, room data, and presence info are shared
- Can use a single shared Redis or local Redis on each machine (messages still sync via NATS)

## Message Flow Example

**User on Machine 1 sends a message:**
```
User (Browser)
    │
    ▼
Chat Node (Machine 1)
    │
    ├─► Redis (Store message)
    │
    └─► NATS (Publish: "chat.room.general.message")
            │
            ├─► NATS Cluster Mesh
            │       │
            │       ├──► Machine 1 NATS ──► Local Chat Nodes ──► Users
            │       │
            │       ├──► Machine 2 NATS ──► Local Chat Nodes ──► Users
            │       │
            │       └──► Machine 3 NATS ──► Local Chat Nodes ──► Users
```

**Result:** All users on all machines receive the message instantly!

## Setup Instructions

### Quick Start (Recommended)

**On each machine, run:**
```bash
./chat-system.sh start --cluster --cluster-consul http://<CONSUL_IP>:8500 --mode full
```

This will:
- ✅ Start local Redis and NATS
- ✅ Auto-discover other NATS instances
- ✅ Form NATS cluster mesh
- ✅ Start chat nodes
- ✅ Messages automatically shared across all machines

### Alternative: Dedicated Infrastructure

**Machine 1 (Infrastructure):**
```bash
./chat-system.sh start --cluster --mode infrastructure
```

**Machines 2, 3, N (Chat Nodes):**
```bash
./chat-system.sh start --cluster --mode node-only
```

### Verify Clustering

**Check NATS cluster status:**
```bash
# On any machine
curl http://localhost:8222/routez

# You should see connections to other NATS instances
```

**Check service discovery:**
```bash
# List all registered NATS services
./chat-system.sh cluster-test
```

**Test messaging:**
1. Open client on Machine 1: `http://<machine-1-ip>:3002`
2. Open client on Machine 2: `http://<machine-2-ip>:3002`
3. Send message from Machine 1
4. ✅ User on Machine 2 receives it instantly!

## Ports Used

- **4222**: NATS client connections (chat nodes connect here)
- **6222**: NATS cluster mesh (NATS-to-NATS communication)
- **6379**: Redis
- **8500**: Consul
- **3002-3004**: Chat nodes

## Key Features

✅ **Automatic Discovery**: New machines automatically discover and join the cluster
✅ **Message Replication**: All messages replicated across all NATS instances
✅ **Fault Tolerance**: If one NATS instance fails, others continue working
✅ **Scalability**: Add more machines simply by running the same command
✅ **Transparent**: Chat nodes don't need to know about other machines

## Troubleshooting

### Messages not syncing between machines?

1. **Check NATS cluster connections:**
   ```bash
   curl http://localhost:8222/routez | jq
   ```
   Should show routes to other NATS instances.

2. **Verify Consul registration:**
   ```bash
   curl http://<CONSUL_IP>:8500/v1/catalog/service/nats-service | jq
   ```
   Should list all NATS instances.

3. **Check firewall:**
   Ensure port 6222 (NATS cluster) is open between machines:
   ```bash
   sudo firewall-cmd --add-port=6222/tcp --permanent
   sudo firewall-cmd --reload
   ```

4. **Test NATS connectivity:**
   ```bash
   nc -zv <other-machine-ip> 6222
   ```

### Redis connection issues?

Check discovered Redis instances:
```bash
curl http://<CONSUL_IP>:8500/v1/catalog/service/redis-service | jq
```

## Advanced: Monitoring the Cluster

**View NATS cluster mesh topology:**
```bash
# Shows all connected NATS servers
curl http://localhost:8222/routez | jq '.routes[] | {host, port}'
```

**Monitor message flow:**
```bash
# On any machine, monitor NATS
sudo podman exec -it nats nats-top
```

**View cluster-wide services:**
```bash
./chat-system.sh cluster-test http://<CONSUL_IP>:8500
```

## What Changed in the Script

The script now automatically:
1. ✅ Discovers other NATS instances via Consul when starting
2. ✅ Configures NATS with cluster routes (`--routes` parameter)
3. ✅ Forms NATS cluster mesh (all NATS instances connect to each other)
4. ✅ Shares Redis connection info via Consul

**No manual configuration needed** - just use `--cluster` flag!