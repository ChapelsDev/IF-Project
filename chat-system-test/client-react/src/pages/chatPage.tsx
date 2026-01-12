import { useEffect, useState } from "react";
import { ChatWindow } from "../components/chatWindow";
import { PrivateMessageWindow } from "../components/privateMessageWindow";
import { RoomList } from "../components/roomList";
import { StatusBar } from "../components/statusBar";
import { UserList } from "../components/userList";
import { FileUploadTest } from "../components/fileUploadTest";
import { useSocket } from "../hooks/useSocket";

export function ChatPage() {
  const { socket, connected, nodeId } = useSocket();
  const [room, setRoom] = useState("general");
  const [username, setUsername] = useState("");
  const [usernameSet, setUsernameSet] = useState(false);
  const [usernameError, setUsernameError] = useState("");
  const [privateChats, setPrivateChats] = useState<string[]>([]);

  useEffect(() => {
    if (!socket) return;

    const handleUsernameError = ({ error }: { error: string }) => {
      setUsernameError(error);
      setUsernameSet(false);
    };

    const handleUsernameAccepted = ({ username: acceptedUsername }: { username: string }) => {
      setUsernameError("");
      setUsernameSet(true);
      setUsername(acceptedUsername);
    };

    socket.on("usernameError", handleUsernameError);
    socket.on("usernameAccepted", handleUsernameAccepted);

    return () => {
      socket.off("usernameError", handleUsernameError);
      socket.off("usernameAccepted", handleUsernameAccepted);
    };
  }, [socket]);

  const handleLogout = () => {
    setUsernameSet(false);
    setUsername("");
    if (socket) {
      socket.disconnect();
      window.location.reload();
    }
  };

  const handleUserClick = (otherUser: string) => {
    if (!privateChats.includes(otherUser)) {
      setPrivateChats([...privateChats, otherUser]);
    }
  };

  const handleClosePM = (otherUser: string) => {
    setPrivateChats(privateChats.filter(u => u !== otherUser));
  };

  if (!socket) return <div>Loading socket...</div>;

  if (!usernameSet) {
    return (
      <div className="app" style={{ display: "flex", alignItems: "center", justifyContent: "center", height: "100vh" }}>
        <div style={{ textAlign: "center", padding: "20px" }}>
          <h2>Enter your username</h2>
          {usernameError && (
            <div style={{ color: "red", marginBottom: "10px", fontWeight: "bold" }}>
              {usernameError}
            </div>
          )}
          <input
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            onKeyUp={(e) => {
              if (e.key === "Enter" && username.trim()) {
                socket?.emit("setUsername", username.trim());
              }
            }}
            placeholder="Username (2-20 chars)..."
            style={{ padding: "10px", fontSize: "16px", marginRight: "10px" }}
          />
          <button 
            onClick={() => username.trim() && socket?.emit("setUsername", username.trim())}
            style={{ padding: "10px 20px", fontSize: "16px" }}
          >
            Join Chat
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="app">
      <StatusBar connected={connected} nodeId={nodeId} />
      <div style={{ position: "absolute", top: "10px", right: "10px", zIndex: 1000 }}>
        <span style={{ marginRight: "10px", fontWeight: "bold" }}>{username}</span>
        <button 
          onClick={handleLogout}
          style={{ 
            padding: "5px 15px", 
            fontSize: "14px",
            backgroundColor: "#ff4444",
            color: "white",
            border: "none",
            borderRadius: "4px",
            cursor: "pointer"
          }}
        >
          Logout
        </button>
      </div>
      <div className="layout">
        <RoomList currentRoom={room} setRoom={setRoom} />
        <ChatWindow socket={socket} roomId={room} />
        <UserList 
          socket={socket} 
          roomId={room} 
          currentUser={username}
          onUserClick={handleUserClick}
        />
      </div>
      
      {/* SeaweedFS Test Component */}
      <FileUploadTest backendUrl="http://localhost:3001" />
      
      {/* Private message windows */}
      {privateChats.map((otherUser, index) => (
        <div 
          key={otherUser}
          style={{
            position: "fixed",
            bottom: "20px",
            right: `${20 + index * 420}px`
          }}
        >
          <PrivateMessageWindow
            socket={socket}
            currentUser={username}
            otherUser={otherUser}
            onClose={() => handleClosePM(otherUser)}
          />
        </div>
      ))}
    </div>
  );
}
