import { useEffect, useState } from 'react'
import { Socket } from 'socket.io-client'

export interface Message {
  id: string
  roomId: string
  userId: string
  text: string
  timestamp: number
}

export const useRoom = (socket: Socket | null, roomId: string) => {
  const [messages, setMessages] = useState<Message[]>([])

  useEffect(() => {
    if (!socket || !roomId) return

    // Join the room
    socket.emit('join', roomId)

    // Listen for new messages
    const handleMessage = (message: Message) => {
      if (message.roomId === roomId) {
        setMessages((prev) => [...prev, message])
      }
    }

    socket.on('message', handleMessage)

    return () => {
      socket.off('message', handleMessage)
    }
  }, [socket, roomId])

  const sendMessage = (text: string) => {
    if (socket && text.trim()) {
      socket.emit('message', { roomId, text })
    }
  }

  return { messages, sendMessage }
}
