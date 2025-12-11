import requests, random

CONSUL = "http://172.20.10.2:8500"

def get_instance():
    r = requests.get(f"{CONSUL}/v1/health/service/dummy",
                     params={"passing": "true"})
    r.raise_for_status()
    services = r.json()
    print("Available instances:", [f"{svc['Service']['Address']}:{svc['Service']['Port']}" for svc in services])
    svc = random.choice(services)
    return svc["Service"]["Address"], svc["Service"]["Port"]

for i in range(1000):
    addr, port = get_instance()
    print("   Selected instance:", addr, port)
    print(f"[{i}] -> calling {addr}:{port}")
    resp = requests.get(f"http://{addr}:{port}/msg")
    print("   response:", resp.json())
