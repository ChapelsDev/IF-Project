const multer = require("multer");
const upload = multer();
const { uploadToFiler } = require("../seaweed/filerClient");

module.exports = function(app) {
    app.post("/upload", upload.single("file"), async (req, res) => {
        try {
            const filename = req.file.originalname;

            await uploadToFiler(`uploads/${filename}`, req.file.buffer);

            res.json({ status: "ok", filename });
        } catch (err) {
            console.error(err);
            res.status(500).json({ error: "Upload failed" });
        }
    });
};
