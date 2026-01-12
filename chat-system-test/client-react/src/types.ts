import { Socket } from 'socket.io-client';

export interface Message {
  id: string;
  user: string;
  text: string;
  timestamp: number;
  fileUrl?: string;
  fileName?: string;
  ts?: string;
}

export interface PrivateMessage {
  id: string;
  from: string;
  to: string;
  text: string;
  timestamp: number;
  ts?: string;
  read?: boolean;
}

export interface User {
  userId: string;
  username: string;
  joinedAt: number;
}

export interface SocketType extends Socket {
  // Add any custom properties if needed
}
