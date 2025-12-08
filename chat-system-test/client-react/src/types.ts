import { Socket } from 'socket.io-client';

export interface Message {
  id: string;
  user: string;
  text: string;
  timestamp: number;
}

export interface User {
  userId: string;
  username: string;
  joinedAt: number;
}

export interface SocketType extends Socket {
  // Add any custom properties if needed
}
