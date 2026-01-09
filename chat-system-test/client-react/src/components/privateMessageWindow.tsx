import { useEffect, useState } from "react";
import { Socket } from "socket.io-client";
import { PrivateMessage } from "../types";

interface PrivateMessageWindowProps {
  socket: Socket;
  currentUser: string;
  otherUser: string;
  onClose: () => void;
}

export function PrivateMessageWindow({ socket, currentUser, otherUser, onClose }: PrivateMessageWindowProps) {
  const [messages, setMessages] = useState<PrivateMessage[]>([]);
  const [inputText, setInputText] = useState("");

  useEffect(() => {
    console.log("[PM] Setting up private message window for:", otherUser);
    
    // Request message history
    socket.emit("getPrivateMessages", { otherUser });

    const handlePrivateMessage = (msg: PrivateMessage) => {
      console.log("[PM] Received private message:", msg);
      // Only show messages in this conversation
      if ((msg.from === otherUser && msg.to === currentUser) || 
          (msg.from === currentUser && msg.to === otherUser)) {
        console.log("[PM] Message belongs to this conversation, adding to state");
        setMessages((prev) => {
          // Avoid duplicates
          if (prev.some(m => m.id === msg.id)) {
            console.log("[PM] Duplicate message, ignoring");
            return prev;
          }
          return [...prev, msg];
        });
      }
    };

    const handlePrivateMessageHistory = ({ otherUser: user, messages: history }: { otherUser: string, messages: PrivateMessage[] }) => {
      console.log("[PM] Received message history for:", user, "messages:", history.length);
      if (user === otherUser) {
        setMessages(history);
      }
    };

    socket.on("privateMessage", handlePrivateMessage);
    socket.on("privateMessageHistory", handlePrivateMessageHistory);

    return () => {
      socket.off("privateMessage", handlePrivateMessage);
      socket.off("privateMessageHistory", handlePrivateMessageHistory);
    };
  }, [socket, currentUser, otherUser]);

  const handleSend = () => {
    if (inputText.trim()) {
      console.log("[PM] Sending private message to:", otherUser, "text:", inputText.trim());
      socket.emit("privateMessage", { to: otherUser, text: inputText.trim() });
      setInputText("");
    }
  };

  const handleKeyPress = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  return (
    <div style={{
      position: "fixed",
      bottom: "20px",
      right: "20px",
      width: "400px",
      height: "500px",
      backgroundColor: "#2c2c2c",
      border: "1px solid #444",
      borderRadius: "8px",
      display: "flex",
      flexDirection: "column",
      zIndex: 1000,
      boxShadow: "0 4px 8px rgba(0,0,0,0.3)"
    }}>
      {/* Header */}
      <div style={{
        padding: "15px",
        borderBottom: "1px solid #444",
        display: "flex",
        justifyContent: "space-between",
        alignItems: "center",
        backgroundColor: "#1e1e1e"
      }}>
        <h3 style={{ margin: 0, fontSize: "16px" }}>Private Chat with {otherUser}</h3>
        <button 
          onClick={onClose}
          style={{
            background: "none",
            border: "none",
            color: "#fff",
            fontSize: "20px",
            cursor: "pointer",
            padding: "0 5px"
          }}
        >
          ×
        </button>
      </div>

      {/* Messages */}
      <div style={{
        flex: 1,
        overflowY: "auto",
        padding: "15px",
        display: "flex",
        flexDirection: "column",
        gap: "10px"
      }}>
        {messages.map((msg) => {
          const isFromMe = msg.from === currentUser;
          return (
            <div
              key={msg.id}
              style={{
                alignSelf: isFromMe ? "flex-end" : "flex-start",
                maxWidth: "70%",
                backgroundColor: isFromMe ? "#0084ff" : "#3a3a3a",
                padding: "10px",
                borderRadius: "12px",
                wordBreak: "break-word"
              }}
            >
              <div style={{ fontSize: "10px", opacity: 0.7, marginBottom: "5px" }}>
                {isFromMe ? "You" : msg.from}
              </div>
              <div>{msg.text}</div>
              <div style={{ fontSize: "10px", opacity: 0.5, marginTop: "5px", textAlign: "right" }}>
                {new Date(msg.ts ? parseInt(msg.ts) : msg.timestamp).toLocaleTimeString()}
              </div>
            </div>
          );
        })}
      </div>

      {/* Input */}
      <div style={{
        padding: "15px",
        borderTop: "1px solid #444",
        display: "flex",
        gap: "10px"
      }}>
        <input
          type="text"
          value={inputText}
          onChange={(e) => setInputText(e.target.value)}
          onKeyPress={handleKeyPress}
          placeholder="Type a message..."
          style={{
            flex: 1,
            padding: "10px",
            backgroundColor: "#1e1e1e",
            border: "1px solid #444",
            borderRadius: "4px",
            color: "#fff",
            outline: "none"
          }}
        />
        <button
          onClick={handleSend}
          style={{
            padding: "10px 20px",
            backgroundColor: "#0084ff",
            border: "none",
            borderRadius: "4px",
            color: "#fff",
            cursor: "pointer",
            fontWeight: "bold"
          }}
        >
          Send
        </button>
      </div>
    </div>
  );
}
