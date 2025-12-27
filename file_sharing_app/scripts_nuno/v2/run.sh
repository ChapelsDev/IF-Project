#!/bin/bash
# filepath: /mnt/c/un/cluster/fs/IF-Project/file_sharing_app/scripts_nuno/run.sh

# Load configuration from external file
CONFIG_FILE="$(dirname "$0")/config.env"
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
else
  echo "Configuration file not found: $CONFIG_FILE"
  exit 1
fi

ROLE=$1  # Role: master, volume, filer, etcd
ACTION=$2  # Action: start, stop
IP=$(hostname -I | awk '{print $1}')

# Function to register service with Consul
register_service() {
  local name=$1
  local port=$2
  local health_path=$3
  local tags=$4

  local unique_name="${name}-$(hostname)"

  echo "Registering $name with Consul..."
  curl -X PUT -H "Content-Type: application/json" -d "{
    \"Name\": \"$unique_name\",
    \"Tags\": [$tags],
    \"Address\": \"$IP\",
    \"Port\": $port,
    \"Check\": {
      \"HTTP\": \"http://$IP:$port$health_path\",
      \"Interval\": \"10s\",
      \"DeregisterCriticalServiceAfter\": \"1m\"
    }
  }" http://$IP:8500/v1/agent/service/register
}

# Function to deregister service from Consul
deregister_service() {
  local name=$1

  local unique_name="${name}-$(hostname)"

  echo "Deregistering $unique_name from Consul..."
  curl -X PUT http://$IP:8500/v1/agent/service/deregister/$unique_name
}

# Start or stop services based on the action
case $ACTION in
  start)
    mkdir -p "$VOL_DIR" "$FILER_DIR" "$ETCD_DIR"

    case $ROLE in
      master)
        echo "Starting SeaweedFS Master on $IP..."
        weed master \
          -ip="$IP" \
          -port=9333 \
          -peers="$MASTERS" \
          -defaultReplication=001 \
          > master.log 2>&1 &
        register_service "seaweed-master" 9333 "/cluster/status" "\"master\""
        ;;
      volume)
        echo "Starting SeaweedFS Volume on $IP..."
        weed volume \
          -ip="$IP" \
          -port=8080 \
          -master="$MASTERS" \
          -dir="$VOL_DIR" \
          > volume.log 2>&1 &
        register_service "seaweed-volume" 8080 "/status" "\"volume\""
        ;;
      filer)
        echo "Starting SeaweedFS Filer on $IP..."
        weed filer \
          -ip="$IP" \
          -port=8888 \
          -master="$MASTERS" \
          -etcd="http://$ETCD_CLUSTER" \
          -dir="$FILER_DIR" \
          > filer.log 2>&1 &
        register_service "seaweed-filer" 8888 "/" "\"filer\""
        ;;
      etcd)
        echo "Starting etcd on $IP..."
        etcd \
          --name "$(hostname)" \
          --data-dir="$ETCD_DIR" \
          --listen-client-urls "http://$IP:2379" \
          --advertise-client-urls "http://$IP:2379" \
          --listen-peer-urls "http://$IP:2380" \
          --initial-advertise-peer-urls "http://$IP:2380" \
          --initial-cluster "$INITIAL_CLUSTER" \
          --initial-cluster-token "etcd-cluster" \
          --initial-cluster-state new \
          > etcd.log 2>&1 &
        register_service "etcd" 2379 "/health" "\"etcd\""
        ;;
      *)
        echo "Invalid role. Use 'master', 'volume', 'filer', or 'etcd'."
        exit 1
        ;;
    esac
    ;;
  stop)
    case $ROLE in
      master)
        echo "Stopping SeaweedFS Master..."
        pkill -f "weed master"
        deregister_service "seaweed-master"
        ;;
      volume)
        echo "Stopping SeaweedFS Volume..."
        pkill -f "weed volume"
        deregister_service "seaweed-volume"
        ;;
      filer)
        echo "Stopping SeaweedFS Filer..."
        pkill -f "weed filer"
        deregister_service "seaweed-filer"
        ;;
      etcd)
        echo "Stopping etcd..."
        pkill -f "etcd"
        deregister_service "etcd"
        ;;
      *)
        echo "Invalid role. Use 'master', 'volume', 'filer', or 'etcd'."
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Invalid action. Use 'start' or 'stop'."
    exit 1
    ;;
esac

echo "$ROLE $ACTION completed on $IP."