export interface Message {
  id: string;
  roomId: string;
  user: string;
  text: string;
  ts: string;
}

export interface PrivateMessage {
  id: string;
  from: string;
  to: string;
  text: string;
  ts: string;
  read?: boolean;
}

export interface User {
  userId: string;
  username: string;
  joinedAt: number;
}
