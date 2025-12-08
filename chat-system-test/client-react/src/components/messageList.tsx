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

    socket.on("history", handleHistory);
    socket.on("message", handleMessage);

    return () => {
      socket.off("message", handleMessage);
      socket.off("history", handleHistory);
    };
  }, [socket, roomId]);

  return (
    <div className="message-list">
      {messages.map((m) => (
        <div key={m.id}>
          <b>{m.user}</b>: {m.text}
        </div>
      ))}
      <div ref={messagesEndRef} />
    </div>
  );
}
