import { useEffect, useRef, useState } from "react";
import { Socket } from 'socket.io-client';

interface MessageInputProps {
  socket: Socket;
  roomId: string;
}

export function MessageInput({ socket, roomId }: MessageInputProps) {
  const [text, setText] = useState("");
  const [uploading, setUploading] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const typingTimeoutRef = useRef<NodeJS.Timeout | null>(null);

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
    }, 1000) as NodeJS.Timeout;
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

  const handleFileSelect = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    setUploading(true);

    try {
      // Read file as base64
      const reader = new FileReader();
      reader.onload = () => {
        const base64 = reader.result?.toString().split(',')[1];
        
        // Emit file upload event via Socket.IO
        socket.emit("uploadFile", {
          filename: file.name,
          data: base64,
          roomId
        });
      };
      reader.readAsDataURL(file);

      // Listen for upload result
      const handleUploadSuccess = (data: any) => {
        console.log("File uploaded successfully:", data);
        setUploading(false);
        socket.off("uploadSuccess", handleUploadSuccess);
        socket.off("uploadError", handleUploadError);
      };

      const handleUploadError = (error: any) => {
        console.error("File upload failed:", error);
        alert(`Upload failed: ${error.error}`);
        setUploading(false);
        socket.off("uploadSuccess", handleUploadSuccess);
        socket.off("uploadError", handleUploadError);
      };

      socket.on("uploadSuccess", handleUploadSuccess);
      socket.on("uploadError", handleUploadError);

    } catch (error: any) {
      console.error("File selection error:", error);
      setUploading(false);
    }

    // Reset file input
    if (fileInputRef.current) {
      fileInputRef.current.value = '';
    }
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
      <input
        ref={fileInputRef}
        type="file"
        style={{ display: 'none' }}
        onChange={handleFileSelect}
        disabled={uploading}
      />
      <button 
        onClick={() => fileInputRef.current?.click()}
        disabled={uploading}
        style={{ 
          marginRight: '5px',
          background: uploading ? '#ccc' : '#2196F3',
          cursor: uploading ? 'not-allowed' : 'pointer'
        }}
      >
        {uploading ? '⏳' : '📎'}
      </button>
      <button onClick={sendMessage}>Send</button>
    </div>
  );
}
