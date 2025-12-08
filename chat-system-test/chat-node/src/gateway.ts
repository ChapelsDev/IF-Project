import { createServer } from "http";
import { Server } from "socket.io";
import { publishPresence, subscribeToMessages, subscribeToPresence } from "./nats";
import { addUserToRoom, appendMessage, getMessageHistory, getRoomUsers, isUsernameAvailable, registerUsername, removeUserFromAllRooms, removeUserFromRoom, unregisterUsername } from "./redis";

let io: Server;

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
      
      // Check if username is already taken
      const available = await isUsernameAvailable(sanitized);
      if (!available) {
        socket.emit("usernameError", { error: "Username is already taken" });
        return;
      }
      
      // Register username globally
      await registerUsername(sanitized, socket.id);
      socket.username = sanitized;
      socket.emit("usernameAccepted", { username: sanitized });
      console.log(`User ${socket.id} set username: ${socket.username}`);
    });

    socket.on("message", async ({ roomId, text }: any) => {
      console.log(`[GATEWAY] Received message from client:`, { roomId, user: socket.username || socket.id, text });
      await appendMessage(roomId, socket.username || socket.id, text);
      console.log(`[GATEWAY] Message appended to Redis`);
    });

    socket.on("join", async (roomId: any) => {
      console.log(`User ${socket.id} (${socket.username}) joining room: ${roomId}`);
      
      // Leave previous room if any
      if (currentRoom) {
        socket.leave(currentRoom);
        await removeUserFromRoom(currentRoom, socket.id);
        publishPresence("leave", { roomId: currentRoom, userId: socket.id, username: socket.username });
      }
      
      currentRoom = roomId;
      socket.join(roomId);
      
      // Add user to room presence
      await addUserToRoom(roomId, socket.id, socket.username || `User-${socket.id.substring(0, 6)}`);
      
      // Send message history when user joins a room
      const history = await getMessageHistory(roomId, 50);
      console.log(`Sending ${history.length} messages to user ${socket.id} for room ${roomId}`);
      socket.emit("history", { roomId, messages: history });
      
      // Send current users list
      const users = await getRoomUsers(roomId);
      socket.emit("userList", { roomId, users });
      
      // Notify others that user joined
      publishPresence("join", { roomId, userId: socket.id, username: socket.username || `User-${socket.id.substring(0, 6)}` });
      
      // Confirm the join
      socket.emit("joined", { roomId });
      console.log(`[GATEWAY] User ${socket.id} confirmed in room ${roomId}`);
    });

    socket.on("typing", ({ roomId, isTyping }: any) => {
      publishPresence("typing", { roomId, userId: socket.id, username: socket.username || socket.id, isTyping });
    });
    
    socket.on("disconnect", async () => {
      console.log("User disconnected:", socket.id);
      if (socket.username) {
        await unregisterUsername(socket.username);
      }
      if (currentRoom) {
        await removeUserFromRoom(currentRoom, socket.id);
        publishPresence("leave", { roomId: currentRoom, userId: socket.id, username: socket.username });
      }
      await removeUserFromAllRooms(socket.id);
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

  httpServer.listen(port);
  console.log(`Gateway listening on port ${port}`);
}
