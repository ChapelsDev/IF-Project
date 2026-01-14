import { connect, NatsConnection, ConnectionOptions } from "nats";

let nc: NatsConnection | null = null;
let reconnectAttempts = 0;
let connectionHealthy = true;
let lastHealthCheck = Date.now();

// Health monitoring interval (15 seconds)
setInterval(() => {
  if (nc && connectionHealthy) {
    const timeSinceLastCheck = Date.now() - lastHealthCheck;
    if (timeSinceLastCheck > 60000) { // 1 minute without activity
      console.warn("[NATS] No activity detected, connection may be stale");
      connectionHealthy = false;
    }
  }
}, 15000);

export async function initNats() {
  if (!nc || !connectionHealthy) {
    // Support multiple NATS servers for HA (comma-separated)
    const natsUrl = process.env.NATS_URL || "nats://127.0.0.1:4222";
    const servers = natsUrl.split(",").map(url => url.trim());
    
    console.log("[NATS] Connecting to servers:", servers);
    
    const options: ConnectionOptions = {
      servers,
      maxReconnectAttempts: -1, // Infinite reconnects
      reconnectTimeWait: 2000,   // 2 seconds base wait
      reconnectJitter: 500,      // Add jitter to avoid thundering herd
      reconnectJitterTLS: 500,
      pingInterval: 20000,       // 20 second ping interval
      maxPingOut: 3,             // Max 3 missed pings
      timeout: 10000,            // 10 second connection timeout
      reconnect: true,
      
      // Enhanced reconnection callbacks
      reconnectDelayHandler: () => {
        reconnectAttempts++;
        // Exponential backoff with cap at 30 seconds
        const delay = Math.min(2000 * Math.pow(1.5, reconnectAttempts), 30000);
        console.log(`[NATS] Reconnect attempt ${reconnectAttempts}, waiting ${delay}ms`);
        return delay;
      },
    };
    
    try {
      nc = await connect(options);
      reconnectAttempts = 0;
      connectionHealthy = true;
      lastHealthCheck = Date.now();
      console.log("[NATS] Connected successfully");
      
      // Monitor connection events
      (async () => {
        for await (const status of nc!.status()) {
          const now = Date.now();
          lastHealthCheck = now;
          
          switch (status.type) {
            case "disconnect":
              console.warn("[NATS] Disconnected from server:", status.data);
              connectionHealthy = false;
              break;
            case "reconnecting":
              console.log("[NATS] Reconnecting to server...");
              break;
            case "reconnect":
              console.log("[NATS] Reconnected to server:", status.data);
              connectionHealthy = true;
              reconnectAttempts = 0;
              break;
            case "error":
              console.error("[NATS] Connection error:", status.data);
              break;
            case "pingTimer":
              // Ping sent, connection is active
              lastHealthCheck = now;
              break;
          }
        }
      })();
      
      nc.closed().then((err) => {
        if (err) {
          console.error("[NATS] Connection closed with error:", err);
          connectionHealthy = false;
          nc = null;
        } else {
          console.log("[NATS] Connection closed gracefully");
        }
      });
    } catch (error) {
      console.error("[NATS] Failed to connect:", error);
      connectionHealthy = false;
      nc = null;
      throw error;
    }
  }
  return nc;
}

async function retryOperation<T>(operation: () => Promise<T>, maxRetries = 3): Promise<T> {
  let lastError;
  for (let i = 0; i < maxRetries; i++) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      console.warn(`[NATS] Operation failed (attempt ${i + 1}/${maxRetries}):`, error);
      if (i < maxRetries - 1) {
        await new Promise(resolve => setTimeout(resolve, 1000 * (i + 1)));
        // Reset connection on retry
        connectionHealthy = false;
      }
    }
  }
  throw lastError;
}

export async function publishMessage(roomId: string, msg: any) {
  await retryOperation(async () => {
    const nc = await initNats();
    nc.publish(`chat.${roomId}.message`, JSON.stringify(msg));
    lastHealthCheck = Date.now();
  });
}

export async function publishPresence(type: string, payload: any) {
  await retryOperation(async () => {
    const nc = await initNats();
    nc.publish(`chat.presence.${type}`, JSON.stringify(payload));
    lastHealthCheck = Date.now();
  });
}

export async function subscribeToMessages(roomId: string, callback: (msg: any) => void) {
  const nc = await initNats();
  const sub = nc.subscribe(`chat.${roomId}.message`);
  
  (async () => {
    for await (const m of sub) {
      const msg = JSON.parse(new TextDecoder().decode(m.data));
      callback(msg);
    }
  })();
}

export async function subscribeToPresence(type: string, callback: (data: any) => void) {
  const nc = await initNats();
  const sub = nc.subscribe(`chat.presence.${type}`);
  
  (async () => {
    for await (const m of sub) {
      const data = JSON.parse(new TextDecoder().decode(m.data));
      callback(data);
    }
  })();
}

// Private messaging functions
export async function publishPrivateMessage(to: string, msg: any) {
  const nc = await initNats();
  nc.publish(`chat.private.${to}`, JSON.stringify(msg));
  console.log(`[NATS] Published private message to ${to}`);
}

export async function subscribeToPrivateMessages(username: string, callback: (msg: any) => void) {
  const nc = await initNats();
  // Use wildcard subscription to receive all private messages on this node
  const subject = username === "*" ? "chat.private.*" : `chat.private.${username}`;
  const sub = nc.subscribe(subject);
  
  console.log(`[NATS] Subscribed to private messages: ${subject}`);
  
  (async () => {
    for await (const m of sub) {
      const msg = JSON.parse(new TextDecoder().decode(m.data));
      callback(msg);
    }
  })();
}

// Username state synchronization
export async function publishUsernameRegistration(username: string, userId: string) {
  const nc = await initNats();
  nc.publish(`chat.username.register`, JSON.stringify({ username, userId }));
  console.log(`[NATS] Published username registration: ${username}`);
}

export async function publishUsernameUnregistration(username: string) {
  const nc = await initNats();
  nc.publish(`chat.username.unregister`, JSON.stringify({ username }));
  console.log(`[NATS] Published username unregistration: ${username}`);
}

export async function subscribeToUsernameRegistrations(callback: (data: any) => void) {
  const nc = await initNats();
  const sub = nc.subscribe(`chat.username.register`);
  
  console.log(`[NATS] Subscribed to username registrations`);
  
  (async () => {
    for await (const m of sub) {
      const data = JSON.parse(new TextDecoder().decode(m.data));
      callback(data);
    }
  })();
}

export async function subscribeToUsernameUnregistrations(callback: (data: any) => void) {
  const nc = await initNats();
  const sub = nc.subscribe(`chat.username.unregister`);
  
  console.log(`[NATS] Subscribed to username unregistrations`);
  
  (async () => {
    for await (const m of sub) {
      const data = JSON.parse(new TextDecoder().decode(m.data));
      callback(data);
    }
  })();
}

// Health check function
export function getNatsHealth() {
  return {
    connected: nc !== null && connectionHealthy,
    reconnectAttempts,
    lastHealthCheck,
    timeSinceLastCheck: Date.now() - lastHealthCheck
  };
}

// Force reconnection if needed
export async function ensureNatsConnection() {
  if (!nc || !connectionHealthy) {
    console.log("[NATS] Forcing reconnection...");
    nc = null;
    return await initNats();
  }
  return nc;
}
