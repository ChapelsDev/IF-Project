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

export interface RoomPresence {
  roomId: string;
  userId: string;
  username: string;
}

// Rate limiting
export interface RateLimitConfig {
  windowMs: number;
  maxRequests: number;
}

export interface RateLimitEntry {
  count: number;
  resetTime: number;
}

// Circuit breaker states
export enum CircuitState {
  CLOSED = 'CLOSED',
  OPEN = 'OPEN',
  HALF_OPEN = 'HALF_OPEN'
}

export interface CircuitBreakerConfig {
  failureThreshold: number;
  successThreshold: number;
  timeout: number;
  resetTimeout: number;
}
