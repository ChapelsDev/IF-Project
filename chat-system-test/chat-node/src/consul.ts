import axios from "axios";

export async function registerWithConsul() {
  const CONSUL = process.env.CONSUL_URL;
  const NODE_ID = process.env.NODE_ID;

  // Register the service
  await axios.put(`${CONSUL}/v1/agent/service/register`, {
    Name: "chat-node",
    ID: `chat-node-${NODE_ID}`,
    Address: "127.0.0.1",
    Port: 3000 + parseInt(NODE_ID || "1"),
    Check: {
      HTTP: `http://127.0.0.1:${3000 + parseInt(NODE_ID || "1")}/health`,
      Interval: "10s"
    }
  });

  console.log(`Registered chat-node-${NODE_ID} with Consul`);
}
