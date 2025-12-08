import { useEffect, useState } from "react";
import { Socket } from 'socket.io-client';

interface TypingIndicatorProps {
  socket: Socket;
  roomId: string;
}

export function TypingIndicator({ socket, roomId }: TypingIndicatorProps) {
  const [typingUsers, setTypingUsers] = useState<Set<string>>(new Set());

  useEffect(() => {
    if (!socket) return;

    const typingTimeouts = new Map<string, NodeJS.Timeout>();

    const handleUserTyping = ({ roomId: typingRoomId, userId, username, isTyping }: { roomId: string; userId: string; username: string; isTyping: boolean }) => {
      if (typingRoomId !== roomId) return;

      // Clear existing timeout for this user
      if (typingTimeouts.has(userId)) {
        clearTimeout(typingTimeouts.get(userId));
        typingTimeouts.delete(userId);
      }

      if (isTyping) {
        setTypingUsers((prev) => new Set(prev).add(username || userId));
        
        // Auto-remove after 3 seconds of inactivity
        const timeout = setTimeout(() => {
          setTypingUsers((prev) => {
            const newSet = new Set(prev);
            newSet.delete(username || userId);
            return newSet;
          });
          typingTimeouts.delete(userId);
        }, 3000);
        
        typingTimeouts.set(userId, timeout);
      } else {
        setTypingUsers((prev) => {
          const newSet = new Set(prev);
          newSet.delete(username || userId);
          return newSet;
        });
      }
    };

    socket.on("userTyping", handleUserTyping);

    return () => {
      socket.off("userTyping", handleUserTyping);
      // Clear all timeouts
      typingTimeouts.forEach(timeout => clearTimeout(timeout));
    };
  }, [socket, roomId]);

  if (typingUsers.size === 0) return null;

  const typingArray = Array.from(typingUsers);
  const typingText = typingArray.length === 1
    ? `${typingArray[0]} is typing...`
    : typingArray.length === 2
    ? `${typingArray[0]} and ${typingArray[1]} are typing...`
    : `${typingArray.length} users are typing...`;

  return (
    <div className="typing-indicator">
      <span className="typing-dots">●●●</span> {typingText}
    </div>
  );
}
