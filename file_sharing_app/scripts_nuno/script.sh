#!/bin/bash

IP=$(hostname -I | awk '{print $1}')

MASTERS="192.168.100.50:9333,192.168.100.51:9333,192.168.100.52:9333,192.168.100.53:9333,192.168.100.54:9333,192.168.100.55:9333,192.168.100.56:9333,192.168.100.57:9333"

DATA_DIR="/var/seaweed"
VOL_DIR="$DATA_DIR/volumes"
FILER_DIR="$DATA_DIR/filer"

mkdir -p "$VOL_DIR" "$FILER_DIR"

echo "Starting master on $IP"
weed master \
  -ip="$IP" \
  -port=9333 \
  -peers="$MASTERS" \
  -defaultReplication=001 \
  > master.log 2>&1 &

sleep 3

echo "Starting volume on $IP"
weed volume \
  -ip="$IP" \
  -port=8080 \
  -master="$MASTERS" \
  -dir="$VOL_DIR" \
  > volume.log 2>&1 &

sleep 3

echo "Starting filer on $IP"
weed filer \
  -ip="$IP" \
  -port=8888 \
  -master="$MASTERS" \
  -dir="$FILER_DIR" \
  > filer.log 2>&1 &

echo "SeaweedFS node started on $IP"
