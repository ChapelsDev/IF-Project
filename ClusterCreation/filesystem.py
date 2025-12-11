import cluster_helper
import time
import sys
import uuid
import socket

# --- CONFIGURATION ---
SERVICE_NAME = "filesystem-service"
# Internal port for the Filer service
FILER_PORT = 8888 

MY_HOSTNAME = socket.gethostname()
SERVICE_ID = f"{SERVICE_NAME}-{MY_HOSTNAME}-{uuid.uuid4().hex[:4]}"

# --- DUMMY SEAWEEDFS CHECK ---
def check_seaweed_connection():
    # Simulate checking if the local SeaweedFS Filer is up
    print(f"💾 [SeaweedFS] Checking Filer on :{FILER_PORT}... OK (Simulated)")
    return True

# --- PROGRAM ---
if __name__ == "__main__":
    print(f"📂 Starting Filesystem Service: {SERVICE_ID}")
    
    if not check_seaweed_connection():
        sys.exit(1)

    try:
        # 1. Register ONLY the Filer Service
        cluster_helper.register_service(
            SERVICE_NAME, 
            SERVICE_ID, 
            "127.0.0.1", 
            FILER_PORT, 
            tags=["storage", "filer", "v1"]
        )
        print(f"✅ Service '{SERVICE_NAME}' registered successfully.")
        
        # 2. Keep Alive Loop
        while True:
            cluster_helper.keep_service_registered(SERVICE_NAME, SERVICE_ID, "127.0.0.1", FILER_PORT)
            time.sleep(10)

    except KeyboardInterrupt:
        print("\n🛑 Shutting down Filesystem Service...")
        cluster_helper.deregister_service(SERVICE_ID)
    except Exception as e:
        print(f"❌ Error: {e}")