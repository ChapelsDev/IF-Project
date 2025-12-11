import cluster_helper
import time
import sys
import uuid
import socket

# --- CONFIGURATION ---
SERVICE_NAME = "chat-service"
# Generates a random port between 5000 and 6000 so you can run multiple on the same node if you want
MY_PORT = 5000 
MY_HOSTNAME = socket.gethostname()
# Unique ID
SERVICE_ID = f"{SERVICE_NAME}-{MY_HOSTNAME}-{uuid.uuid4().hex[:4]}"

# --- CALLBACKS ---
def on_service_change(instances):
    ips = [f"{i['Node']['Address']}:{i['Service']['Port']}" for i in instances]
    print(f"\n⚡ [WATCH] Chat Topology has changed! {len(ips)} active nodes.")
    print(f"   Neighbors: {ips}")

def on_infra_change(node_name, status):
    if status == "critical":
        print(f"\nServer '{node_name}' DOWN (Crash/Network)!")
    else:
        print(f"\nServer '{node_name}' RECOVERED!")

# --- PROGRAM ---
if __name__ == "__main__":
    print(f"🚀 Starting test application: {SERVICE_ID}")
    try:
        # 1. Registration (Uses TTL by default in adjusted library)
        cluster_helper.register_service(SERVICE_NAME, SERVICE_ID, "127.0.0.1", MY_PORT, tags=["v1"])
        
        # 2. Self-Healing
        cluster_helper.keep_service_registered(SERVICE_NAME, SERVICE_ID, "127.0.0.1", MY_PORT)

        # 3. Watch Application
        cluster_helper.watch_service_changes(SERVICE_NAME, on_service_change)

        # 4. Watch Infrastructure (Hardware)
        cluster_helper.watch_nodes(on_infra_change)

        print("✅ System running. Press Ctrl+C to exit.")
        
        while True:
            time.sleep(1)

    except KeyboardInterrupt:
        print("\n🛑 Shutting down...")
        cluster_helper.deregister_service(SERVICE_ID)