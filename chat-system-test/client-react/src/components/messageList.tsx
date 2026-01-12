import { useEffect, useRef, useState } from "react";
import { Socket } from 'socket.io-client';
import { Message } from '../types';

interface MessageListProps {
  socket: Socket;
  roomId: string;
}

export function MessageList({ socket, roomId }: MessageListProps) {
  const [messages, setMessages] = useState<Message[]>([]);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  // Auto-scroll to bottom when messages change
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  useEffect(() => {
    if (!socket) return;

    // Clear messages when switching rooms
    setMessages([]);

    socket.emit("join", roomId);

    // Listen for message history when joining a room
    const handleHistory = ({ roomId: historyRoomId, messages }: { roomId: string; messages: Message[] }) => {
      if (historyRoomId === roomId) {
        console.log("Received history:", messages);
        setMessages(messages);
      }
    };

    const handleMessage = (msg: Message) => {
      console.log("Received message:", msg);
      // Only add messages for the current room
      if (msg.id) {
        setMessages((prev) => [...prev, msg]);
      }
    };

    const handleFileMessage = (msg: any) => {
      console.log("Received file message:", msg);
      if (msg.id) {
        setMessages((prev) => [...prev, {
          id: msg.id,
          user: msg.username,
          text: `[FILE] ${msg.originalName}`,
          fileUrl: msg.fileUrl,
          fileName: msg.fileName,
          timestamp: parseInt(msg.ts) || Date.now(),
          ts: msg.ts
        }]);
      }
    };

    socket.on("history", handleHistory);
    socket.on("message", handleMessage);
    socket.on("fileMessage", handleFileMessage);

    return () => {
      socket.off("message", handleMessage);
      socket.off("history", handleHistory);
      socket.off("fileMessage", handleFileMessage);
    };
  }, [socket, roomId]);

  return (
    <div className="message-list">
      {messages.map((m) => {
        // Convert SeaweedFS URL to chat node proxy URL
        const downloadUrl = m.fileUrl 
          ? m.fileUrl.replace(/https?:\/\/[^/]+/, import.meta.env.VITE_CHAT_URL || 'http://localhost:3001').replace('/chat-files/', '/download/chat-files/')
          : '';
        
        return (
          <div key={m.id}>
            <b>{m.user}</b>: {m.text}
            {m.fileUrl && (
              <div style={{ marginTop: '5px' }}>
                <a 
                  href={downloadUrl} 
                  download
                  style={{ 
                    color: '#2196F3', 
                    textDecoration: 'underline',
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: '5px'
                  }}
                >
                  📎 Download File
                </a>
              </div>
            )}
          </div>
        );
      })}
      <div ref={messagesEndRef} />
    </div>
  );
}
