const express = require("express");
const app = express();

require("./fileMap"); // Ensures the map is initialized
require("./api/upload")(app);
require("./api/download")(app);

const PORT = 3000;
app.listen(PORT, () => console.log(`App running at http://localhost:${PORT}`));