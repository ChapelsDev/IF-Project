#!/bin/bash

set -e

echo "Installing SeaweedFS..."

curl -L https://github.com/seaweedfs/seaweedfs/releases/latest/download/linux_amd64.tar.gz \
  | tar -xz

sudo mv weed /usr/local/bin/

echo "SeaweedFS installed"
weed version
