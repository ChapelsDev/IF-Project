import { createServer } from "http";
import { Server } from "socket.io";
import { publishPresence, publishPrivateMessage, subscribeToMessages, subscribeToPresence, subscribeToPrivateMessages } from "./nats";
import { addUserToRoom, appendMessage, getMessageHistory, getPrivateMessageHistory, getRoomUsers, isUsernameAvailable, registerUsername, removeUserFromAllRooms, removeUserFromRoom, sendPrivateMessage, unregisterUsername } from "./redis";

let io: Server;
const usernameToSocketId = new Map<string, string>();

export function getIO() {
  return io;
}

export function startGateway() {
  const port = 3000 + parseInt(process.env.NODE_ID || "1");
  
  const httpServer = createServer((req: any, res: any) => {
    if (req.url === "/health") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok", nodeId: process.env.NODE_ID }));
      return;
    }
    res.writeHead(404);
    res.end();
  });

  io = new Server(httpServer, { cors: { origin: "*" } });

  io.on("connection", (socket: any) => {
    console.log("User connected:", socket.id);
    let currentRoom: string | null = null;

    socket.on("setUsername", async (username: string) => {
      const sanitized = (username || "").trim();
      
      if (!sanitized || sanitized.length < 2 || sanitized.length > 20) {
        socket.emit("usernameError", { error: "Username must be between 2-20 characters" });
        return;
      }
      
      // Check if username is already taken (allow reconnects)
      const available = await isUsernameAvailable(sanitized, socket.id);
      if (!available) {
        socket.emit("usernameError", { error: "Username is already taken" });
        return;
      }
      
      // Register username globally
      await registerUsername(sanitized, socket.id);
      socket.username = sanitized;
      
      // Map username to socket ID for private message routing
      usernameToSocketId.set(sanitized, socket.id);
      console.log(`[GATEWAY] Mapped username ${sanitized} to socket ${socket.id}`);
      
      socket.emit("usernameAccepted", { username: sanitized });
      console.log(`User ${socket.id} set username: ${socket.username}`);
    });

    socket.on("message", async ({ roomId, text }: any) => {
      console.log(`[GATEWAY] Received message from client:`, { roomId, user: socket.username || socket.id, text });
      await appendMessage(roomId, socket.username || socket.id, text);
      console.log(`[GATEWAY] Message appended to Redis`);
    });

    socket.on("join", async (roomId: any) => {
      // Require username to be set before joining
      if (!socket.username) {
        socket.emit("error", { message: "Username must be set before joining a room" });
        return;
      }
      
      console.log(`User ${socket.id} (${socket.username}) joining room: ${roomId}`);
      
      // Leave previous room if any
      if (currentRoom) {
        socket.leave(currentRoom);
        await removeUserFromRoom(currentRoom, socket.username);
        publishPresence("leave", { roomId: currentRoom, userId: socket.id, username: socket.username });
      }
      
      currentRoom = roomId;
      socket.join(roomId);
      
      // Add user to room presence
      await addUserToRoom(roomId, socket.id, socket.username);
      
      // Send message history when user joins a room
      const history = await getMessageHistory(roomId, 50);
      console.log(`Sending ${history.length} messages to user ${socket.id} for room ${roomId}`);
      socket.emit("history", { roomId, messages: history });
      
      // Send current users list
      const users = await getRoomUsers(roomId);
      socket.emit("userList", { roomId, users });
      
      // Notify others that user joined
      publishPresence("join", { roomId, userId: socket.id, username: socket.username });
      
      // Confirm the join
      socket.emit("joined", { roomId });
      console.log(`[GATEWAY] User ${socket.id} confirmed in room ${roomId}`);
    });

    socket.on("typing", ({ roomId, isTyping }: any) => {
      publishPresence("typing", { roomId, userId: socket.id, username: socket.username || socket.id, isTyping });
    });
    
    // Private messaging handlers
    socket.on("privateMessage", async ({ to, text }: any) => {
      console.log(`[GATEWAY] privateMessage event received from socket ${socket.id}`);
      console.log(`[GATEWAY] Socket username: ${socket.username}, to: ${to}, text: ${text}`);
      
      if (!socket.username) {
        console.log(`[GATEWAY] ERROR: Username not set for socket ${socket.id}`);
        socket.emit("error", { message: "Username must be set before sending private messages" });
        return;
      }
      
      console.log(`[GATEWAY] Private message from ${socket.username} to ${to}: ${text}`);
      
      // Store in Redis
      const msgId = await sendPrivateMessage(socket.username, to, text);
      console.log(`[GATEWAY] Message stored in Redis with ID: ${msgId}`);
      
      // Create message object
      const msg = {
        id: msgId,
        from: socket.username,
        to,
        text,
        ts: Date.now().toString()
      };
      
      // Publish via NATS to reach the recipient on any node
      console.log(`[GATEWAY] Publishing to NATS for user: ${to}`);
      await publishPrivateMessage(to, msg);
      
      // Echo back to sender
      console.log(`[GATEWAY] Echoing message back to sender`);
      socket.emit("privateMessage", msg);
    });
    
    socket.on("getPrivateMessages", async ({ otherUser }: any) => {
      if (!socket.username) {
        socket.emit("error", { message: "Username must be set" });
        return;
      }
      
      console.log(`[GATEWAY] Getting private messages between ${socket.username} and ${otherUser}`);
      const history = await getPrivateMessageHistory(socket.username, otherUser, 50);
      socket.emit("privateMessageHistory", { otherUser, messages: history });
    });
    
    socket.on("disconnect", async () => {
      console.log("User disconnected:", socket.id, socket.username);
      if (socket.username) {
        // Remove username mapping
        usernameToSocketId.delete(socket.username);
        
        // Don't immediately unregister - let TTL handle it (allows reconnects)
        // Only clean up room presence
        await removeUserFromAllRooms(socket.username);
        if (currentRoom) {
          publishPresence("leave", { roomId: currentRoom, userId: socket.id, username: socket.username });
        }
      }
    });
    
    socket.emit("node-info", { nodeId: process.env.NODE_ID });
  });

  // Subscribe to NATS messages and broadcast to Socket.IO clients
  const rooms = ["general", "tech", "random", "games", "projects"];
  rooms.forEach(room => {
    subscribeToMessages(room, (msg: any) => {
      console.log(`[GATEWAY] Received from NATS for room ${room}:`, msg);
      console.log(`[GATEWAY] Broadcasting to ${io.sockets.adapter.rooms.get(room)?.size || 0} clients in room ${room}`);
      io.to(room).emit("message", msg);
    });
  });
  
  // Subscribe to presence events
  subscribeToPresence("join", (data: any) => {
    console.log(`[GATEWAY] User joined:`, data);
    io.to(data.roomId).emit("userJoined", data);
  });
  
  subscribeToPresence("leave", (data: any) => {
    console.log(`[GATEWAY] User left:`, data);
    io.to(data.roomId).emit("userLeft", data);
  });
  
  subscribeToPresence("typing", (data: any) => {
    io.to(data.roomId).emit("userTyping", data);
  });

  // Subscribe to private messages with wildcard to handle all users
  // This allows any node to receive and route private messages
  console.log("[GATEWAY] Setting up private message subscription...");
  subscribeToPrivateMessages("*", (msg: any) => {
    console.log(`[GATEWAY] Received private message via NATS:`, msg);
    const targetSocketId = usernameToSocketId.get(msg.to);
    
    if (targetSocketId) {
      console.log(`[GATEWAY] Routing private message to socket ${targetSocketId} (user: ${msg.to})`);
      io.to(targetSocketId).emit("privateMessage", msg);
    } else {
      console.log(`[GATEWAY] User ${msg.to} not connected to this node`);
    }
  });

  httpServer.listen(port);
  console.log(`Gateway listening on port ${port}`);
}
