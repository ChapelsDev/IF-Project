#!/bin/bash
# filepath: /mnt/c/un/cluster/fs/IF-Project/file_sharing_app/scripts_nuno/install.sh

# Install SeaweedFS
if ! command -v weed &> /dev/null; then
  echo "Installing SeaweedFS..."
  wget https://github.com/seaweedfs/seaweedfs/releases/download/3.47/weed -O /usr/local/bin/weed
  chmod +x /usr/local/bin/weed
else
  echo "SeaweedFS is already installed."
fi

# Install etcd (for filer metadata)
if ! command -v etcd &> /dev/null; then
  echo "Installing etcd..."
  wget https://github.com/etcd-io/etcd/releases/download/v3.5.9/etcd-v3.5.9-linux-amd64.tar.gz
  tar -xvf etcd-v3.5.9-linux-amd64.tar.gz
  mv etcd-v3.5.9-linux-amd64/etcd* /usr/local/bin/
  rm -rf etcd-v3.5.9-linux-amd64*
else
  echo "etcd is already installed."
fi

echo "Installation complete."