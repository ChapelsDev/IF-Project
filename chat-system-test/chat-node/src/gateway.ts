import { createServer } from "http";
import { Server } from "socket.io";
import { publishPresence, publishPrivateMessage, subscribeToMessages, subscribeToPresence, subscribeToPrivateMessages } from "./nats";
import { addUserToRoom, appendMessage, getMessageHistory, getPrivateMessageHistory, getRoomUsers, isUsernameAvailable, registerUsername, removeUserFromAllRooms, removeUserFromRoom, sendPrivateMessage, unregisterUsername } from "./redis";
import { validateSocketAuth, generateToken, TokenPayload } from "./tokenValidation";
import { messageLimiter, connectionLimiter, privateMessageLimiter } from "./rateLimit";
import { sanitizeUsername, sanitizeText, validateMessagePayload, validatePrivateMessagePayload } from "./sanitizer";
import { redisCircuitBreaker, natsCircuitBreaker } from "./circuitBreaker";

// Extend Socket type to include custom properties
interface ExtendedSocket {
  id: string;
  username?: string;
  tokenData?: TokenPayload;
  handshake: any;
  emit: any;
  on: any;
  join: any;
  leave: any;
  disconnect: any;
}

let io: Server;
const usernameToSocketId = new Map<string, string>();
const activeConnections = new Map<string, { socket: any; username: string }>();
let isShuttingDown = false;

export function getIO() {
  return io;
}

export function startGateway() {
  const port = 3000 + parseInt(process.env.NODE_ID || "1");
  
  const httpServer = createServer((req: any, res: any) => {
    if (req.url === "/health") {
      const health = {
        status: isShuttingDown ? "shutting_down" : "ok",
        nodeId: process.env.NODE_ID,
        connections: activeConnections.size,
        redis: redisCircuitBreaker.getState(),
        nats: natsCircuitBreaker.getState(),
        timestamp: Date.now()
      };
      
      // Return 503 if shutting down or dependencies are down
      const statusCode = (isShuttingDown || 
                         redisCircuitBreaker.getState() === 'OPEN' || 
                         natsCircuitBreaker.getState() === 'OPEN') ? 503 : 200;
      
      res.writeHead(statusCode, { "Content-Type": "application/json" });
      res.end(JSON.stringify(health));
      return;
    }
    
    if (req.url === "/ready") {
      // Readiness check - only ready if not shutting down
      const ready = !isShuttingDown;
      res.writeHead(ready ? 200 : 503, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ready, connections: activeConnections.size }));
      return;
    }
    
    res.writeHead(404);
    res.end();
  });

  io = new Server(httpServer, { 
    cors: { 
      origin: process.env.ALLOWED_ORIGINS?.split(',') || "*",
      credentials: true
    },
    maxHttpBufferSize: 1e6, // 1MB max message size
    pingTimeout: 60000,
    pingInterval: 25000
  });

  // Middleware for connection authentication (optional - can be disabled for development)
  io.use((socket: any, next) => {
    // Check if shutting down
    if (isShuttingDown) {
      return next(new Error('Server is shutting down'));
    }
    
    // Rate limit connections by IP
    const clientIp = socket.handshake.address;
    if (!connectionLimiter.checkLimit(clientIp)) {
      console.log(`[SECURITY] Connection rate limit exceeded for ${clientIp}`);
      return next(new Error('Too many connection attempts'));
    }
    
    // Optional: Token authentication (enable in production)
    if (process.env.REQUIRE_AUTH === 'true') {
      const tokenData = validateSocketAuth(socket);
      if (!tokenData) {
        return next(new Error('Authentication required'));
      }
      (socket as ExtendedSocket).tokenData = tokenData;
    }
    
    next();
  });

  io.on("connection", (socket: any) => {
    console.log(`[GATEWAY] User connected: ${socket.id} from ${socket.handshake.address}`);
    let currentRoom: string | null = null;
    
    // Track active connection
    activeConnections.set(socket.id, { socket, username: '' });

    socket.on("setUsername", async (username: string) => {
      try {
        // Sanitize and validate username
        const sanitized = sanitizeUsername(username);
        
        // Check if username is already taken (allow reconnects)
        const available = await redisCircuitBreaker.executeWithFallback(
          () => isUsernameAvailable(sanitized, socket.id),
          () => true // Fallback: allow username if Redis is down
        );
        
        if (!available) {
          socket.emit("usernameError", { error: "Username is already taken" });
          return;
        }
        
        // Register username globally
        await redisCircuitBreaker.executeWithFallback(
          () => registerUsername(sanitized, socket.id),
          () => Promise.resolve()
        );
        
        socket.username = sanitized;
        
        // Map username to socket ID for private message routing
        usernameToSocketId.set(sanitized, socket.id);
        
        // Update active connection tracking
        const conn = activeConnections.get(socket.id);
        if (conn) conn.username = sanitized;
        
        console.log(`[GATEWAY] User ${socket.id} set username: ${sanitized}`);
        
        // Generate JWT token for the user (optional, for future auth)
        const token = generateToken(socket.id, sanitized);
        socket.emit("usernameAccepted", { username: sanitized, token });
        
      } catch (error: any) {
        console.error(`[GATEWAY] Username validation failed:`, error.message);
        socket.emit("usernameError", { error: error.message || "Invalid username" });
      }
    });

    socket.on("message", async (payload: any) => {
      try {
        // Validate and sanitize input
        const { roomId, text } = validateMessagePayload(payload);
        
        // Rate limiting check
        if (!messageLimiter.checkLimit(socket.id)) {
          socket.emit("error", { message: "Rate limit exceeded. Please slow down." });
          console.log(`[SECURITY] Message rate limit exceeded for ${socket.username || socket.id}`);
          return;
        }
        
        // Empty message check
        if (!text || text.length === 0) {
          return;
        }
        
        console.log(`[GATEWAY] Received message from ${socket.username || socket.id} to ${roomId}`);
        
        // Use circuit breaker for Redis operations
        await redisCircuitBreaker.executeWithFallback(
          () => appendMessage(roomId, socket.username || socket.id, text),
          () => {
            console.log(`[GATEWAY] Redis unavailable, message not persisted`);
            return Promise.resolve('fallback-id');
          }
        );
        
        console.log(`[GATEWAY] Message processed successfully`);
        
      } catch (error: any) {
        console.error(`[GATEWAY] Message handling error:`, error.message);
        socket.emit("error", { message: "Failed to send message" });
      }
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
    socket.on("privateMessage", async (payload: any) => {
      try {
        if (!socket.username) {
          socket.emit("error", { message: "Username must be set before sending private messages" });
          return;
        }
        
        // Validate and sanitize input
        const { to, text } = validatePrivateMessagePayload(payload);
        
        // Rate limiting check
        if (!privateMessageLimiter.checkLimit(socket.id)) {
          socket.emit("error", { message: "Private message rate limit exceeded" });
          console.log(`[SECURITY] Private message rate limit exceeded for ${socket.username}`);
          return;
        }
        
        // Empty message check
        if (!text || text.length === 0) {
          return;
        }
        
        console.log(`[GATEWAY] Private message from ${socket.username} to ${to}`);
        
        // Store in Redis with circuit breaker
        const msgId = await redisCircuitBreaker.executeWithFallback(
          () => sendPrivateMessage(socket.username, to, text),
          () => {
            console.log(`[GATEWAY] Redis unavailable, private message not persisted`);
            return Promise.resolve(`temp-${Date.now()}`);
          }
        );
        
        // Create message object
        const msg = {
          id: msgId,
          from: socket.username,
          to,
          text,
          ts: Date.now().toString()
        };
        
        // Publish via NATS to reach the recipient on any node
        await natsCircuitBreaker.executeWithFallback(
          () => publishPrivateMessage(to, msg),
          () => {
            console.log(`[GATEWAY] NATS unavailable, message may not be delivered`);
            return Promise.resolve();
          }
        );
        
        // Echo back to sender
        socket.emit("privateMessage", msg);
        
      } catch (error: any) {
        console.error(`[GATEWAY] Private message error:`, error.message);
        socket.emit("error", { message: "Failed to send private message" });
      }
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
      console.log(`[GATEWAY] User disconnected: ${socket.id} (${socket.username || 'anonymous'})`);
      
      // Remove from active connections tracking
      activeConnections.delete(socket.id);
      
      if (socket.username) {
        // Remove username mapping
        usernameToSocketId.delete(socket.username);
        
        // Clean up room presence with circuit breaker
        await redisCircuitBreaker.executeWithFallback(
          async () => {
            await removeUserFromAllRooms(socket.username);
          },
          () => {
            console.log(`[GATEWAY] Redis unavailable during disconnect cleanup`);
            return Promise.resolve();
          }
        );
        
        // Notify others that user left
        if (currentRoom) {
          await natsCircuitBreaker.executeWithFallback(
            () => publishPresence("leave", { roomId: currentRoom, userId: socket.id, username: socket.username }),
            () => Promise.resolve()
          );
        }
      }
      
      console.log(`[GATEWAY] Cleanup complete. Active connections: ${activeConnections.size}`);
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

  httpServer.listen(port, () => {
    console.log(`[GATEWAY] ✓ Chat service listening on port ${port}`);
    console.log(`[GATEWAY] Node ID: ${process.env.NODE_ID}`);
    console.log(`[GATEWAY] Security features: Rate limiting, input sanitization, circuit breakers`);
    console.log(`[GATEWAY] Health check: http://localhost:${port}/health`);
    console.log(`[GATEWAY] Readiness check: http://localhost:${port}/ready`);
  });

  // Graceful shutdown handler
  const gracefulShutdown = async (signal: string) => {
    console.log(`[GATEWAY] ${signal} received, starting graceful shutdown...`);
    isShuttingDown = true;

    // Stop accepting new connections
    httpServer.close(() => {
      console.log('[GATEWAY] HTTP server closed');
    });

    // Notify all connected clients
    const shutdownMessage = 'Server is shutting down. Please reconnect.';
    activeConnections.forEach(({ socket, username }) => {
      socket.emit('serverShutdown', { message: shutdownMessage });
    });

    // Wait a bit for clients to receive the notification
    await new Promise(resolve => setTimeout(resolve, 2000));

    // Close all Socket.IO connections
    const disconnectPromises: Promise<void>[] = [];
    activeConnections.forEach(({ socket }) => {
      disconnectPromises.push(
        new Promise(resolve => {
          socket.disconnect(true);
          resolve();
        })
      );
    });

    await Promise.all(disconnectPromises);
    console.log(`[GATEWAY] Disconnected ${disconnectPromises.length} clients`);

    // Close Socket.IO server
    await new Promise<void>(resolve => {
      io.close(() => {
        console.log('[GATEWAY] Socket.IO server closed');
        resolve();
      });
    });

    console.log('[GATEWAY] Graceful shutdown complete');
    process.exit(0);
  };

  // Register shutdown handlers
  process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
  process.on('SIGINT', () => gracefulShutdown('SIGINT'));

  // Handle uncaught errors
  process.on('uncaughtException', (error) => {
    console.error('[GATEWAY] Uncaught exception:', error);
    gracefulShutdown('UNCAUGHT_EXCEPTION');
  });

  process.on('unhandledRejection', (reason, promise) => {
    console.error('[GATEWAY] Unhandled rejection at:', promise, 'reason:', reason);
  });

  return { httpServer, io, gracefulShutdown };
}
