import React, { createContext, useContext, useEffect, useState } from 'react'
import { io, Socket } from 'socket.io-client'

interface SocketContextType {
  socket: Socket | null
  nodeId: string | null
  isConnected: boolean
}

const SocketContext = createContext<SocketContextType>({
  socket: null,
  nodeId: null,
  isConnected: false
})

export const useSocketContext = () => useContext(SocketContext)

export const SocketProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [socket, setSocket] = useState<Socket | null>(null)
  const [nodeId, setNodeId] = useState<string | null>(null)
  const [isConnected, setIsConnected] = useState(false)

  useEffect(() => {
    // Get chat node URL from environment or use detected IP
    // For distributed setup, set VITE_CHAT_NODE_URL in .env
    const chatNodeUrl = import.meta.env.VITE_CHAT_NODE_URL || 'http://192.168.100.231:3001';
    
    // Support comma-separated list for multiple nodes
    const chatNodes = chatNodeUrl.split(',').map((url: string) => url.trim());
    const socketUrl = chatNodes[Math.floor(Math.random() * chatNodes.length)];
    console.log('Connecting to:', socketUrl);
    
    const newSocket = io(socketUrl, {
      reconnection: true,
      reconnectionDelay: 1000,
      reconnectionAttempts: 10,
      transports: ['websocket', 'polling']
    })

    newSocket.on('connect', () => {
      console.log('Connected to chat server')
      setIsConnected(true)
    })

    newSocket.on('disconnect', () => {
      console.log('Disconnected from chat server')
      setIsConnected(false)
    })

    newSocket.on('node-info', (data: { nodeId: string }) => {
      console.log('Connected to node:', data.nodeId)
      setNodeId(data.nodeId)
    })

    setSocket(newSocket)

    return () => {
      newSocket.close()
    }
  }, [])

  return (
    <SocketContext.Provider value={{ socket, nodeId, isConnected }}>
      {children}
    </SocketContext.Provider>
  )
}
