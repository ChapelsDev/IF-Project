import { useEffect, useRef, useState } from "react";

export function MessageInput({ socket, roomId }) {
  const [text, setText] = useState("");
  const typingTimeoutRef = useRef(null);

  const handleTyping = () => {
    if (!socket) return;
    
    // Emit typing start
    socket.emit("typing", { roomId, isTyping: true });
    
    // Clear existing timeout
    if (typingTimeoutRef.current) {
      clearTimeout(typingTimeoutRef.current);
    }
    
    // Set timeout to emit typing stop
    typingTimeoutRef.current = setTimeout(() => {
      socket.emit("typing", { roomId, isTyping: false });
    }, 1000);
  };

  const sendMessage = () => {
    if (!text.trim()) return;
    socket.emit("message", { roomId, text });
    setText("");
    
    // Stop typing indicator when sending
    if (typingTimeoutRef.current) {
      clearTimeout(typingTimeoutRef.current);
    }
    socket.emit("typing", { roomId, isTyping: false });
  };

  useEffect(() => {
    return () => {
      if (typingTimeoutRef.current) {
        clearTimeout(typingTimeoutRef.current);
      }
    };
  }, []);

  return (
    <div className="input-bar">
      <input
        value={text}
        onChange={(e) => {
          setText(e.target.value);
          handleTyping();
        }}
        onKeyUp={(e) => e.key === "Enter" && sendMessage()}
        placeholder="Type a message..."
      />
      <button onClick={sendMessage}>Send</button>
    </div>
  );
}
