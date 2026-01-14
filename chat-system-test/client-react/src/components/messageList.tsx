import { useEffect, useRef, useState } from "react";
import { Socket } from 'socket.io-client';
import { Message } from '../types';

interface MessageListProps {
  socket: Socket;
  roomId: string;
  nodePort?: number;
}

export function MessageList({ socket, roomId, nodePort = 3001 }: MessageListProps) {
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

    // Accumulate all history messages before setting state
    const historyMessages: Message[] = [];
    const historyMessageIds = new Set<string>();
    let historyReceived = false;

    // Listen for message history when joining a room
    const handleHistory = ({ roomId: historyRoomId, messages }: { roomId: string; messages: Message[] }) => {
      if (historyRoomId === roomId) {
        console.log("Received history:", messages);
        // Add messages, avoiding duplicates
        messages.forEach(msg => {
          if (!historyMessageIds.has(msg.id)) {
            historyMessages.push(msg);
            historyMessageIds.add(msg.id);
          }
        });
        historyReceived = true;
        
        // Set a small timeout to allow fileMessage events to arrive
        setTimeout(() => {
          // Sort all messages by timestamp and remove any remaining duplicates
          const sorted = historyMessages.sort((a, b) => {
            const tsA = a.timestamp || parseInt(a.ts || '0');
            const tsB = b.timestamp || parseInt(b.ts || '0');
            return tsA - tsB;
          });
          
          // Final deduplication based on ID
          const uniqueMessages = sorted.filter((msg, index, self) => 
            index === self.findIndex(m => m.id === msg.id)
          );
          
          setMessages(uniqueMessages);
        }, 100);
      }
    };

    const handleMessage = (msg: Message) => {
      console.log("Received message:", msg);
      // Only add messages for the current room
      if (msg.id) {
        setMessages((prev) => {
          // Check if message already exists
          if (prev.some(m => m.id === msg.id)) {
            return prev;
          }
          return [...prev, msg];
        });
      }
    };

    const handleFileMessage = (msg: any) => {
      console.log("Received file message:", msg);
      if (msg.id) {
        const fileMsg = {
          id: msg.id,
          user: msg.username,
          text: `[FILE] ${msg.originalName}`,
          fileUrl: msg.fileUrl,
          fileName: msg.fileName,
          timestamp: parseInt(msg.ts) || Date.now(),
          ts: msg.ts
        };
        
        // If we're still loading history, add to the accumulator (avoid duplicates)
        if (!historyReceived || historyMessages.length > 0) {
          if (!historyMessageIds.has(fileMsg.id)) {
            historyMessages.push(fileMsg);
            historyMessageIds.add(fileMsg.id);
          }
        } else {
          // New file message after history loaded
          setMessages((prev) => {
            // Check if message already exists
            if (prev.some(m => m.id === fileMsg.id)) {
              return prev;
            }
            return [...prev, fileMsg];
          });
        }
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
        // Build download URL using the connected node's port
        // Extract host from VITE_CHAT_URL and replace port with nodePort
        const chatUrl = import.meta.env.VITE_CHAT_URL || 'http://localhost:3001';
        const hostMatch = chatUrl.match(/^(https?:\/\/[^:]+)/);
        const host = hostMatch ? hostMatch[1] : 'http://localhost';
        const downloadBaseUrl = `${host}:${nodePort}`;
        
        const downloadUrl = m.fileUrl 
          ? m.fileUrl.replace(/https?:\/\/[^/]+/, downloadBaseUrl).replace('/chat-files/', '/download/chat-files/')
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
