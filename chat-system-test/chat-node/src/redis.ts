import { createClient, RedisClientType } from "redis";

// Support both single Redis and multiple Redis instances (with failover)
const redisUrl = process.env.REDIS_URL || "redis://127.0.0.1:6379";
const hasMultipleInstances = redisUrl.includes(",");
const urls = redisUrl.split(",").map(url => url.trim());

let redis: RedisClientType;
let currentUrlIndex = 0;
let connectionHealthy = false;
let reconnectAttempts = 0;
let lastHealthCheck = Date.now();

// Health monitoring interval (15 seconds)
setInterval(async () => {
  if (redis && connectionHealthy) {
    try {
      await redis.ping();
      lastHealthCheck = Date.now();
    } catch (error) {
      console.error("[REDIS] Health check failed:", error);
      connectionHealthy = false;
      await attemptReconnection();
    }
  }
}, 15000);

async function attemptReconnection() {
  if (reconnectAttempts >= 5) {
    console.error("[REDIS] Max reconnection attempts reached");
    if (hasMultipleInstances && urls.length > 1) {
      console.log("[REDIS] Attempting failover to next instance...");
      currentUrlIndex = (currentUrlIndex + 1) % urls.length;
      reconnectAttempts = 0;
    }
  }
  
  try {
    if (redis) {
      await redis.disconnect().catch(() => {});
    }
    await initRedis();
  } catch (error) {
    console.error("[REDIS] Reconnection failed:", error);
    reconnectAttempts++;
    const delay = Math.min(2000 * Math.pow(1.5, reconnectAttempts), 30000);
    setTimeout(() => attemptReconnection(), delay);
  }
}

async function initRedis() {
  const targetUrl = hasMultipleInstances ? urls[currentUrlIndex] : redisUrl;
  
  console.log("[REDIS] Connecting to:", targetUrl);
  if (hasMultipleInstances) {
    console.log("[REDIS] Fallback instances available:", 
      urls.filter((_, i) => i !== currentUrlIndex).join(", "));
  }
  
  redis = createClient({ 
    url: targetUrl,
    socket: {
      reconnectStrategy: (retries) => {
        reconnectAttempts = retries;
        if (retries > 10) {
          console.error("[REDIS] Too many reconnection attempts");
          return new Error("Max reconnection attempts reached");
        }
        // Exponential backoff with cap at 30 seconds
        const delay = Math.min(1000 * Math.pow(1.5, retries), 30000);
        console.log(`[REDIS] Reconnecting (attempt ${retries + 1}), waiting ${delay}ms`);
        return delay;
      },
      connectTimeout: 10000,
      keepAlive: 30000,
    }
  });
  
  // Error handlers
  redis.on('error', (err) => {
    console.error('[REDIS] Client error:', err);
    connectionHealthy = false;
  });
  
  redis.on('connect', () => {
    console.log('[REDIS] Client connecting...');
  });
  
  redis.on('ready', () => {
    console.log('[REDIS] Client ready');
    connectionHealthy = true;
    reconnectAttempts = 0;
    lastHealthCheck = Date.now();
  });
  
  redis.on('reconnecting', () => {
    console.log('[REDIS] Client reconnecting...');
    connectionHealthy = false;
  });
  
  redis.on('end', () => {
    console.log('[REDIS] Client connection ended');
    connectionHealthy = false;
  });
  
  await redis.connect();
  console.log("[REDIS] Connected successfully");
  connectionHealthy = true;
}

// Initialize connection
initRedis().catch((err) => {
  console.error("[REDIS] Initial connection failed:", err);
  attemptReconnection();
});

async function retryRedisOperation<T>(operation: () => Promise<T>, maxRetries = 3): Promise<T> {
  let lastError;
  for (let i = 0; i < maxRetries; i++) {
    try {
      if (!connectionHealthy && i > 0) {
        await attemptReconnection();
      }
      const result = await operation();
      lastHealthCheck = Date.now();
      return result;
    } catch (error) {
      lastError = error;
      console.warn(`[REDIS] Operation failed (attempt ${i + 1}/${maxRetries}):`, error);
      if (i < maxRetries - 1) {
        await new Promise(resolve => setTimeout(resolve, 1000 * (i + 1)));
      }
    }
  }
  throw lastError;
}

export async function appendMessage(roomId: string, user: string, text: string, userId?: string) {
  return retryRedisOperation(async () => {
    const msg = { roomId, user, text, userId: userId || '', ts: Date.now().toString() };
    console.log("[REDIS] Appending message to stream:", msg);
    const id = await redis.xAdd(
      `stream:${roomId}`,
      "*",
      msg
    );
    console.log(`[REDIS] Message appended with ID: ${id}`);
    return id;
  });
}

export async function getMessageHistory(roomId: string, count: number = 50) {
  try {
    const messages = await redis.xRange(`stream:${roomId}`, "-", "+", { COUNT: count });
    return messages.map((msg: any) => ({
      id: msg.id,
      roomId,
      ...msg.message
    }));
  } catch (error) {
    return [];
  }
}

// Presence tracking
export async function isUsernameAvailable(username: string, socketId?: string): Promise<boolean> {
  const normalizedUsername = username.toLowerCase();
  const data = await redis.get(`username:${normalizedUsername}`);
  
  if (!data) {
    return true; // Username is available
  }
  
  // If socketId provided, allow re-registration by same socket or if TTL is close to expiring
  if (socketId) {
    const parsed = JSON.parse(data);
    // Allow takeover if it's been more than 5 seconds (likely a reconnect)
    const age = Date.now() - parsed.registeredAt;
    if (age > 5000) {
      return true;
    }
  }
  
  return false;
}

export async function registerUsername(username: string, userId: string) {
  const normalizedUsername = username.toLowerCase();
  // Set with 30 second expiry (auto-cleanup if user doesn't disconnect properly)
  // This allows quick reconnects while preventing long-term username squatting
  await redis.setEx(`username:${normalizedUsername}`, 30, JSON.stringify({ originalUsername: username, userId, registeredAt: Date.now() }));
}

export async function unregisterUsername(username: string) {
  const normalizedUsername = username.toLowerCase();
  await redis.del(`username:${normalizedUsername}`);
}

export async function addUserToRoom(roomId: string, userId: string, username: string) {
  // Use username as key so same user reconnecting replaces old entry
  await redis.hSet(`room:${roomId}:users`, username, JSON.stringify({ userId, username, joinedAt: Date.now() }));
}

export async function removeUserFromRoom(roomId: string, username: string) {
  await redis.hDel(`room:${roomId}:users`, username);
}

export async function getRoomUsers(roomId: string) {
  const users = await redis.hGetAll(`room:${roomId}:users`);
  return Object.entries(users).map(([username, data]) => {
    const parsed = JSON.parse(data as string);
    return {
      userId: parsed.userId,
      username: parsed.username,
      joinedAt: parsed.joinedAt
    };
  });
}

export async function removeUserFromAllRooms(username: string) {
  const rooms = ["general", "tech", "random", "games", "projects"];
  for (const room of rooms) {
    await removeUserFromRoom(room, username);
  }
}

// Private messaging functions
export async function sendPrivateMessage(from: string, to: string, text: string) {
  const msg = { from, to, text, ts: Date.now().toString(), read: "false" };
  console.log("[REDIS] Sending private message:", msg);
  
  // Store in both sender's and receiver's message streams
  const conversationKey = getConversationKey(from, to);
  const id = await redis.xAdd(
    `pm:${conversationKey}`,
    "*",
    msg
  );
  
  console.log(`[REDIS] Private message stored with ID: ${id}`);
  return id;
}

export async function getPrivateMessageHistory(user1: string, user2: string, count: number = 50) {
  try {
    const conversationKey = getConversationKey(user1, user2);
    const messages = await redis.xRange(`pm:${conversationKey}`, "-", "+", { COUNT: count });
    return messages.map((msg: any) => ({
      id: msg.id,
      ...msg.message,
      read: msg.message.read === "true"
    }));
  } catch (error) {
    console.error("[REDIS] Error getting private message history:", error);
    return [];
  }
}

export async function markPrivateMessagesAsRead(from: string, to: string) {
  // This is a simple implementation - for production, you'd want to update individual messages
  console.log(`[REDIS] Marking messages from ${from} to ${to} as read`);
  // Note: Redis Streams don't support in-place updates
  // For production, consider using a separate hash to track read status
}

export async function getActivePrivateConversations(username: string) {
  // Get all private message streams that involve this user
  try {
    const keys = await redis.keys(`pm:*${username}*`);
    const conversations = new Set<string>();
    
    for (const key of keys) {
      // Extract the other user from the conversation key
      const conversationKey = key.replace("pm:", "");
      const [user1, user2] = conversationKey.split(":");
      const otherUser = user1 === username ? user2 : user1;
      conversations.add(otherUser);
    }
    
    return Array.from(conversations);
  } catch (error) {
    console.error("[REDIS] Error getting active conversations:", error);
    return [];
  }
}

// Helper function to create a consistent conversation key
function getConversationKey(user1: string, user2: string): string {
  // Sort usernames alphabetically to ensure consistent key
  return [user1, user2].sort().join(":");
}

export async function readMessages(callback: (roomId: string, msg: any) => void) {
  const rooms = ["general", "tech", "random", "games", "projects"];
  const lastIds: { [key: string]: string } = {};
  
  // Initialize last IDs - start reading from the END of each stream (new messages only)
  // Using "$" means "only new messages arriving after this point"
  for (const room of rooms) {
    // Get the last message ID in each stream to start from there
    try {
      const lastMsg: any = await redis.xRevRange(`stream:${room}`, "+", "-", { COUNT: 1 });
      if (lastMsg && lastMsg.length > 0) {
        lastIds[`stream:${room}`] = lastMsg[0].id;
        console.log(`[REDIS] Starting from last message in stream:${room} - ID: ${lastMsg[0].id}`);
      } else {
        lastIds[`stream:${room}`] = "0";  // Stream is empty, start from beginning
        console.log(`[REDIS] Stream stream:${room} is empty, starting from 0`);
      }
    } catch (error) {
      lastIds[`stream:${room}`] = "0";  // On error, start from beginning
      console.log(`[REDIS] Error checking stream:${room}, starting from 0`);
    }
  }

  console.log("Starting to read from Redis streams...");

  while (true) {
    try {
      // Read from all room streams
      const streams = rooms.map(room => ({ key: `stream:${room}`, id: lastIds[`stream:${room}`] }));
      
      const results: any = await redis.xRead(
        streams,
        { BLOCK: 1000 }
      );

      if (results) {
        console.log(`[REDIS] Read ${results.length} stream(s) with new messages`);
        
        for (const stream of results) {
          const roomKey = stream.name;
          const roomId = roomKey.replace("stream:", "");
          
          for (const msgData of stream.messages) {
            const { id, message } = msgData;
            lastIds[roomKey] = id;
            const msg = { id, roomId, ...message };
            console.log("[REDIS] Read message from Redis:", msg);
            callback(roomId, msg);
          }
        }
      } else {
        // No new messages in this iteration
        console.log("[REDIS] No new messages (timeout)");
      }
    } catch (error) {
      console.error("Error reading from Redis:", error);
      connectionHealthy = false;
      await attemptReconnection();
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
}

// Health check function
export function getRedisHealth() {
  return {
    connected: connectionHealthy,
    currentInstance: hasMultipleInstances ? urls[currentUrlIndex] : redisUrl,
    reconnectAttempts,
    lastHealthCheck,
    timeSinceLastCheck: Date.now() - lastHealthCheck,
    availableInstances: urls.length
  };
}

// Force reconnection if needed
export async function ensureRedisConnection() {
  if (!connectionHealthy) {
    console.log("[REDIS] Forcing reconnection...");
    await attemptReconnection();
  }
  return redis;
}
