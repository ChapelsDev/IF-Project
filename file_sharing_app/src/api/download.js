const { downloadFromFiler } = require("../seaweed/filerClient");
const fileMap = require("../fileMap");

module.exports = function(app) {
    app.get("/download/:name", async (req, res) => {
        try {
            const originalName = req.params.name;
            const storedName = fileMap.get(originalName);

            if (!storedName) {
                return res.status(404).json({ error: "File not found" });
            }

            const stream = await downloadFromFiler(`uploads/${storedName}`);

            res.setHeader("Content-Disposition", `attachment; filename=${originalName}`);
            stream.pipe(res);

        } catch (err) {
            console.error(err);
            // SeaweedFS filer might return 404, which axios treats as an error
            if (err.response && err.response.status === 404) {
                return res.status(404).json({ error: "File not found in storage" });
            }
            res.status(500).json({ error: "Download failed" });
        }
    });
};