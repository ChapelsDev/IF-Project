# SeaweedFS Integration - Quick Start Guide

## Overview
SeaweedFS is now integrated with the chat system for distributed file storage. Files uploaded through the chat are stored in SeaweedFS and can be shared in chat rooms.

## Features
- ✅ File upload/download via HTTP endpoints
- ✅ File sharing in chat rooms via Socket.IO
- ✅ File attachment button in message input
- ✅ Test component for quick SeaweedFS testing
- ✅ Automatic file organization by username and date
- ✅ Support for images, documents, archives, and more

## Quick Start with Docker Compose

### 1. Start Everything (Easiest Method)
```bash
cd /home/sopas/IF-Project/chat-system-test
./chat-system.sh start
```

This starts:
- ✅ Consul cluster (service discovery)
- ✅ Redis cluster (message storage)
- ✅ NATS cluster (pub/sub messaging)
- ✅ SeaweedFS (master, volume, filer)
- ✅ Chat nodes (3 instances)

### 2. Access the Services

**Chat Application:**
- Build frontend: `cd client-react && npm run build && cd ..`
- Open: `http://localhost:3001` (or 3002, 3003)

**SeaweedFS Filer:**
- Web UI: `http://localhost:8888`
- Upload endpoint: `http://localhost:3001/upload`

**Test Component:**
- Visible in top-right corner of chat interface
- Upload any file to test SeaweedFS

### 3. Test File Upload

**Via Test Component (Easiest):**
1. Open chat at `http://localhost:3001`
2. See "🧪 SeaweedFS Test" widget in top-right
3. Select a file and click "📤 Upload to SeaweedFS"
4. Success! File URL is displayed

**Via Chat Message:**
1. Join a chat room
2. Click the 📎 (paperclip) button next to Send
3. Select a file
4. File uploads and appears as a message with download link

**Via curl:**
```bash
# Create a test file
echo "Hello SeaweedFS!" > test.txt

# Convert to base64
BASE64_DATA=$(base64 -w 0 test.txt)

# Upload
curl -X POST http://localhost:3001/upload \
  -H "Content-Type: application/json" \
  -d "{\"filename\":\"test.txt\",\"data\":\"$BASE64_DATA\",\"username\":\"testuser\"}"
```

### 4. Check SeaweedFS Health
```bash
curl http://localhost:3001/seaweed/health
# Should return: {"healthy":true}
```

## Manual SeaweedFS Setup (Without Docker)

If you want to run SeaweedFS manually for testing:

### Install SeaweedFS
```bash
# Download latest release
wget https://github.com/seaweedfs/seaweedfs/releases/download/3.60/linux_amd64_full.tar.gz
tar -xzf linux_amd64_full.tar.gz
sudo mv weed /usr/local/bin/

# Verify installation
weed version
```

### Start Services

**Terminal 1 - Master:**
```bash
weed master -port=9333
```

**Terminal 2 - Volume:**
```bash
mkdir -p /tmp/vol1
weed volume -port=8080 -mserver=localhost:9333 -dir=/tmp/vol1
```

**Terminal 3 - Filer:**
```bash
weed filer -port=8888 -master=localhost:9333
```

**Terminal 4 - Chat Node:**
```bash
cd /home/sopas/IF-Project/chat-system-test/chat-node
export FILESTORE_URL=http://localhost:8888
npm run build
npm start
```

## Environment Variables

The chat nodes use these environment variables:

```bash
FILESTORE_URL=http://seaweed-filer:8888  # Default for docker-compose
FILESTORE_URL=http://localhost:8888      # For manual setup
```

## File Organization

Files are automatically organized in SeaweedFS:
```
/chat-files/
  ├── username1/
  │   ├── 2026-01-12/
  │   │   ├── 1736704800000_image.jpg
  │   │   └── 1736704900000_document.pdf
  │   └── 2026-01-13/
  │       └── 1736791200000_video.mp4
  └── username2/
      └── 2026-01-12/
          └── 1736705000000_file.zip
```

## API Endpoints

### Upload File
```bash
POST http://localhost:3001/upload
Content-Type: application/json

{
  "filename": "example.jpg",
  "data": "base64_encoded_file_data",
  "username": "john_doe"
}

Response:
{
  "success": true,
  "fileUrl": "http://localhost:8888/chat-files/john_doe/2026-01-12/1736704800000_example.jpg",
  "fileName": "1736704800000_example.jpg"
}
```

### Download File
```bash
GET http://localhost:3001/download/chat-files/username/2026-01-12/filename.jpg
```

### Health Check
```bash
GET http://localhost:3001/seaweed/health
```

## Socket.IO Events

### Upload File via Socket
```javascript
socket.emit("uploadFile", {
  filename: "example.jpg",
  data: base64Data,
  roomId: "general"  // Optional: share in room
});

// Listen for success
socket.on("uploadSuccess", (data) => {
  console.log("Uploaded:", data.fileUrl);
});

// Listen for errors
socket.on("uploadError", (error) => {
  console.error("Upload failed:", error.error);
});

// Listen for file messages in room
socket.on("fileMessage", (msg) => {
  console.log("File shared:", msg.fileUrl);
});
```

## Troubleshooting

### SeaweedFS not responding
```bash
# Check if services are running
curl http://localhost:8888/
curl http://localhost:9333/cluster/status

# Check Docker containers
podman ps | grep seaweed
```

### Files not uploading
```bash
# Check chat node logs
podman logs chat-node-1

# Check environment variable
podman exec chat-node-1 env | grep FILESTORE_URL
```

### Upload fails with "ECONNREFUSED"
- Ensure SeaweedFS filer is running on port 8888
- Check `FILESTORE_URL` environment variable
- Verify network connectivity

## Architecture

```
┌─────────────┐
│   Client    │
│  (Browser)  │
└──────┬──────┘
       │ WebSocket + HTTP
       ▼
┌─────────────┐     ┌──────────────┐
│  Chat Node  ├────►│  SeaweedFS   │
│   (3001)    │HTTP │   Filer      │
└─────────────┘     │   (8888)     │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │  SeaweedFS   │
                    │   Master     │
                    │   (9333)     │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │  SeaweedFS   │
                    │   Volumes    │
                    │   (8080)     │
                    └──────────────┘
```

## File Limits

- Max file size: **10MB** (configurable in seaweed.ts)
- Upload timeout: **30 seconds**
- Supported formats: All file types

## Next Steps

1. ✅ Start the system: `./chat-system.sh start`
2. ✅ Open browser: `http://localhost:3001`
3. ✅ Test file upload using the test widget
4. ✅ Share files in chat rooms
5. ✅ Check SeaweedFS UI: `http://localhost:8888`

## Additional Resources

- [SeaweedFS Documentation](https://github.com/seaweedfs/seaweedfs/wiki)
- [Chat System README](./README.md)
- Main Script: [`./chat-system.sh`](./chat-system.sh)
- SeaweedFS Module: [`chat-node/src/seaweed.ts`](chat-node/src/seaweed.ts)

---

**Happy file sharing! 📎🚀**
