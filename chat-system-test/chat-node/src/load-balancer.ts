import axios from 'axios';
import express from 'express';
import { createServer } from 'http';
import { Server as SocketIOServer } from 'socket.io';

const PORT = parseInt(process.env.LB_PORT || '3001');
const CONSUL_URL = process.env.CONSUL_URL || 'http://192.168.100.53:8500';
const SERVICE_NAME = 'chat-service';
const HEALTH_CHECK_INTERVAL = 10000; // 10 seconds

interface ChatNode {
  id: string;
  address: string;
  port: number;
  healthy: boolean;
  connections: number;
}

class LoadBalancer {
  private app = express();
  private server = createServer(this.app);
  private io = new SocketIOServer(this.server, {
    cors: {
      origin: '*',
      methods: ['GET', 'POST']
    },
    transports: ['websocket', 'polling']
  });
  
  private chatNodes: Map<string, ChatNode> = new Map();
  private roundRobinIndex = 0;

  constructor() {
    this.setupRoutes();
    this.setupSocketIO();
    this.startHealthChecks();
  }

  private setupRoutes() {
    // Health check endpoint
    this.app.get('/health', (req, res) => {
      const healthyNodes = Array.from(this.chatNodes.values()).filter(n => n.healthy);
      res.json({
        status: 'healthy',
        role: 'load-balancer',
        port: PORT,
        availableNodes: healthyNodes.length,
        totalNodes: this.chatNodes.size,
        nodes: Array.from(this.chatNodes.values()).map(n => ({
          id: n.id,
          address: `${n.address}:${n.port}`,
          healthy: n.healthy,
          connections: n.connections
        }))
      });
    });

    // Metrics endpoint
    this.app.get('/metrics', (req, res) => {
      const healthyNodes = Array.from(this.chatNodes.values()).filter(n => n.healthy);
      const totalConnections = Array.from(this.chatNodes.values())
        .reduce((sum, n) => sum + n.connections, 0);
      
      let metrics = '';
      metrics += '# HELP lb_available_nodes Number of healthy chat nodes\n';
      metrics += '# TYPE lb_available_nodes gauge\n';
      metrics += `lb_available_nodes ${healthyNodes.length}\n`;
      metrics += '# HELP lb_total_connections Total connections across all nodes\n';
      metrics += '# TYPE lb_total_connections gauge\n';
      metrics += `lb_total_connections ${totalConnections}\n`;
      
      res.set('Content-Type', 'text/plain');
      res.send(metrics);
    });

    // List available nodes
    this.app.get('/nodes', (req, res) => {
      res.json({
        nodes: Array.from(this.chatNodes.values()).map(n => ({
          id: n.id,
          url: `http://${n.address}:${n.port}`,
          healthy: n.healthy,
          connections: n.connections
        }))
      });
    });
  }

  private setupSocketIO() {
    this.io.on('connection', async (socket) => {
      console.log(`📥 Client connected: ${socket.id}`);
      
      // Select best node
      const targetNode = this.selectNode();
      
      if (!targetNode) {
        console.error('❌ No healthy nodes available');
        socket.emit('error', { message: 'No chat nodes available. Please try again later.' });
        socket.disconnect();
        return;
      }

      console.log(`🔀 Redirecting ${socket.id} to ${targetNode.id} (${targetNode.address}:${targetNode.port})`);
      
      // Send redirect information to client
      socket.emit('redirect', {
        url: `http://${targetNode.address}:${targetNode.port}`,
        nodeId: targetNode.id,
        message: 'Redirecting to chat node...'
      });
      
      // Increment connection count for this node
      targetNode.connections++;
      
      socket.on('disconnect', () => {
        console.log(`📤 Client disconnected: ${socket.id}`);
        if (targetNode.connections > 0) {
          targetNode.connections--;
        }
      });
    });
  }

  private selectNode(): ChatNode | null {
    const healthyNodes = Array.from(this.chatNodes.values()).filter(n => n.healthy);
    
    if (healthyNodes.length === 0) {
      return null;
    }

    // Use least connections algorithm
    // healthyNodes.sort((a, b) => a.connections - b.connections);
    // return healthyNodes[0];

    // Use round-robin
    const node = healthyNodes[this.roundRobinIndex % healthyNodes.length];
    this.roundRobinIndex++;
    return node;
  }

  private async discoverNodes() {
    try {
      const response = await axios.get(
        `${CONSUL_URL}/v1/health/service/${SERVICE_NAME}?passing=true`,
        { timeout: 5000 }
      );
      
      const instances = response.data;
      const discoveredIds = new Set<string>();

      for (const entry of instances) {
        const service = entry.Service;
        const nodeId = service.ID;
        discoveredIds.add(nodeId);

        if (!this.chatNodes.has(nodeId)) {
          console.log(`✓ Discovered new node: ${nodeId} at ${service.Address}:${service.Port}`);
          this.chatNodes.set(nodeId, {
            id: nodeId,
            address: service.Address,
            port: service.Port,
            healthy: true,
            connections: 0
          });
        } else {
          // Update existing node
          const node = this.chatNodes.get(nodeId)!;
          node.address = service.Address;
          node.port = service.Port;
          node.healthy = true;
        }
      }

      // Remove nodes that no longer exist in Consul
      for (const [nodeId, node] of this.chatNodes.entries()) {
        if (!discoveredIds.has(nodeId)) {
          console.log(`✗ Node removed: ${nodeId}`);
          this.chatNodes.delete(nodeId);
        }
      }

    } catch (error: any) {
      console.error(`Failed to discover nodes: ${error.message}`);
    }
  }

  private async checkNodeHealth(node: ChatNode): Promise<boolean> {
    try {
      const response = await axios.get(
        `http://${node.address}:${node.port}/health`,
        { timeout: 2000 }
      );
      return response.status === 200;
    } catch (error) {
      return false;
    }
  }

  private async startHealthChecks() {
    // Initial discovery
    await this.discoverNodes();

    // Periodic discovery and health checks
    setInterval(async () => {
      await this.discoverNodes();
      
      // Health check all nodes
      for (const node of this.chatNodes.values()) {
        const healthy = await this.checkNodeHealth(node);
        if (node.healthy !== healthy) {
          console.log(`Node ${node.id} health changed: ${healthy ? 'healthy' : 'unhealthy'}`);
          node.healthy = healthy;
        }
      }
    }, HEALTH_CHECK_INTERVAL);

    console.log(`✓ Health checks started (interval: ${HEALTH_CHECK_INTERVAL}ms)`);
  }

  public start() {
    this.server.listen(PORT, () => {
      console.log('🚀 Load Balancer started');
      console.log(`   Port: ${PORT}`);
      console.log(`   Consul: ${CONSUL_URL}`);
      console.log(`   Service: ${SERVICE_NAME}`);
      console.log(`   Health: http://localhost:${PORT}/health`);
      console.log(`   Nodes: http://localhost:${PORT}/nodes`);
    });
  }
}

const lb = new LoadBalancer();
lb.start();
