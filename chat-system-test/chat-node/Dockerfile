FROM node:18-alpine

# Install Python and dependencies for cluster integration
RUN apk add --no-cache python3 py3-pip curl

WORKDIR /app

COPY package*.json ./
RUN npm install

COPY tsconfig.json ./
COPY src ./src

RUN npm run build

# Install Python requests library for cluster bridge
RUN pip3 install --no-cache-dir requests

EXPOSE 3000 3001 3002 3003

CMD ["npm", "start"]
