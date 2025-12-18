/**
 * Input sanitization utilities for chat messages
 */

/**
 * Sanitize text to prevent XSS and injection attacks
 */
export function sanitizeText(text: string): string {
  if (!text || typeof text !== 'string') {
    return '';
  }

  // Trim whitespace
  let sanitized = text.trim();

  // Remove null bytes
  sanitized = sanitized.replace(/\0/g, '');

  // Encode HTML special characters
  sanitized = sanitized
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;')
    .replace(/\//g, '&#x2F;');

  // Limit length
  if (sanitized.length > 2000) {
    sanitized = sanitized.substring(0, 2000);
  }

  return sanitized;
}

/**
 * Sanitize username
 */
export function sanitizeUsername(username: string): string {
  if (!username || typeof username !== 'string') {
    return '';
  }

  // Trim and limit length
  let sanitized = username.trim();
  
  if (sanitized.length < 2 || sanitized.length > 20) {
    throw new Error('Username must be between 2-20 characters');
  }

  // Only allow alphanumeric, underscore, and hyphen
  if (!/^[a-zA-Z0-9_-]+$/.test(sanitized)) {
    throw new Error('Username can only contain letters, numbers, underscore, and hyphen');
  }

  return sanitized;
}

/**
 * Sanitize room ID
 */
export function sanitizeRoomId(roomId: string): string {
  if (!roomId || typeof roomId !== 'string') {
    return '';
  }

  const sanitized = roomId.trim().toLowerCase();

  // Only allow alphanumeric and hyphen
  if (!/^[a-z0-9-]+$/.test(sanitized)) {
    throw new Error('Invalid room ID format');
  }

  if (sanitized.length < 1 || sanitized.length > 50) {
    throw new Error('Room ID must be between 1-50 characters');
  }

  return sanitized;
}

/**
 * Validate and sanitize message payload
 */
export function validateMessagePayload(payload: any): { roomId: string; text: string } {
  if (!payload || typeof payload !== 'object') {
    throw new Error('Invalid message payload');
  }

  const { roomId, text } = payload;

  if (!roomId || !text) {
    throw new Error('Message must include roomId and text');
  }

  return {
    roomId: sanitizeRoomId(roomId),
    text: sanitizeText(text)
  };
}

/**
 * Validate and sanitize private message payload
 */
export function validatePrivateMessagePayload(payload: any): { to: string; text: string } {
  if (!payload || typeof payload !== 'object') {
    throw new Error('Invalid private message payload');
  }

  const { to, text } = payload;

  if (!to || !text) {
    throw new Error('Private message must include to and text');
  }

  return {
    to: sanitizeUsername(to),
    text: sanitizeText(text)
  };
}
