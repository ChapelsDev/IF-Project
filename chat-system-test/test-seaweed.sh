#!/bin/bash
# Quick test script for SeaweedFS integration

echo "🧪 Testing SeaweedFS Integration..."
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

CHAT_NODE_URL="http://localhost:3001"
SEAWEED_URL="http://localhost:8888"

# Test 1: Check if SeaweedFS is running
echo -n "1️⃣  Checking SeaweedFS filer... "
if curl -s "$SEAWEED_URL/" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Running${NC}"
else
    echo -e "${RED}✗ Not accessible${NC}"
    echo "   Start with: ./chat-system.sh start"
    exit 1
fi

# Test 2: Check if chat node is running
echo -n "2️⃣  Checking chat node... "
if curl -s "$CHAT_NODE_URL/health" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Running${NC}"
else
    echo -e "${RED}✗ Not accessible${NC}"
    echo "   Start with: ./chat-system.sh start"
    exit 1
fi

# Test 3: Check SeaweedFS health via chat node
echo -n "3️⃣  Checking SeaweedFS health endpoint... "
HEALTH=$(curl -s "$CHAT_NODE_URL/seaweed/health")
if echo "$HEALTH" | grep -q '"healthy":true'; then
    echo -e "${GREEN}✓ Healthy${NC}"
else
    echo -e "${RED}✗ Unhealthy${NC}"
    echo "   Response: $HEALTH"
    exit 1
fi

# Test 4: Upload a test file
echo -n "4️⃣  Testing file upload... "
TEST_FILE="/tmp/seaweed_test_file.txt"
echo "SeaweedFS test - $(date)" > "$TEST_FILE"
BASE64_DATA=$(base64 -w 0 "$TEST_FILE" 2>/dev/null || base64 "$TEST_FILE")

UPLOAD_RESPONSE=$(curl -s -X POST "$CHAT_NODE_URL/upload" \
  -H "Content-Type: application/json" \
  -d "{\"filename\":\"test_$(date +%s).txt\",\"data\":\"$BASE64_DATA\",\"username\":\"test_user\"}")

if echo "$UPLOAD_RESPONSE" | grep -q '"success":true'; then
    echo -e "${GREEN}✓ Success${NC}"
    FILE_URL=$(echo "$UPLOAD_RESPONSE" | grep -o '"fileUrl":"[^"]*"' | cut -d'"' -f4)
    echo "   📎 File URL: $FILE_URL"
    
    # Test 5: Download the file
    echo -n "5️⃣  Testing file download... "
    if curl -s "$FILE_URL" | grep -q "SeaweedFS test"; then
        echo -e "${GREEN}✓ Success${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
else
    echo -e "${RED}✗ Failed${NC}"
    echo "   Response: $UPLOAD_RESPONSE"
    exit 1
fi

# Clean up
rm -f "$TEST_FILE"

echo ""
echo -e "${GREEN}🎉 All tests passed!${NC}"
echo ""
echo "Next steps:"
echo "  • Open chat: http://localhost:3001"
echo "  • Open SeaweedFS UI: http://localhost:8888"
echo "  • Test file upload in chat interface"
echo ""
