IF Project

Local Seaweed testing:
install Seaweed:
  wget https://github.com/seaweedfs/seaweedfs/releases/tag/4.01/linux_amd64_full.tar.gz
  tar -xzf linux_amd64_full.tar.gz
  sudo mv weed /usr/local/bin/

install node dep: (/file_sharing_app)
  npm install

  1 master:
    weed master -port=9333
  
  2 volumes:
    mkdir -p /tmp/vol1
    weed volume -port=8080 -mserver=localhost:9333 -dir=/tmp/vol1
    mkdir -p /tmp/vol2
    weed volume -port=8081 -mserver=localhost:9333  -dir=/tmp/vol2
  
  1 filer:
    weed filer -port=8888
  
  filer client: (/file_Sharing_app/src)
    node server.js

test client with:
  upload:
    curl -X POST -F "file=@strawb.jpeg" http://localhost:3000/upload
  download:
    curl -OJ http://localhost:3000/download/strawb.jpeg
