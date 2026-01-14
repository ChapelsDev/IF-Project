import { connect, NatsConnection } from "nats";

let nc: NatsConnection | null = null;

export async function initNats() {
  if (!nc) {
    // Support multiple NATS servers for HA (comma-separated)
    const natsUrl = process.env.NATS_URL || "nats://127.0.0.1:4222";
    const servers = natsUrl.split(",").map(url => url.trim());
    
    console.log("[NATS] Connecting to servers:", servers);
    nc = await connect({ 
      servers,
      maxReconnectAttempts: -1, // Infinite reconnects
      reconnectTimeWait: 1000,   // 1 second between attempts
    });
    
    console.log("[NATS] Connected successfully");
    
    nc.closed().then((err) => {
      if (err) {
        console.error("[NATS] Connection closed with error:", err);
      } else {
        console.log("[NATS] Connection closed");
      }
    });
  }
  return nc;
}

export async function publishMessage(roomId: string, msg: any) {
  const nc = await initNats();
  nc.publish(`chat.${roomId}.message`, JSON.stringify(msg));
}

export async function publishPresence(type: string, payload: any) {
  const nc = await initNats();
  nc.publish(`chat.presence.${type}`, JSON.stringify(payload));
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
