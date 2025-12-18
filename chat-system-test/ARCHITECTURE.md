# Chat Service Security & Redundancy Architecture

## 🎯 Focus: Chat Service Resilience in Cluster Environment

This implementation focuses on making the **chat service nodes** themselves secure and resilient, independent of the supporting infrastructure (Consul, SeaweedFS, etc.).

---

## 📐 Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     Load Balancer (nginx)                    │
│              Health-Check Based Routing + TLS                │
└─────────────────┬───────────────┬───────────────────────────┘
                  │               │               
        ┌─────────┴────┐  ┌──────┴────────┐  ┌──────────────┐
        │  Chat Node 1 │  │  Chat Node 2  │  │  Chat Node 3 │
        │  (Port 3001) │  │  (Port 3002)  │  │  (Port 3003) │
        └──────┬───────┘  └───────┬───────┘  └──────┬───────┘
               │                  │                  │
               │   ┌──────────────┴──────────────┐   │
               │   │   Security Layer (Each Node) │   │
               │   │  ┌────────────────────────┐  │   │
               │   │  │ • JWT Authentication   │  │   │
               │   │  │ • Rate Limiting        │  │   │
               │   │  │ • Input Sanitization   │  │   │
               │   │  │ • Circuit Breakers     │  │   │
               │   │  │ • Graceful Shutdown    │  │   │
               │   │  └────────────────────────┘  │   │
               │   └─────────────────────────────┘   │
               │                  │                  │
        ┌──────┴──────────────────┴──────────────────┴──────┐
        │         Shared Infrastructure (HA)                 │
        │  ┌──────────┐  ┌──────────┐  ┌──────────────┐   │
        │  │  Redis   │  │   NATS   │  │    Consul    │   │
        │  │ Cluster  │  │ Cluster  │  │   Cluster    │   │
        │  └──────────┘  └──────────┘  └──────────────┘   │
        └───────────────────────────────────────────────────┘
```

---

## 🔐 Security Layers (Per Chat Node)

### Layer 1: Connection Security
```
Client Connection
      ↓
[Rate Limit Check] ← 10 connections/min per IP
      ↓
[JWT Validation] ← Optional (REQUIRE_AUTH=true)
      ↓
[CORS Validation] ← Configurable allowed origins
      ↓
[Size Limit] ← 1MB max message size
      ↓
Connection Accepted
```

### Layer 2: Message Security
```
Message Received
      ↓
[Rate Limit Check] ← 60 messages/min per user
      ↓
[Input Sanitization] ← XSS/injection prevention
      ↓
[Content Validation] ← Length, format checks
      ↓
Message Processed
```

### Layer 3: Operational Security
```
Every Operation
      ↓
[Circuit Breaker Check] ← Is dependency healthy?
      ↓
  ┌─── CLOSED: Execute normally
  ├─── OPEN: Use fallback
  └─── HALF_OPEN: Test recovery
      ↓
Operation Complete
```

---

## 🔄 Redundancy Mechanisms

### 1. Circuit Breaker Pattern

**Problem:** When Redis/NATS fails, the entire service shouldn't crash.

**Solution:** Circuit breakers monitor dependency health and automatically switch to degraded mode.

```typescript
// Example: Message handling with circuit breaker
await redisCircuitBreaker.executeWithFallback(
  () => appendMessage(roomId, user, text),  // Normal path
  () => {
    console.log('Redis down - message not persisted');
    return 'temp-id';  // Fallback: temporary ID
  }
);
```

**States:**
- **CLOSED** (Normal): All operations go through Redis/NATS
- **OPEN** (Degraded): Bypass failed dependency, use fallbacks
- **HALF_OPEN** (Testing): Try dependency again after timeout

**Benefits:**
- Service stays online even if Redis crashes
- Automatic recovery when dependencies come back
- No manual intervention required

---

### 2. Graceful Shutdown

**Problem:** Abrupt shutdown causes dropped connections and lost messages.

**Solution:** Coordinated shutdown sequence that drains connections cleanly.

```
SIGTERM Received
      ↓
1. Stop accepting new connections
      ↓
2. Mark node unhealthy (health check → 503)
      ↓
3. Load balancer stops routing here
      ↓
4. Send 'serverShutdown' event to all clients
      ↓
5. Wait 2 seconds (clients disconnect gracefully)
      ↓
6. Force disconnect remaining clients
      ↓
7. Close servers
      ↓
8. Exit process (exit code 0)
```

**Kubernetes Integration:**
```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 15"]
terminationGracePeriodSeconds: 30
```

---

### 3. Health Check System

**Two-Tier Health Checks:**

| Endpoint | Purpose | When to Use |
|----------|---------|-------------|
| `/health` | Liveness | Is the service running? |
| `/ready` | Readiness | Can it handle traffic? |

**Health Check Response:**
```json
{
  "status": "ok",           // or "shutting_down"
  "nodeId": "1",
  "connections": 42,
  "redis": "CLOSED",        // Circuit breaker state
  "nats": "CLOSED",         // Circuit breaker state
  "timestamp": 1702741234567
}
```

**Status Codes:**
- `200`: Healthy and ready
- `503`: Shutting down OR circuit breaker OPEN

**Orchestrator Usage:**
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 3001
  failureThreshold: 3
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /ready
    port: 3001
  failureThreshold: 1  # Immediate removal
  periodSeconds: 5
```

---

## 🛡️ Failure Scenarios & Responses

### Scenario 1: Redis Cluster Fails

**Without Circuit Breaker:**
```
Redis fails → All chat operations timeout → Service crashes
```

**With Circuit Breaker:**
```
Redis fails → Circuit opens after 5 failures
             ↓
Service continues with fallbacks:
  • Messages not persisted (ephemeral mode)
  • Username checks always pass
  • Room history returns empty
  • Service stays online
```

**Recovery:**
```
Redis comes back → Circuit enters HALF_OPEN
                  ↓
2 successful operations → Circuit CLOSES
                  ↓
Normal operation resumes
```

---

### Scenario 2: NATS Cluster Fails

**Impact:** Messages don't broadcast to other nodes

**Response:**
```
NATS fails → Circuit breaker opens
           ↓
Messages delivered locally only
(Users on same node still communicate)
           ↓
When NATS recovers:
  → Circuit closes
  → Cross-node messaging resumes
```

---

### Scenario 3: Node Overload (Rate Limit Attack)

**Attack:** Malicious user sends 1000 messages/second

**Defense:**
```
Message 1-60   → Accepted (within rate limit)
Message 61+    → Rejected with error
               ↓
Client receives: "Rate limit exceeded. Please slow down."
               ↓
Other users unaffected
```

**Rate Limits:**
- Messages: 60/minute
- Private messages: 30/minute  
- Connections: 10/minute per IP

---

### Scenario 4: Rolling Update (Zero Downtime)

**Deployment Process:**

```
1. Deploy new version (Node 4, 5, 6)
   Current: [Node 1✓] [Node 2✓] [Node 3✓]
   New:     [Node 4✓] [Node 5✓] [Node 6✓]

2. New nodes pass health checks
   Load balancer adds them to pool

3. Send SIGTERM to old nodes
   [Node 1: shutting_down] [Node 2: shutting_down] [Node 3: shutting_down]
   
4. Old nodes return 503 on /ready
   Load balancer stops routing to them

5. Old nodes drain connections
   Node 1: 42 → 30 → 15 → 5 → 0 connections

6. Old nodes shut down
   [Node 1: stopped] [Node 2: stopped] [Node 3: stopped]

7. Only new nodes handling traffic
   Current: [Node 4✓] [Node 5✓] [Node 6✓]

Result: Zero dropped connections
```

---

## 📊 Monitoring & Observability

### Key Metrics to Monitor

1. **Connection Metrics**
   - Active connections per node
   - Connections per second
   - Connection errors

2. **Circuit Breaker Metrics**
   - Redis circuit state (should be CLOSED)
   - NATS circuit state (should be CLOSED)
   - Circuit open duration
   - Fallback invocation count

3. **Rate Limiting Metrics**
   - Rate limit violations per minute
   - Top offending IPs
   - Rejected connections

4. **Security Metrics**
   - Failed authentication attempts
   - Invalid token count
   - XSS/injection attempts blocked

5. **Performance Metrics**
   - Message latency
   - Operation timeout count
   - Health check response time

### Alerting Thresholds

```yaml
alerts:
  - name: CircuitBreakerOpen
    condition: circuit_breaker_state == "OPEN"
    severity: HIGH
    message: "Dependency is down, service in degraded mode"

  - name: HighConnectionCount
    condition: active_connections > 1000
    severity: MEDIUM
    message: "Node approaching connection limit"

  - name: RateLimitViolations
    condition: rate_limit_violations > 100/min
    severity: MEDIUM
    message: "Possible DDoS attack detected"

  - name: GracefulShutdownSlow
    condition: shutdown_duration > 30s
    severity: LOW
    message: "Shutdown taking longer than expected"
```

---

## 🚀 Production Checklist

### Pre-Deployment

- [ ] **Security**
  - [ ] Set `REQUIRE_AUTH=true`
  - [ ] Generate strong `JWT_SECRET` (32+ chars)
  - [ ] Configure `ALLOWED_ORIGINS` (no wildcards)
  - [ ] Review rate limit thresholds
  - [ ] Test input sanitization

- [ ] **Redundancy**
  - [ ] Deploy minimum 3 nodes
  - [ ] Configure health checks in orchestrator
  - [ ] Set up load balancer with health-based routing
  - [ ] Test graceful shutdown sequence
  - [ ] Verify circuit breaker behavior

- [ ] **Monitoring**
  - [ ] Set up log aggregation
  - [ ] Configure metric collection
  - [ ] Create alerting rules
  - [ ] Build operational dashboard

### Post-Deployment

- [ ] Verify all nodes healthy (`/health` returns 200)
- [ ] Check circuit breakers closed
- [ ] Monitor connection distribution
- [ ] Test rate limiting with load test
- [ ] Perform rolling update test
- [ ] Simulate Redis failure
- [ ] Simulate NATS failure
- [ ] Test graceful shutdown under load

---

## 🎓 Key Design Principles

1. **Fail Gracefully**: Never crash, always degrade gracefully
2. **Fail Fast**: Detect issues quickly with circuit breakers
3. **Fail Safe**: Fallbacks ensure service continuity
4. **Fail Transparently**: Log all failures for debugging
5. **Fail Informatively**: Clear error messages to clients

---

## 📚 Additional Resources

- `SECURITY-AND-REDUNDANCY.md` - Detailed feature documentation
- `test-security.sh` - Automated testing script
- `src/circuitBreaker.ts` - Circuit breaker implementation
- `src/rateLimit.ts` - Rate limiting logic
- `src/sanitizer.ts` - Input validation
- `src/tokenValidation.ts` - JWT authentication

---

## 🔮 Future Enhancements

1. **Distributed Rate Limiting**: Use Redis for cross-node rate limits
2. **Session Affinity**: Sticky sessions for better UX
3. **Message Queue**: Kafka/RabbitMQ for guaranteed delivery
4. **Encryption**: End-to-end message encryption
5. **Audit Logging**: Compliance-ready audit trails
6. **Auto-Scaling**: Dynamic node scaling based on load
7. **Geographic Distribution**: Multi-region deployment
8. **A/B Testing**: Feature flags for gradual rollouts
