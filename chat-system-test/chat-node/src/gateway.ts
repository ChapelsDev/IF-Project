import { createServer } from "http";
import { Server } from "socket.io";
import Busboy from "busboy";
import { natsCircuitBreaker, redisCircuitBreaker } from "./circuitBreaker";
import { publishPresence, publishPrivateMessage, publishUsernameRegistration, publishUsernameUnregistration, subscribeToMessages, subscribeToPresence, subscribeToPrivateMessages, subscribeToUsernameRegistrations, subscribeToUsernameUnregistrations } from "./nats";
import { connectionLimiter, messageLimiter, privateMessageLimiter } from "./rateLimit";
import { addUserToRoom, appendMessage, getMessageHistory, getPrivateMessageHistory, getRoomUsers, isUsernameAvailable, registerUsername, removeUserFromAllRooms, removeUserFromRoom, sendPrivateMessage } from "./redis";
import { sanitizeUsername, validateMessagePayload, validatePrivateMessagePayload } from "./sanitizer";
import { checkSeaweedHealth, downloadFromSeaweed, uploadToSeaweed } from "./seaweed";
import { generateToken, TokenPayload, validateSocketAuth } from "./tokenValidation";

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
  const port = parseInt(process.env.PORT || (3000 + parseInt(process.env.NODE_ID || "1")).toString());
  
  const httpServer = createServer(async (req: any, res: any) => {
    // Set CORS and security headers for all requests
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    res.setHeader('Access-Control-Max-Age', '86400'); // 24 hours
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'SAMEORIGIN');
    
    // Handle preflight OPTIONS request
    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }
    
    if (req.url === "/health") {
      const health = {
        status: isShuttingDown ? "shutting_down" : "ok",
        nodeId: process.env.NODE_ID,
        serviceId: process.env.SERVICE_ID,
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

    if (req.url === "/metrics") {
      // Prometheus-style metrics endpoint
      const metrics = [
        `# HELP chat_connections_total Total number of active WebSocket connections`,
        `# TYPE chat_connections_total gauge`,
        `chat_connections_total{node_id="${process.env.NODE_ID}",service_id="${process.env.SERVICE_ID}"} ${activeConnections.size}`,
        ``,
        `# HELP chat_redis_circuit_breaker Redis circuit breaker state (0=closed, 1=half_open, 2=open)`,
        `# TYPE chat_redis_circuit_breaker gauge`,
        `chat_redis_circuit_breaker{node_id="${process.env.NODE_ID}"} ${redisCircuitBreaker.getState() === 'CLOSED' ? 0 : redisCircuitBreaker.getState() === 'HALF_OPEN' ? 1 : 2}`,
        ``,
        `# HELP chat_nats_circuit_breaker NATS circuit breaker state (0=closed, 1=half_open, 2=open)`,
        `# TYPE chat_nats_circuit_breaker gauge`,
        `chat_nats_circuit_breaker{node_id="${process.env.NODE_ID}"} ${natsCircuitBreaker.getState() === 'CLOSED' ? 0 : natsCircuitBreaker.getState() === 'HALF_OPEN' ? 1 : 2}`,
        ``,
        `# HELP chat_health_status Node health status (1=ok, 0=unhealthy)`,
        `# TYPE chat_health_status gauge`,
        `chat_health_status{node_id="${process.env.NODE_ID}"} ${isShuttingDown ? 0 : 1}`,
      ].join('\n');
      
      res.writeHead(200, { "Content-Type": "text/plain; version=0.0.4" });
      res.end(metrics);
      return;
    }

    // File upload endpoint - supports multipart/form-data
    if (req.url?.startsWith("/upload") && req.method === "POST") {
      // Parse query parameters for filerIp
      const urlParts = req.url.split('?');
      const queryParams = new URLSearchParams(urlParts[1] || '');
      const filerIp = queryParams.get('filerIp') || process.env.FILESTORE_URL || 'http://localhost:8888';
      
      const busboy = Busboy({ headers: req.headers });
      let fileBuffer: Buffer | null = null;
      let fileName = '';
      let username = 'anonymous';
      
      busboy.on('file', (fieldname: string, file: any, info: any) => {
        const { filename } = info;
        fileName = filename;
        const chunks: Buffer[] = [];
        
        file.on('data', (chunk: Buffer) => {
          chunks.push(chunk);
        });
        
        file.on('end', () => {
          fileBuffer = Buffer.concat(chunks);
        });
      });
      
      busboy.on('field', (fieldname: string, value: string) => {
        if (fieldname === 'username') {
          username = value;
        }
      });
      
      busboy.on('finish', async () => {
        try {
          if (!fileBuffer || !fileName) {
            res.writeHead(400, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: "Missing file or filename" }));
            return;
          }

          // Upload to SeaweedFS with custom filerIp
          const result = await uploadToSeaweed(fileBuffer, fileName, username, filerIp);
          
          if (result.success) {
            res.writeHead(200, { 
              "Content-Type": "application/json",
              "Access-Control-Allow-Origin": "*"
            });
            res.end(JSON.stringify({ 
              success: true,
              fileUrl: result.fileUrl,
              fileName: result.fileName
            }));
          } else {
            res.writeHead(500, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: result.error || "Upload failed" }));
          }
        } catch (error: any) {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: error.message }));
        }
      });
      
      req.pipe(busboy);
      return;
    }

    // File download endpoint (proxy to SeaweedFS) - supports filerIp query param
    if (req.url?.startsWith("/download/") && req.method === "GET") {
      // Parse URL and query parameters
      const urlParts = req.url.split('?');
      const pathPart = urlParts[0].replace("/download", "");
      const queryParams = new URLSearchParams(urlParts[1] || '');
      const filerIp = queryParams.get('filerIp') || process.env.FILESTORE_URL || 'http://localhost:8888';
      
      const fileBuffer = await downloadFromSeaweed(pathPart, filerIp);
      
      if (fileBuffer) {
        const filename = pathPart.split('/').pop() || 'download';
        res.writeHead(200, { 
          "Content-Type": "application/octet-stream",
          "Content-Disposition": `attachment; filename="${filename}"`,
          "Content-Transfer-Encoding": "binary",
          "Content-Length": fileBuffer.length.toString(),
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type",
          "Access-Control-Expose-Headers": "Content-Disposition, Content-Length",
          "X-Content-Type-Options": "nosniff",
          "Cache-Control": "public, max-age=31536000"
        });
        res.end(fileBuffer);
      } else {
        res.writeHead(404, { 
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*"
        });
        res.end(JSON.stringify({ error: "File not found" }));
      }
      return;
    }
    
    // Handle OPTIONS preflight for download endpoint
    if (req.url?.startsWith("/download/") && req.method === "OPTIONS") {
      res.writeHead(200, {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type"
      });
      res.end();
      return;
    }

    // SeaweedFS health check
    if (req.url === "/seaweed/health") {
      const isHealthy = await checkSeaweedHealth();
      res.writeHead(isHealthy ? 200 : 503, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ healthy: isHealthy }));
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
        
        // Broadcast username registration to all nodes via NATS
        await natsCircuitBreaker.executeWithFallback(
          () => publishUsernameRegistration(sanitized, socket.id),
          () => Promise.resolve()
        );
        
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
        const msgId = await redisCircuitBreaker.executeWithFallback(
          () => appendMessage(roomId, socket.username || socket.id, text, socket.id),
          () => {
            console.log(`[GATEWAY] Redis unavailable, message not persisted`);
            return Promise.resolve('fallback-id');
          }
        );
        
        // Create message object to send back to sender immediately
        // Use 'user' field to match the format from Redis/NATS
        const messageObj = {
          id: msgId,
          userId: socket.id,
          user: socket.username || socket.id,
          text: text,
          roomId: roomId,
          ts: Date.now().toString()
        };
        
        // Send the message back to the sender immediately (acknowledgment)
        // This prevents the echo when the message comes back through NATS
        socket.emit("message", messageObj);
        
        // Publish to NATS so other nodes receive it immediately
        await natsCircuitBreaker.executeWithFallback(
          async () => {
            const { publishMessage } = await import("./nats");
            await publishMessage(roomId, messageObj);
          },
          () => {
            console.log(`[GATEWAY] NATS unavailable, message not broadcast to other nodes`);
            return Promise.resolve();
          }
        );
        
        console.log(`[GATEWAY] Message processed successfully and acknowledged to sender`);
        
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
      
      // Parse history to separate regular messages from file messages
      const regularMessages = [];
      const fileMessages = [];
      
      for (const msg of history) {
        try {
          // Check if text field is a JSON string (file message)
          const parsed = JSON.parse(msg.text);
          if (parsed.type === 'file') {
            fileMessages.push({
              id: msg.id,
              ...parsed
            });
          } else {
            regularMessages.push(msg);
          }
        } catch (e) {
          // Not JSON, it's a regular message
          regularMessages.push(msg);
        }
      }
      
      // Send regular messages as history
      socket.emit("history", { roomId, messages: regularMessages });
      
      // Send file messages separately
      for (const fileMsg of fileMessages) {
        socket.emit("fileMessage", fileMsg);
      }
      
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
    
    // File upload via Socket.IO
    socket.on("uploadFile", async (payload: any) => {
      try {
        if (!socket.username) {
          socket.emit("uploadError", { error: "Username must be set before uploading files" });
          return;
        }

        const { filename, data, roomId } = payload;

        if (!filename || !data) {
          socket.emit("uploadError", { error: "Missing filename or data" });
          return;
        }

        console.log(`[GATEWAY] File upload from ${socket.username}: ${filename}`);

        // Upload to SeaweedFS
        const result = await uploadToSeaweed(data, filename, socket.username);

        if (result.success) {
          // Send success response
          socket.emit("uploadSuccess", {
            fileUrl: result.fileUrl,
            fileName: result.fileName,
            originalName: filename
          });

          // If roomId provided, send file share message to room
          if (roomId) {
            const fileMessage: any = {
              type: 'file',
              fileUrl: result.fileUrl,
              fileName: result.fileName,
              originalName: filename,
              username: socket.username,
              roomId,
              ts: Date.now().toString()
            };

            // Store in Redis
            const msgId = await redisCircuitBreaker.executeWithFallback(
              () => appendMessage(roomId, socket.username, JSON.stringify(fileMessage), socket.id),
              () => {
                console.log(`[GATEWAY] Redis unavailable, file message not persisted`);
                return Promise.resolve('fallback-id');
              }
            );

            fileMessage.id = msgId;
            fileMessage.userId = socket.id;
            
            // Broadcast to all users in the room on this node
            io.to(roomId).emit("fileMessage", fileMessage);
            
            // Publish to NATS so other nodes receive it
            await natsCircuitBreaker.executeWithFallback(
              async () => {
                const { publishMessage } = await import("./nats");
                // Create message format that NATS subscriber expects
                const natsMessage = {
                  id: msgId,
                  userId: socket.id,
                  user: socket.username,
                  text: JSON.stringify(fileMessage),
                  roomId: roomId,
                  ts: fileMessage.ts
                };
                await publishMessage(roomId, natsMessage);
              },
              () => {
                console.log(`[GATEWAY] NATS unavailable, file message not broadcast to other nodes`);
                return Promise.resolve();
              }
            );
          }

          console.log(`[GATEWAY] File uploaded successfully: ${result.fileUrl}`);
        } else {
          socket.emit("uploadError", { error: result.error || "Upload failed" });
        }
      } catch (error: any) {
        console.error(`[GATEWAY] File upload error:`, error.message);
        socket.emit("uploadError", { error: error.message });
      }
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
        const disconnectedUsername = socket.username;
        
        // Remove username mapping
        usernameToSocketId.delete(socket.username);
        
        // Broadcast username unregistration to all nodes
        await natsCircuitBreaker.executeWithFallback(
          () => publishUsernameUnregistration(disconnectedUsername),
          () => Promise.resolve()
        );
        
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
    
    // Send node information to client - use SERVICE_ID for full identification
    socket.emit("node-info", { nodeId: process.env.SERVICE_ID || process.env.NODE_ID });
  });

  // Subscribe to NATS messages and broadcast to Socket.IO clients
  const rooms = ["general", "tech", "random", "games", "projects"];
  rooms.forEach(room => {
    subscribeToMessages(room, (msg: any) => {
      console.log(`[GATEWAY] Received from NATS for room ${room}:`, msg);
      console.log(`[GATEWAY] Broadcasting to ${io.sockets.adapter.rooms.get(room)?.size || 0} clients in room ${room}`);
      
      // Check if this is a file message (text field contains JSON with type: 'file')
      let isFileMessage = false;
      try {
        const parsed = JSON.parse(msg.text);
        if (parsed.type === 'file') {
          isFileMessage = true;
          // Emit as fileMessage instead
          if (msg.userId) {
            io.to(room).except(msg.userId).emit("fileMessage", { id: msg.id, ...parsed });
          } else {
            io.to(room).emit("fileMessage", { id: msg.id, ...parsed });
          }
        }
      } catch (e) {
        // Not JSON, it's a regular message
      }
      
      // Only emit regular message if it's not a file message
      if (!isFileMessage) {
        // Broadcast to all clients in the room EXCEPT the original sender
        // This prevents the echo effect where the sender receives their own message twice
        if (msg.userId) {
          console.log(`[GATEWAY] Broadcasting to room ${room} except sender ${msg.userId}`);
          io.to(room).except(msg.userId).emit("message", msg);
        } else {
          // If no userId (older messages from history), broadcast to all
          io.to(room).emit("message", msg);
        }
      }
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

  // Subscribe to username registrations from other nodes
  console.log("[GATEWAY] Setting up username synchronization subscriptions...");
  subscribeToUsernameRegistrations((data: any) => {
    console.log(`[GATEWAY] Username registered on another node: ${data.username} (${data.userId})`);
    // Don't override if this user is connected to this node
    if (!usernameToSocketId.has(data.username)) {
      // This is just for awareness - the actual socket connection is on another node
      console.log(`[GATEWAY] Username ${data.username} tracked (remote node)`);
    }
  });

  subscribeToUsernameUnregistrations((data: any) => {
    console.log(`[GATEWAY] Username unregistered on another node: ${data.username}`);
    // Clean up local mapping if it exists (shouldn't normally, but just in case)
    usernameToSocketId.delete(data.username);
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
