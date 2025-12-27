const multer = require("multer");
const { uploadToFiler } = require("../seaweed/filerClient");
const crypto = require("crypto");
const path = require("path");
const fileMap = require("../fileMap");

const upload = multer();

module.exports = function(app) {
    app.post("/upload", upload.single("file"), async (req, res) => {
        try {
            const filerIp = req.query.filerIp; // Get FILER IP from query parameter
            if (!filerIp) {
                return res.status(400).json({ error: "FILER IP is required" });
            }

            const originalName = req.file.originalname;
            const extension = path.extname(originalName);
            const uuid = crypto.randomUUID();
            const storedName = `${uuid}${extension}`;

            await uploadToFiler(filerIp, `uploads/${storedName}`, req.file.buffer);

            // Store the mapping from original name to stored name
            fileMap.set(originalName, storedName);

            res.json({ status: "ok", filename: originalName });
        } catch (err) {
            console.error(err);
            res.status(500).json({ error: "Upload failed" });
        }
    });
};