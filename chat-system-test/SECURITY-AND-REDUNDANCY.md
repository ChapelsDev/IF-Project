# Chat Service Security and Redundancy

## Overview
This document outlines the security and redundancy features implemented in the distributed chat service cluster.

## 🔒 Security Features

### 1. **Authentication & Authorization**
- **JWT Token Validation**: Optional token-based authentication for WebSocket connections
- **Token Generation**: Automatic token generation on username acceptance
- **Token Verification**: Multi-source token extraction (Authorization header, query params)
- **Session Management**: Token payload includes userId and username with configurable expiry

**Configuration:**
```bash
# Enable authentication (set in environment)
REQUIRE_AUTH=true
JWT_SECRET=your-production-secret-key-here
```

**Usage:**
```javascript
// Client connects with token
const socket = io('http://localhost:3001', {
  query: { token: 'your-jwt-token' }
});
```

### 2. **Rate Limiting**
Protects against spam and abuse with per-user rate limits:

- **Message Rate Limit**: 60 messages per minute per user
- **Connection Rate Limit**: 10 connections per minute per IP
- **Private Message Rate Limit**: 30 private messages per minute per user

**Implementation:**
- In-memory rate limiting (scalable to Redis for distributed tracking)
- Automatic cleanup of expired rate limit entries
- Client receives clear error messages when limits are exceeded

### 3. **Input Sanitization**
All user inputs are sanitized to prevent XSS and injection attacks:

- **Username Validation**: 
  - 2-20 characters length
  - Alphanumeric, underscore, and hyphen only
  - Case-insensitive duplicate checking
  
- **Message Sanitization**:
  - HTML entity encoding
  - Null byte removal
  - 2000 character limit
  - Whitespace trimming

- **Room ID Validation**:
  - Lowercase alphanumeric and hyphen only
  - 1-50 characters length

### 4. **Network Security**
- **CORS Configuration**: Configurable allowed origins (defaults to "*" for development)
- **Message Size Limit**: 1MB maximum per message to prevent DoS
- **Connection Limits**: Configurable max connections per node

**Production Configuration:**
```bash
# Set allowed origins
ALLOWED_ORIGINS=https://yourdomain.com,https://app.yourdomain.com
```

### 5. **Security Monitoring**
- Connection tracking with IP address logging
- Rate limit violation logging
- Failed authentication attempt logging
- Security event timestamps

---

## 🔄 Redundancy & Resilience Features

### 1. **Circuit Breaker Pattern**
Prevents cascading failures when dependencies are unavailable:

**Redis Circuit Breaker:**
- Failure threshold: 5 consecutive failures
- Success threshold: 2 consecutive successes (in half-open state)
- Timeout: 5 seconds per operation
- Reset timeout: 30 seconds before retry

**NATS Circuit Breaker:**
- Same configuration as Redis
- Automatic fallback to degraded mode

**States:**
- `CLOSED`: Normal operation
- `OPEN`: Dependency down, using fallback
- `HALF_OPEN`: Testing if dependency recovered

**Fallback Behaviors:**
```typescript
// Redis unavailable - allow operations but don't persist
await redisCircuitBreaker.executeWithFallback(
  () => appendMessage(roomId, user, text),
  () => Promise.resolve('fallback-id') // Message not persisted
);

// NATS unavailable - continue but message may not broadcast
await natsCircuitBreaker.executeWithFallback(
  () => publishMessage(roomId, msg),
  () => Promise.resolve() // Local delivery only
);
```

### 2. **Graceful Shutdown**
Ensures no message loss and clean disconnections:

**Process:**
1. Receive SIGTERM/SIGINT signal
2. Stop accepting new connections
3. Mark node as unhealthy (health check returns 503)
4. Notify all connected clients (`serverShutdown` event)
5. Wait 2 seconds for clients to receive notification
6. Disconnect all clients gracefully
7. Close Socket.IO and HTTP servers
8. Exit process

**Health Check Integration:**
```bash
# Health endpoint
curl http://localhost:3001/health
# Returns: { status: "shutting_down", ... } with 503 status code

# Readiness endpoint
curl http://localhost:3001/ready
# Returns: { ready: false, ... } when shutting down
```

### 3. **Enhanced Health Checks**
Multi-level health monitoring:

**Endpoints:**
- `/health`: Liveness probe (is the service running?)
- `/ready`: Readiness probe (can it handle traffic?)

**Health Response:**
```json
{
  "status": "ok",
  "nodeId": "1",
  "connections": 42,
  "redis": "CLOSED",
  "nats": "CLOSED",
  "timestamp": 1702741234567
}
```

**Status Codes:**
- `200`: Healthy and ready
- `503`: Shutting down or dependencies unavailable

**Kubernetes Integration:**
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 3001
  initialDelaySeconds: 10
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /ready
    port: 3001
  initialDelaySeconds: 5
  periodSeconds: 5
```

### 4. **Connection Tracking**
- Active connection registry with username mapping
- Automatic cleanup on disconnect
- Connection count exposed in health checks
- Used for graceful shutdown coordination

### 5. **Session Persistence**
- Username registration with TTL in Redis (30 seconds)
- Allows reconnection without username conflicts
- Automatic cleanup of stale sessions
- JWT tokens for stateless authentication

### 6. **Error Handling**
- Uncaught exception handler with graceful shutdown
- Unhandled promise rejection logging
- Per-operation try-catch with user-friendly error messages
- Client error event emission for all failures

---

## 🎯 Cluster-Specific Features

### 1. **Multi-Node Message Routing**
- Private messages routed via NATS to any node
- Username-to-socket mapping for cross-node delivery
- Fallback when user not on current node

### 2. **Distributed State**
- Redis for shared state (usernames, room presence)
- NATS for pub/sub messaging
- Circuit breakers protect against single node failures

### 3. **Zero-Downtime Deployments**
With graceful shutdown and health checks:

1. Deploy new version
2. Old nodes mark as not ready
3. Load balancer stops routing to old nodes
4. Old nodes drain connections
5. Old nodes shut down
6. Only new nodes receive traffic

### 4. **Load Balancer Integration**
Recommended nginx configuration:

```nginx
upstream chat_backends {
    # Health check based routing
    server chat-node-1:3001 max_fails=3 fail_timeout=30s;
    server chat-node-2:3002 max_fails=3 fail_timeout=30s;
    server chat-node-3:3003 max_fails=3 fail_timeout=30s;
}

server {
    listen 80;
    
    location / {
        proxy_pass http://chat_backends;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        
        # Health check
        proxy_next_upstream error timeout http_503;
    }
    
    location /health {
        proxy_pass http://chat_backends/health;
    }
}
```

---

## 🚀 Production Deployment Checklist

### Security
- [ ] Set `REQUIRE_AUTH=true`
- [ ] Generate strong `JWT_SECRET`
- [ ] Configure `ALLOWED_ORIGINS` (remove wildcard)
- [ ] Enable TLS/SSL for all connections
- [ ] Implement Redis password authentication
- [ ] Enable NATS authentication
- [ ] Set up firewall rules (only allow internal cluster traffic)

### Redundancy
- [ ] Deploy at least 3 chat nodes
- [ ] Configure health check endpoints in orchestrator
- [ ] Set up load balancer with sticky sessions
- [ ] Test graceful shutdown (send SIGTERM)
- [ ] Verify circuit breaker behavior (disconnect Redis/NATS)
- [ ] Monitor circuit breaker states
- [ ] Set up alerts for OPEN circuit breakers

### Monitoring
- [ ] Log aggregation (ELK, Grafana Loki)
- [ ] Metrics collection (Prometheus)
- [ ] Alert on high error rates
- [ ] Alert on circuit breaker OPEN state
- [ ] Alert on high connection counts
- [ ] Dashboard for connection tracking

### Testing
- [ ] Load test with rate limits
- [ ] Test multi-node message delivery
- [ ] Test graceful shutdown under load
- [ ] Test circuit breaker fallbacks
- [ ] Test authentication failures
- [ ] Test input sanitization (XSS attempts)

---

## 📊 Monitoring Queries

### Check Circuit Breaker States
```bash
# Query health endpoint from all nodes
for port in 3001 3002 3003; do
  echo "Node on port $port:"
  curl -s http://localhost:$port/health | jq '.redis, .nats'
done
```

### Monitor Active Connections
```bash
# Get connection counts
for port in 3001 3002 3003; do
  echo -n "Port $port: "
  curl -s http://localhost:$port/health | jq '.connections'
done
```

### Test Rate Limiting
```bash
# Send 100 messages rapidly (should hit rate limit)
for i in {1..100}; do
  curl -X POST http://localhost:3001/message \
    -H "Content-Type: application/json" \
    -d '{"roomId":"test","text":"msg'$i'"}'
done
```

---

## 🔧 Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NODE_ID` | 1 | Unique identifier for this node |
| `REQUIRE_AUTH` | false | Enable JWT authentication |
| `JWT_SECRET` | (dev key) | Secret for JWT signing |
| `ALLOWED_ORIGINS` | * | CORS allowed origins (comma-separated) |
| `REDIS_URL` | redis://127.0.0.1:6379 | Redis connection string |
| `NATS_URL` | nats://127.0.0.1:4222 | NATS connection string |
| `CONSUL_URL` | http://127.0.0.1:8500 | Consul connection string |

### Rate Limit Tuning

Edit `src/rateLimit.ts`:
```typescript
export const messageLimiter = new RateLimiter({ 
  windowMs: 60000,    // Time window in ms
  maxRequests: 60     // Max requests per window
});
```

### Circuit Breaker Tuning

Edit `src/circuitBreaker.ts`:
```typescript
export const redisCircuitBreaker = new CircuitBreaker('Redis', {
  failureThreshold: 5,    // Failures before opening
  successThreshold: 2,    // Successes to close from half-open
  timeout: 5000,          // Operation timeout (ms)
  resetTimeout: 30000     // Time before retry (ms)
});
```

---

## 🎓 Best Practices

1. **Always use circuit breakers** for external dependencies
2. **Sanitize all inputs** before processing
3. **Rate limit by user/IP** to prevent abuse
4. **Log security events** for audit trails
5. **Test graceful shutdown** in staging environment
6. **Monitor circuit breaker states** in production
7. **Use health checks** for orchestration decisions
8. **Enable authentication** in production
9. **Rotate JWT secrets** regularly
10. **Keep dependencies updated** for security patches
