const express = require("express");
const app = express();
const PORT = process.env.PORT || 3000;
const VERSION = process.env.APP_VERSION || "1.0.0";

app.get("/", (req, res) => {
  res.json({
    status: "ok",
    version: VERSION,
    message: "CI/CD Auto Rollback — GitHub Actions + Docker + EC2",
    timestamp: new Date().toISOString(),
    host: require("os").hostname(),
  });
});

// /health is what the rollback script monitors after every deploy
app.get("/health", (req, res) => {
  if (VERSION.includes("bad")) {
    return res.status(500).json({ status: "unhealthy", version: VERSION });
  }
  res.json({ status: "healthy", version: VERSION });
});

const server = app.listen(PORT, () => {
  console.log(`App v${VERSION} running on port ${PORT}`);
});

module.exports = { app, server };
