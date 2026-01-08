import { useEffect, useState } from "react";
import { io, Socket } from "socket.io-client";

export function useSocket() {
  const [socket, setSocket] = useState<Socket | null>(null);
  const [connected, setConnected] = useState(false);
  const [nodeId, setNodeId] = useState("unknown");

  useEffect(() => {
    // Get chat node URL from environment or use localhost
    // For distributed setup, set VITE_CHAT_NODE_URL in .env
    const chatNodeUrl = import.meta.env.VITE_CHAT_NODE_URL || 'http://192.168.100.231:3001';
    
    // Support comma-separated list for multiple nodes
    const chatNodes = chatNodeUrl.split(',').map(url => url.trim());
    const socketUrl = chatNodes[Math.floor(Math.random() * chatNodes.length)];
    console.log('Connecting to:', socketUrl);
    
    const sock = io(socketUrl, {
      autoConnect: true,
      transports: ["websocket", "polling"],
      reconnection: true,
      reconnectionAttempts: Infinity,
      reconnectionDelay: 1000,
    });

    sock.on("connect", () => {
      setConnected(true);
    });

    sock.on("disconnect", () => {
      setConnected(false);
    });

    // IMPORTANT:
    // Each gateway sends its own ID to identify which node you're connected to
    sock.on("node-info", (info) => {
      setNodeId(info.nodeId);
    });

    setSocket(sock);
    return () => {
      sock.close();
    };
  }, []);

  return { socket, connected, nodeId };
}