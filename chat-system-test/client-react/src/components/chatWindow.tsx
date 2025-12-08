import { MessageInput } from "./messageInput";
import { MessageList } from "./messageList";
import { TypingIndicator } from "./typingIndicator";

export function ChatWindow({ socket, roomId }) {
  return (
    <div className="chat-window">
      <div className="room-header">#{roomId}</div>
      <MessageList socket={socket} roomId={roomId} />
      <TypingIndicator socket={socket} roomId={roomId} />
      <MessageInput socket={socket} roomId={roomId} />
    </div>
  );
}
