import { Socket } from 'socket.io-client';
import { MessageInput } from "./messageInput";
import { MessageList } from "./messageList";
import { TypingIndicator } from "./typingIndicator";

interface ChatWindowProps {
  socket: Socket;
  roomId: string;
  nodePort?: number;
}

export function ChatWindow({ socket, roomId, nodePort }: ChatWindowProps) {
  return (
    <div className="chat-window">
      <div className="room-header">#{roomId}</div>
      <MessageList socket={socket} roomId={roomId} nodePort={nodePort} />
      <TypingIndicator socket={socket} roomId={roomId} />
      <MessageInput socket={socket} roomId={roomId} />
    </div>
  );
}
