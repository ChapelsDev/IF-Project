const { downloadFromFiler } = require("../seaweed/filerClient");
const fileMap = require("../fileMap");

module.exports = function(app) {
    app.get("/download/:name", async (req, res) => {
        try {
            const originalName = req.params.name;
            const filerIp = req.query.filerIp; // Get FILER IP from query parameter
            const storedName = fileMap.get(originalName);

            console.log(`Download request for ${originalName}, stored as ${storedName}, using filer IP: ${filerIp}`);

            if (!filerIp) {
                return res.status(400).json({ error: "FILER IP is required" });
            }

            if (!storedName) {
                return res.status(404).json({ error: "File not found" });
            }

            const stream = await downloadFromFiler(filerIp, `uploads/${storedName}`);

            res.setHeader("Content-Disposition", `attachment; filename=${originalName}`);
            stream.pipe(res);

        } catch (err) {
            console.error(err);
            if (err.response && err.response.status === 404) {
                return res.status(404).json({ error: "File not found in storage" });
            }
            res.status(500).json({ error: "Download failed" });
        }
    });
};