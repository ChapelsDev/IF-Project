import { startChatCore } from "./chatcore";
import { ClusterDiscovery } from "./cluster-discovery";
import { startGateway } from "./gateway";

const SERVICE_NAME = 'chat-service';
const NODE_ID = process.env.NODE_ID || '1';
const SERVICE_ID = process.env.SERVICE_ID || `chat-node-${NODE_ID}`;
const PORT = parseInt(process.env.PORT || '3001');
const HOST_IP = process.env.HOST_IP || 'localhost';
const CLUSTER_MODE = process.env.CLUSTER_MODE === 'true';
const CLUSTER_CONSUL_URL = process.env.CLUSTER_CONSUL_URL || 'http://172.20.10.10:8500';
// Prefer an explicit CONSUL_URL env (set by manager). If not provided, default to local agent.
const CONSUL_URL = process.env.CONSUL_URL || 'http://127.0.0.1:8500';

let discovery: ClusterDiscovery;

async function initializeDiscovery() {
  discovery = new ClusterDiscovery(
    CONSUL_URL,
    SERVICE_NAME,
    SERVICE_ID,
    HOST_IP,
    PORT
  );

  // Discover and connect to infrastructure if needed
  if (CLUSTER_MODE) {
    console.log('🔍 Discovering cluster infrastructure...');
    const infra = await discovery.discoverInfrastructure();
    if (infra.redis) {
      console.log(`✓ Discovered Redis at ${infra.redis.address}:${infra.redis.port}`);
    }
    if (infra.nats) {
      console.log(`✓ Discovered NATS at ${infra.nats.address}:${infra.nats.port}`);
    }
  }

  // Register this node
  await discovery.register(['chat', `node-${NODE_ID}`]);

  // Discover peer nodes
  const peers = await discovery.discoverPeers();
  console.log(`✓ Found ${peers.length} peer chat nodes`);
  peers.forEach(peer => {
    console.log(`  - ${peer.id} at ${peer.address}:${peer.port}`);
  });

  // Watch for new/removed nodes
  discovery.watchService(SERVICE_NAME, (instances) => {
    const peerCount = instances.filter(i => i.id !== SERVICE_ID).length;
    console.log(`🔄 Peer nodes changed: ${peerCount} peers now available`);
  });
}

async function shutdown() {
  console.log('\n🛑 Shutting down...');
  if (discovery) {
    await discovery.deregister();
  }
  process.exit(0);
}

(async () => {
  console.log(`🚀 Starting chat-node ${NODE_ID}`);
  console.log(`   Mode: ${CLUSTER_MODE ? 'Cluster' : 'Local'}`);
  console.log(`   Port: ${PORT}`);
  console.log(`   Host: ${HOST_IP}`);

  try {
    // Initialize cluster discovery and registration
    await initializeDiscovery();
    console.log('✓ Node initialized and registered with cluster');

    // Start services
    startGateway();  // Socket.IO server
    startChatCore(); // Redis consumer + NATS producer

    console.log('✓ Chat node ready');
  } catch (error) {
    console.error('❌ Failed to initialize:', error);
    process.exit(1);
  }

  // Graceful shutdown handlers
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
})();
