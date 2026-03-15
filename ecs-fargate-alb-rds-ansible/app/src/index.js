const express = require("express");
const app = express();
const port = process.env.PORT || 8080;

app.get("/health", (_, res) => res.status(200).send("ok"));
app.get("/", (_, res) => res.status(200).send("hello from ecs"));

app.listen(port, () => console.log(`listening on ${port}`));
