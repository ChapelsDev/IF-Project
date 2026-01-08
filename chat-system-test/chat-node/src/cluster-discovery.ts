import axios from 'axios';

interface ServiceInstance {
  id: string;
  address: string;
  port: number;
  tags: string[];
}

interface ServiceCheck {
  HTTP: string;
  Interval: string;
  Timeout: string;
  DeregisterCriticalServiceAfter: string;
}

interface ServiceRegistration {
  ID: string;
  Name: string;
  Address: string;
  Port: number;
  Tags: string[];
  Check: ServiceCheck;
}

export class ClusterDiscovery {
  private consulUrl: string;
  private serviceName: string;
  private serviceId: string;
  private myAddress: string;
  private myPort: number;
  private healthCheckInterval: NodeJS.Timeout | null = null;

  constructor(
    consulUrl: string,
    serviceName: string,
    serviceId: string,
    myAddress: string,
    myPort: number
  ) {
    this.consulUrl = consulUrl;
    this.serviceName = serviceName;
    this.serviceId = serviceId;
    this.myAddress = myAddress;
    this.myPort = myPort;
  }

  async register(tags: string[] = []): Promise<void> {
    const registration: ServiceRegistration = {
      ID: this.serviceId,
      Name: this.serviceName,
      Address: this.myAddress,
      Port: this.myPort,
      Tags: tags,
      Check: {
        HTTP: `http://${this.myAddress}:${this.myPort}/health`,
        Interval: '10s',
        Timeout: '2s',
        DeregisterCriticalServiceAfter: '30s'
      }
    };

    try {
      console.log(`📝 Registering ${this.serviceId} with Consul at ${this.consulUrl}`);
      console.log(`   Service: ${this.serviceName}, Address: ${this.myAddress}:${this.myPort}`);
      
      await axios.put(
        `${this.consulUrl}/v1/agent/service/register`,
        registration,
        { timeout: 10000 }
      );
      console.log(`✓ Registered ${this.serviceId} with cluster at ${this.myAddress}:${this.myPort}`);
      
      // Start health check updates
      this.startHealthCheck();
    } catch (error: any) {
      console.error(`❌ Failed to register ${this.serviceId} with cluster:`, error.message);
      if (error.response) {
        console.error(`   Response status: ${error.response.status}`);
        console.error(`   Response data:`, error.response.data);
      }
      throw error;
    }
  }

  async deregister(): Promise<void> {
    if (this.healthCheckInterval) {
      clearInterval(this.healthCheckInterval);
      this.healthCheckInterval = null;
    }

    try {
      await axios.put(
        `${this.consulUrl}/v1/agent/service/deregister/${this.serviceId}`
      );
      console.log(`✓ Deregistered ${this.serviceId} from cluster`);
    } catch (error: any) {
      console.error('Failed to deregister from cluster:', error.message);
    }
  }

  async discoverService(serviceName: string): Promise<ServiceInstance[]> {
    try {
      const response = await axios.get(
        `${this.consulUrl}/v1/health/service/${serviceName}?passing=true`
      );

      return response.data.map((entry: any) => ({
        id: entry.Service.ID,
        address: entry.Service.Address,
        port: entry.Service.Port,
        tags: entry.Service.Tags || []
      }));
    } catch (error: any) {
      console.error(`Failed to discover ${serviceName}:`, error.message);
      return [];
    }
  }

  async discoverPeers(): Promise<ServiceInstance[]> {
    const allInstances = await this.discoverService(this.serviceName);
    // Filter out self
    return allInstances.filter(instance => instance.id !== this.serviceId);
  }

  async discoverInfrastructure(): Promise<{
    redis?: ServiceInstance;
    nats?: ServiceInstance;
  }> {
    const [redisInstances, natsInstances] = await Promise.all([
      this.discoverService('redis-service'),
      this.discoverService('nats-service')
    ]);

    return {
      redis: redisInstances[0],
      nats: natsInstances[0]
    };
  }

  private startHealthCheck(): void {
    // Periodically check if we're still registered
    this.healthCheckInterval = setInterval(async () => {
      try {
        const response = await axios.get(
          `${this.consulUrl}/v1/agent/service/${this.serviceId}`
        );
        if (!response.data) {
          console.warn('Service not found in Consul, re-registering...');
          await this.register();
        }
      } catch (error) {
        // Ignore errors - Consul will mark us as unhealthy if we don't respond
      }
    }, 30000); // Check every 30 seconds
  }

  // Watch for service changes
  async watchService(
    serviceName: string,
    onChange: (instances: ServiceInstance[]) => void
  ): Promise<() => void> {
    let lastIndex = 0;
    let watching = true;

    const watch = async () => {
      while (watching) {
        try {
          const response = await axios.get(
            `${this.consulUrl}/v1/health/service/${serviceName}?passing=true&index=${lastIndex}&wait=30s`,
            { timeout: 35000 }
          );

          if (response.headers['x-consul-index']) {
            const newIndex = parseInt(response.headers['x-consul-index']);
            if (newIndex !== lastIndex) {
              lastIndex = newIndex;
              const instances = response.data.map((entry: any) => ({
                id: entry.Service.ID,
                address: entry.Service.Address,
                port: entry.Service.Port,
                tags: entry.Service.Tags || []
              }));
              onChange(instances);
            }
          }
        } catch (error) {
          // Wait before retrying
          await new Promise(resolve => setTimeout(resolve, 5000));
        }
      }
    };

    watch();

    return () => {
      watching = false;
    };
  }

  async isHealthy(): Promise<boolean> {
    try {
      // Check if we can reach Consul
      await axios.get(`${this.consulUrl}/v1/agent/self`, { timeout: 2000 });
      return true;
    } catch (error) {
      return false;
    }
  }
}
