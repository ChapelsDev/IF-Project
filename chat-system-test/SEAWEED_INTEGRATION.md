# SeaweedFS Integration with Chat System

This chat system now includes **SeaweedFS** for distributed file storage, allowing users to upload and share files in chat rooms.

## 🚀 Quick Start

### Option 1: Using Docker Compose (Recommended)

```bash
cd chat-system-test
podman-compose up -d
# or
docker-compose up -d
```

This will start:
- 3 Consul servers (service discovery)
- 6 Redis nodes (3 masters + 3 replicas)
- 3 NATS servers (message bus)
- **SeaweedFS Master** (port 9333)
- **SeaweedFS Volume** (port 8080)
- **SeaweedFS Filer** (port 8888)
- 3 Chat nodes (ports 3001, 3002, 3003)

### Option 2: Using chat-system.sh Script

```bash
cd chat-system-test
./chat-system.sh start
```

**Note:** If using `chat-system.sh`, SeaweedFS is NOT automatically started. You'll need to start it separately (see Manual Setup below).

### Access the Application

- **Chat Frontend:** Configure `VITE_CHAT_URL` environment variable to point to your chat nodes
- **Chat API:** Ports 3001, 3002, or 3003 on your host IP
- **SeaweedFS Filer:** Port 8888 on your host IP

Example:
```bash
# Set in client-react/.env
VITE_CHAT_URL=http://192.168.100.51:3001
```

## 📁 Features

### 1. File Upload Test Widget
A test widget appears in the top-right corner of the chat interface:
- Select any file
- Click "Upload to SeaweedFS"
- Get a direct download URL

### 2. File Sharing in Chat
- Click the 📎 button next to the message input
- Select a file to upload
- File is automatically shared in the current chat room
- Other users see a download link

### 3. HTTP API Endpoints

**Upload File:**
```bash
# Replace with your actual IP address
curl -X POST http://192.168.100.51:3001/upload \
  -H "Content-Type: application/json" \
  -d '{
    "filename": "test.txt",
    "data": "SGVsbG8gV29ybGQh",
    "username": "testuser"
  }'
```

**Download File:**
```bash
# Replace with your actual IP address
curl http://192.168.100.51:3001/download/chat-files/testuser/2026-01-12/123456789_test.txt -o downloaded.txt
```

**Check SeaweedFS Health:**
```bash
# Replace with your actual IP address
curl http://192.168.100.51:3001/seaweed/health
```

## 🛠️ Manual SeaweedFS Setup (for chat-system.sh users)

If you're using `./chat-system.sh` instead of docker-compose, start SeaweedFS manually:

### 1. Install SeaweedFS
```bash
# Download (adjust version as needed)
wget https://github.com/seaweedfs/seaweedfs/releases/download/3.61/linux_amd64_full.tar.gz
tar -xzf linux_amd64_full.tar.gz
sudo mv weed /usr/local/bin/
```

### 2. Start SeaweedFS Services

**Terminal 1 - Master:**
```bash
weed master -port=9333
```

**Terminal 2 - Volume:**
```bash
mkdir -p /tmp/seaweed-vol1
weed volume -port=8080 -mserver=localhost:9333 -dir=/tmp/seaweed-vol1
```

**Terminal 3 - Filer:**
```bash
weed filer -port=8888 -master=localhost:9333
```

### 3. Configure Chat Nodes
Set the environment variable for chat nodes:
```bash
export FILESTORE_URL=http://localhost:8888
```

Then start the chat system:
```bash
./chat-system.sh start
```

## 🔧 Architecture

### File Upload Flow
1. User selects file in browser
2. File is read as base64 in React frontend
3. Sent to chat-node via HTTP POST or Socket.IO
4. Chat-node uploads to SeaweedFS Filer
5. Filer assigns file to Volume and returns URL
6. URL is shared in chat room (if applicable)

### File Storage Structure
```
/chat-files/
  ├── username1/
  │   ├── 2026-01-12/
  │   │   ├── 1736698800000_image.png
  │   │   └── 1736699000000_document.pdf
  │   └── 2026-01-13/
  │       └── 1736785200000_video.mp4
  └── username2/
      └── 2026-01-12/
          └── 1736699500000_file.zip
```

Files are organized by:
- Username (prevents conflicts)
- Date (YYYY-MM-DD)
- Timestamp prefix (unique naming)

## 🧪 Testing

### Test File Upload (HTTP)
```bash
# Create test file
echo "Hello SeaweedFS!" > test.txt

# Convert to base64
BASE64_DATA=$(base64 -w 0 test.txt)

# Upload (replace with your actual IP)
curl -X POST http://192.168.100.51:3001/upload \
  -H "Content-Type: application/json" \
  -d "{\"filename\":\"test.txt\",\"data\":\"$BASE64_DATA\",\"username\":\"testuser\"}"
```

### Test File Upload (Socket.IO)
Use the browser console:
```javascript
// In chat page console
const file = document.querySelector('input[type="file"]').files[0];
const reader = new FileReader();
reader.onload = () => {
  const base64 = reader.result.split(',')[1];
  socket.emit('uploadFile', {
    filename: file.name,
    data: base64,
    roomId: 'general'
  });
};
reader.readAsDataURL(file);
```

## 📊 Configuration

### Environment Variables

**Chat Node (backend):**
```bash
FILESTORE_URL=http://localhost:8888  # SeaweedFS Filer URL (use localhost in container, or actual IP)
PORT=3001                             # Chat node port
NODE_ID=1                             # Node identifier
```

**Frontend (.env file in client-react/):**
```bash
VITE_CHAT_URL=http://192.168.100.51:3001  # Chat node URL (use your actual IP)
```

The frontend automatically uses the chat node's URL for file operations.

### Docker Compose Environment
In `docker-compose.yml`, each chat node has:
```yaml
environment:
  - FILESTORE_URL=http://seaweed-filer:8888
```

## 🔒 Security Considerations

1. **File Size Limits:** Currently set to 10MB (configurable in gateway.ts)
2. **File Type Validation:** Currently accepts all file types (add validation as needed)
3. **Username-based Storage:** Files are organized by username to prevent conflicts
4. **No Authentication:** Add authentication/authorization as needed for production

## 📝 File Format Support

The system handles all file types, including:
- Images: JPG, PNG, GIF, WebP, SVG
- Documents: PDF, DOC, DOCX, XLS, XLSX, TXT
- Archives: ZIP, RAR, 7Z
- Media: MP3, MP4, AVI, MOV
- Code: JS, JSON, HTML, CSS

MIME types are automatically detected and set correctly.

## 🐛 Troubleshooting

### "Upload failed: connect ECONNREFUSED"
SeaweedFS is not running. Start the services:
```bash
# Check if SeaweedFS containers are running (docker-compose)
podman ps | grep seaweed

# Or check manually started processes
# Replace with your actual IP
curl http://192.168.100.51:8888/
```

### "File not found" when downloading
The file path may be incorrect. Files are stored at:
```
http://localhost:8888/chat-files/{username}/{date}/{timestamp}_{filename}
```

### Chat nodes can't connect to SeaweedFS
Check the `FILESTORE_URL` environment variable:
```bash
# In chat node container
echo $FILESTORE_URL

# Should be: http://seaweed-filer:8888 (in docker)
# Or: http://localhost:8888 (standalone)
```

## 📚 Additional Resources

- [SeaweedFS Documentation](https://github.com/seaweedfs/seaweedfs/wiki)
- [SeaweedFS API Reference](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Server-API)
- Chat System README: [README.md](./README.md)

## 🎯 Next Steps

1. **Add file type restrictions** - Limit uploads to specific file types
2. **Implement file preview** - Show image thumbnails in chat
3. **Add progress indicators** - Show upload/download progress
4. **Implement file expiration** - Auto-delete old files
5. **Add file search** - Search through uploaded files
6. **Quota management** - Limit storage per user
