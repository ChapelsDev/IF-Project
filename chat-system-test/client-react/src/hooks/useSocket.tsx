import { useEffect, useState } from "react";
import { io, Socket } from "socket.io-client";

export function useSocket() {
  const [socket, setSocket] = useState<Socket | null>(null);
  const [connected, setConnected] = useState(false);
  const [nodeId, setNodeId] = useState("unknown");

  useEffect(() => {
    // Round-robin load balancing: randomly pick one of the 3 chat nodes
    const chatNodes = [
      'http://localhost:3001',
      'http://localhost:3002',
      'http://localhost:3003'
    ];
    const socketUrl = chatNodes[Math.floor(Math.random() * chatNodes.length)];
    console.log('Connecting to:', socketUrl);
    
    const sock = io(socketUrl, {
      autoConnect: true,
      transports: ["websocket"],
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