import { useEffect, useRef, useState } from "react";
import { io, Socket } from "socket.io-client";

export function useSocket() {
  const [socket, setSocket] = useState<Socket | null>(null);
  const [connected, setConnected] = useState(false);
  const [nodeId, setNodeId] = useState("unknown");
  const hasRedirected = useRef(false);

  useEffect(() => {
    // Get chat URL from environment
    // VITE_CHAT_URL can be either:
    // 1. Load balancer: http://192.168.100.162:3000 (recommended)
    // 2. Direct node list: http://localhost:3001,http://localhost:3002,http://localhost:3003
    const chatUrl = import.meta.env.VITE_CHAT_URL || 'http://localhost:3001';
    
    console.log(`[Socket] Connecting to: ${chatUrl}`);
    
    const sock = io(chatUrl, {
      autoConnect: true,
      transports: ["websocket", "polling"],
      reconnection: true,
      reconnectionAttempts: 5,
      reconnectionDelay: 1000,
      reconnectionDelayMax: 3000,
      timeout: 5000,
    });

    // Handle redirect from load balancer
    sock.on("redirect", (data: { url: string; nodeId: string; message: string }) => {
      if (hasRedirected.current) {
        console.log('[Socket] Already redirected, ignoring duplicate redirect');
        return;
      }
      
      console.log(`[Socket] 🔀 Redirecting to ${data.nodeId}: ${data.url}`);
      hasRedirected.current = true;
      
      // Close load balancer connection
      sock.close();
      
      // Connect to actual chat node
      const nodeSock = io(data.url, {
        autoConnect: true,
        transports: ["websocket", "polling"],
        reconnection: true,
        reconnectionAttempts: 10,
        reconnectionDelay: 1000,
        timeout: 5000,
      });

      nodeSock.on("connect", () => {
        console.log(`[Socket] ✓ Connected to ${data.url}`);
        setConnected(true);
      });

      nodeSock.on("disconnect", (reason) => {
        console.log(`[Socket] Disconnected: ${reason}`);
        setConnected(false);
        
        // On disconnect, reconnect to load balancer for re-routing
        if (reason === 'io server disconnect' || reason === 'transport close') {
          console.log('[Socket] Reconnecting to load balancer for failover...');
          hasRedirected.current = false;
          setTimeout(() => {
            window.location.reload();
          }, 2000);
        }
      });

      nodeSock.on("connect_error", (error) => {
        console.error(`[Socket] Connection error:`, error.message);
      });

      nodeSock.on("node-info", (info) => {
        setNodeId(info.nodeId);
        console.log(`[Socket] Connected to node: ${info.nodeId}`);
      });

      setSocket(nodeSock);
    });

    sock.on("connect", () => {
      console.log(`[Socket] ✓ Connected to load balancer`);
      // If no redirect happens (direct connection mode), set connected
      if (!hasRedirected.current) {
        setConnected(true);
      }
    });

    sock.on("disconnect", (reason) => {
      console.log(`[Socket] Disconnected from load balancer: ${reason}`);
      if (!hasRedirected.current) {
        setConnected(false);
      }
    });

    sock.on("connect_error", (error) => {
      console.error(`[Socket] Load balancer connection error:`, error.message);
    });

    // For direct connection (no load balancer)
    sock.on("node-info", (info) => {
      setNodeId(info.nodeId);
      console.log(`[Socket] Connected to node: ${info.nodeId}`);
    });

    sock.on("error", (error: { message: string }) => {
      console.error(`[Socket] Error: ${error.message}`);
    });

    setSocket(sock);

    return () => {
      sock.close();
    };
  }, []);

  return { socket, connected, nodeId };
}