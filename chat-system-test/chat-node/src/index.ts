import { startGateway } from "./gateway";
import { startChatCore } from "./chatcore";
import { registerWithConsul } from "./consul";

(async () => {
  console.log("Starting chat-node", process.env.NODE_ID);

  await registerWithConsul();

  startGateway();  // Socket.IO server
  startChatCore(); // Redis consumer + NATS producer
})();
