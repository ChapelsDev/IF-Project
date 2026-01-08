import axios from "axios";

export async function registerWithConsul() {
  const CONSUL = process.env.CONSUL_URL;
  const NODE_ID = process.env.NODE_ID;
  // Optional explicit service id (should be unique per host)
  const SERVICE_ID = process.env.SERVICE_ID || `chat-node-${NODE_ID}`;
  const ADDRESS = process.env.HOST_IP || "127.0.0.1";
  // Prefer an explicit PORT env (set by manager), otherwise fall back to previous logic
  const PORT = parseInt(process.env.PORT || (3000 + parseInt(NODE_ID || "1")) as any, 10);

  // Register the service using host address and explicit port so multiple hosts can register
  // Use the canonical service name 'chat-service' so nodes discover each other
  await axios.put(`${CONSUL}/v1/agent/service/register`, {
    Name: "chat-service",
    ID: SERVICE_ID,
    Address: ADDRESS,
    Port: PORT,
    Check: {
      HTTP: `http://${ADDRESS}:${PORT}/health`,
      Interval: "10s"
    }
  });

  console.log(`Registered ${SERVICE_ID} with Consul at ${ADDRESS}:${PORT}`);
}
