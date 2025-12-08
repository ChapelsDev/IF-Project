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
