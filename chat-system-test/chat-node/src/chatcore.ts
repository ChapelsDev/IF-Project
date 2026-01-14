
export function startChatCore() {
  console.log("Chat-Core running...");

  // ALL nodes now publish messages to NATS immediately when sent
  // Redis is only used for persistent storage (history)
  // No need for Node 1 to read from Redis streams anymore
  console.log("Messages are published to NATS directly by sending nodes");
  console.log("Redis is used only for persistent message history");
  
  // Note: ALL nodes can read message history directly from Redis when users join
  // This is done in gateway.ts when handling the 'join' event
}
