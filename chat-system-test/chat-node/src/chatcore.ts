import { publishMessage } from "./nats";
import { readMessages } from "./redis";

export function startChatCore() {
  console.log("Chat-Core running...");

  // Only node 1 reads from Redis to avoid duplicate processing
  if (process.env.NODE_ID === "1") {
    console.log("This node will read from Redis streams");
    // Start reading messages in background (don't await)
    readMessages((roomId: string, msg: any) => {
      console.log(`[CHATCORE] Callback triggered for room ${roomId}, publishing to NATS:`, msg);
      publishMessage(roomId, msg);
    }).catch(error => {
      console.error("[CHATCORE] Fatal error in readMessages:", error);
    });
  } else {
    console.log("This node will only listen to NATS broadcasts");
  }
}
