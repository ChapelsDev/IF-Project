import { createClient, createCluster } from "redis";

// Support both single Redis and Redis Cluster
const redisUrl = process.env.REDIS_URL || "redis://127.0.0.1:6379";
const isCluster = redisUrl.includes(",");

let redis: any;

if (isCluster) {
  // Redis Cluster mode with multiple nodes
  const nodes = redisUrl.split(",").map(url => ({ url: url.trim() }));
  console.log("[REDIS] Connecting to cluster:", nodes);
  redis = createCluster({ rootNodes: nodes });
} else {
  // Single Redis instance
  console.log("[REDIS] Connecting to single instance:", redisUrl);
  redis = createClient({ url: redisUrl });
}

redis.connect().then(() => {
  console.log("[REDIS] Connected successfully");
}).catch((err: any) => {
  console.error("[REDIS] Connection failed:", err);
});

export async function appendMessage(roomId: string, user: string, text: string) {
  const msg = { roomId, user, text, ts: Date.now().toString() };
  console.log("[REDIS] Appending message to stream:", msg);
  const id = await redis.xAdd(
    `stream:${roomId}`,
    "*",
    msg
  );
  console.log(`[REDIS] Message appended with ID: ${id}`);
  return id;
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
export async function isUsernameAvailable(username: string): Promise<boolean> {
  const normalizedUsername = username.toLowerCase();
  const exists = await redis.exists(`username:${normalizedUsername}`);
  return exists === 0;
}

export async function registerUsername(username: string, userId: string) {
  const normalizedUsername = username.toLowerCase();
  // Set with 1 hour expiry (auto-cleanup if user doesn't disconnect properly)
  await redis.setEx(`username:${normalizedUsername}`, 3600, JSON.stringify({ originalUsername: username, userId, registeredAt: Date.now() }));
}

export async function unregisterUsername(username: string) {
  const normalizedUsername = username.toLowerCase();
  await redis.del(`username:${normalizedUsername}`);
}

export async function addUserToRoom(roomId: string, userId: string, username: string) {
  await redis.hSet(`room:${roomId}:users`, userId, JSON.stringify({ username, joinedAt: Date.now() }));
}

export async function removeUserFromRoom(roomId: string, userId: string) {
  await redis.hDel(`room:${roomId}:users`, userId);
}

export async function getRoomUsers(roomId: string) {
  const users = await redis.hGetAll(`room:${roomId}:users`);
  return Object.entries(users).map(([userId, data]) => ({
    userId,
    ...JSON.parse(data as string)
  }));
}

export async function removeUserFromAllRooms(userId: string) {
  const rooms = ["general", "tech", "random", "games", "projects"];
  for (const room of rooms) {
    await removeUserFromRoom(room, userId);
  }
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
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
}
