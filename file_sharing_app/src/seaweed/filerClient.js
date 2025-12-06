const axios = require("axios");

const FILER = "http://localhost:8888";  // later: FILER = http://<cluster-filer-service>

async function uploadToFiler(filePath, stream) {
    const url = `${FILER}/${filePath}`;
    const res = await axios.put(url, stream, {
        headers: { "Content-Type": "application/octet-stream" }
    });
    return res.data;
}

async function downloadFromFiler(filePath) {
    const url = `${FILER}/${filePath}`;
    const res = await axios.get(url, { responseType: "stream" });
    return res.data;
}

module.exports = { uploadToFiler, downloadFromFiler };
