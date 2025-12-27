# Local Seaweed Testing

## Installation

### Install Seaweed
```bash
wget https://github.com/seaweedfs/seaweedfs/releases/tag/4.01/linux_amd64_full.tar.gz
tar -xzf linux_amd64_full.tar.gz
sudo mv weed /usr/local/bin/
```

### Install Node Dependencies
Navigate to `/file_sharing_app` and run:
```bash
npm install
```

## Running Services

### 1. Start Master
```bash
weed master -port=9333
```

### 2. Start Volumes (only create dir if they don' exist)
```bash
mkdir -p /tmp/vol1
weed volume -port=8080 -mserver=localhost:9333 -dir=/tmp/vol1

mkdir -p /tmp/vol2
weed volume -port=8081 -mserver=localhost:9333 -dir=/tmp/vol2
```

### 3. Start Filer
```bash
weed filer -port=8888
```

### 4. Start Filer Client
Navigate to `/file_sharing_app/src` and run:
```bash
node server.js
```

## Testing

### Upload a File
```bash
# curl -X POST -F "file=@strawb.jpeg" http://localhost:3000/upload
    curl -X POST -F "file=@flower.jpg" "http://localhost:3000/upload?filerIp=http://localhost:8889"
```

### Download a File
```bash
# curl -OJf http://localhost:3000/download/strawb.jpeg

curl -OJf -X GET "http://localhost:3000/download/flower.jpg?filerIp=http://localhost:8888"
```

dockercompose tests:    
3 filers + 3 etcd nodes
3 masters
3 vols

quorum of 3 on both master raft and etcd raft (need at least 3 entities in both clusters for them to work, e.g. for masters needs to exist 3 at all times, else raft election doesnt work and write op dont work)

quorum = Nnodes / 2 + 1
(3 nodes -> 3
 5 nodes -> 3
 8 nodes -> 5)

write operations require quorum
read operations dont require quorum

### Consul Register/Deregister (Docker Testing)

#### Register Services with Consul

**master**
```bash
curl -X PUT \
    -H "Content-Type: application/json" \
    -d '{
        "Name": "seaweed-master1",
        "Tags": ["master"],
        "Address": "192.168.10.116",
        "Port": 9331,
        "Check": {
            "HTTP": "http://192.168.10.116:9331/cluster/status",
            "Interval": "10s"
        }
    }' \
    http://localhost:8500/v1/agent/service/register
```
<details>
<summary>PowerShell (Invoke-RestMethod)</summary>

```powershell
Invoke-RestMethod -Method Put `
    -Uri "http://localhost:8500/v1/agent/service/register" `
    -ContentType "application/json" `
    -Body '{
        "Name": "seaweed-master1",
        "Tags": ["master"],
        "Address": "192.168.10.116",
        "Port": 9331,
        "Check": {
            "HTTP": "http://192.168.10.116:9331/cluster/status",
            "Interval": "10s"
        }
    }'
```
</details>

**volume**
```bash
curl -X PUT \
    -H "Content-Type: application/json" \
    -d '{
        "Name": "seaweed-volume1",
        "Tags": ["volume"],
        "Address": "192.168.10.116",
        "Port": 8080,
        "Check": {
            "HTTP": "http://192.168.10.116:8080/status",
            "Interval": "10s"
        }
    }' \
    http://localhost:8500/v1/agent/service/register
```
<details>
<summary>PowerShell (Invoke-RestMethod)</summary>

```powershell
Invoke-RestMethod -Method Put `
    -Uri "http://localhost:8500/v1/agent/service/register" `
    -ContentType "application/json" `
    -Body '{
        "Name": "seaweed-volume1",
        "Tags": ["volume"],
        "Address": "192.168.10.116",
        "Port": 8080,
        "Check": {
            "HTTP": "http://192.168.10.116:8080/status",
            "Interval": "10s"
        }
    }'
```
</details>

**filer**
```bash
curl -X PUT \
    -H "Content-Type: application/json" \
    -d '{
        "Name": "seaweed-filer1",
        "Tags": ["filer"],
        "Address": "192.168.10.116",
        "Port": 8888,
        "Check": {
            "HTTP": "http://192.168.10.116:8888/",
            "Interval": "10s"
        }
    }' \
    http://localhost:8500/v1/agent/service/register
```
<details>
<summary>PowerShell (Invoke-RestMethod)</summary>

```powershell
Invoke-RestMethod -Method Put `
    -Uri "http://localhost:8500/v1/agent/service/register" `
    -ContentType "application/json" `
    -Body '{
        "Name": "seaweed-filer1",
        "Tags": ["filer"],
        "Address": "192.168.10.116",
        "Port": 8888,
        "Check": {
            "HTTP": "http://192.168.10.116:8888/",
            "Interval": "10s"
        }
    }'
```
</details>