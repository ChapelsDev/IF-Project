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
curl -X POST -F "file=@strawb.jpeg" http://localhost:3000/upload
```

### Download a File
```bash
curl -OJ http://localhost:3000/download/strawb.jpeg
```