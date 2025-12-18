import jwt from 'jsonwebtoken';

// JWT secret - should be stored in environment variable in production
const JWT_SECRET = process.env.JWT_SECRET || 'your-secret-key-change-in-production';
const JWT_EXPIRY = '24h';

export interface TokenPayload {
  userId: string;
  username: string;
  iat?: number;
  exp?: number;
}

/**
 * Generate a JWT token for a user
 */
export function generateToken(userId: string, username: string): string {
  return jwt.sign({ userId, username }, JWT_SECRET, { expiresIn: JWT_EXPIRY });
}

/**
 * Verify and decode a JWT token
 * @throws Error if token is invalid or expired
 */
export function verifyToken(token: string): TokenPayload {
  try {
    const decoded = jwt.verify(token, JWT_SECRET) as TokenPayload;
    return decoded;
  } catch (error: any) {
    if (error.name === 'TokenExpiredError') {
      throw new Error('Token has expired');
    } else if (error.name === 'JsonWebTokenError') {
      throw new Error('Invalid token');
    }
    throw new Error('Token verification failed');
  }
}

/**
 * Extract token from authorization header or query string
 */
export function extractToken(authHeader?: string, query?: any): string | null {
  // Try Authorization header first (Bearer token)
  if (authHeader && authHeader.startsWith('Bearer ')) {
    return authHeader.substring(7);
  }
  
  // Fall back to query parameter (for WebSocket initial connection)
  if (query && query.token) {
    return query.token;
  }
  
  return null;
}

/**
 * Validate socket authentication
 */
export function validateSocketAuth(socket: any): TokenPayload | null {
  try {
    const token = extractToken(
      socket.handshake.auth?.token,
      socket.handshake.query
    );
    
    if (!token) {
      return null;
    }
    
    return verifyToken(token);
  } catch (error) {
    console.error('[AUTH] Token validation failed:', error);
    return null;
  }
}
