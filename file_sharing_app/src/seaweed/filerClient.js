const axios = require("axios");

async function uploadToFiler(filerIp, filePath, stream) {
    const url = `${filerIp}/${filePath}`;
    const res = await axios.put(url, stream, {
        headers: { "Content-Type": "application/octet-stream" }
    });
    return res.data;
}

async function downloadFromFiler(filerIp, filePath) {
    const url = `${filerIp}/${filePath}`;
    const res = await axios.get(url, { responseType: "stream" });
    return res.data;
}

module.exports = { uploadToFiler, downloadFromFiler };
