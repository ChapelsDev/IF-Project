const { downloadFromFiler } = require("../seaweed/filerClient");

module.exports = function(app) {
    app.get("/download/:name", async (req, res) => {
        try {
            const name = req.params.name;

            const stream = await downloadFromFiler(`uploads/${name}`);

            res.setHeader("Content-Disposition", `attachment; filename=${name}`);
            stream.pipe(res);

        } catch (err) {
            console.error(err);
            res.status(404).json({ error: "File not found" });
        }
    });
};
