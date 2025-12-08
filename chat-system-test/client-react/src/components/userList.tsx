import { useEffect, useState } from "react";
import { Socket } from 'socket.io-client';
import { User } from '../types';

interface UserListProps {
  socket: Socket;
  roomId: string;
}

export function UserList({ socket, roomId }: UserListProps) {
  const [users, setUsers] = useState<User[]>([]);

  useEffect(() => {
    if (!socket) return;

    const handleUserList = ({ roomId: listRoomId, users }: { roomId: string; users: User[] }) => {
      if (listRoomId === roomId) {
        setUsers(users);
      }
    };

    const handleUserJoined = ({ roomId: joinRoomId, userId, username }: { roomId: string; userId: string; username: string }) => {
      if (joinRoomId === roomId) {
        setUsers((prev) => {
          // Avoid duplicates
          if (prev.find(u => u.userId === userId)) return prev;
          return [...prev, { userId, username, joinedAt: Date.now() }];
        });
      }
    };

    const handleUserLeft = ({ roomId: leaveRoomId, userId }: { roomId: string; userId: string }) => {
      if (leaveRoomId === roomId) {
        setUsers((prev) => prev.filter(u => u.userId !== userId));
      }
    };

    socket.on("userList", handleUserList);
    socket.on("userJoined", handleUserJoined);
    socket.on("userLeft", handleUserLeft);

    return () => {
      socket.off("userList", handleUserList);
      socket.off("userJoined", handleUserJoined);
      socket.off("userLeft", handleUserLeft);
    };
  }, [socket, roomId]);

  return (
    <div className="user-list">
      <h3>Online Users ({users.length})</h3>
      <ul>
        {users.map((user) => (
          <li key={user.userId}>
            <span className="status-dot">●</span> {user.username}
          </li>
        ))}
      </ul>
    </div>
  );
}
