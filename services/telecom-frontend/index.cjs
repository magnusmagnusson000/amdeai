// Copyright © Advanced Micro Devices, Inc., or its affiliates.
//
// SPDX-License-Identifier: MIT

require("dotenv").config();
const express = require("express");
const http = require("http");
const path = require("path");
const httpProxy = require("http-proxy");
const { AccessToken } = require("livekit-server-sdk");

const app = express();
app.use(express.json());

const {
  LIVEKIT_API_KEY,
  LIVEKIT_API_SECRET,
  LIVEKIT_URL,
  LIVEKIT_UPSTREAM = "http://eai-telecom-livekit:80",
  LIVEKIT_PROXY_ENABLED = "1",
  LIVEKIT_PROXY_PREFIX = "/livekit",
  PORT = "3000",
  LLM_WARMUP_URL = "http://qwen3-6-27b-llm.default.svc.cluster.local",
  LLM_MODEL = "Qwen/Qwen3.6-27B",
} = process.env;

const proxy = httpProxy.createProxyServer({ ws: true, changeOrigin: true });
proxy.on("error", (err, _req, res) => {
  console.error("livekit proxy error:", err.message);
  if (res && typeof res.writeHead === "function" && !res.headersSent) {
    res.writeHead(502);
    res.end("LiveKit proxy error");
  }
});

function clientLiveKitUrl(req) {
  if (LIVEKIT_PROXY_ENABLED === "1") {
    const host = req.headers["x-forwarded-host"] || req.headers.host;
    const secure =
      req.headers["x-forwarded-proto"] === "https" ||
      req.headers["x-forwarded-ssl"] === "on";
    const proto = secure ? "wss" : "ws";
    return `${proto}://${host}${LIVEKIT_PROXY_PREFIX}`;
  }
  return LIVEKIT_URL;
}

function warmupLlm() {
  const base = LLM_WARMUP_URL.replace(/\/$/, "");
  const url = base.endsWith("/v1")
    ? `${base}/chat/completions`
    : `${base}/v1/chat/completions`;
  fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Bearer no-key-required",
    },
    body: JSON.stringify({
      model: LLM_MODEL,
      messages: [{ role: "user", content: "hi" }],
      max_tokens: 1,
    }),
  })
    .then((r) => {
      if (!r.ok) console.warn("llm warmup HTTP", r.status);
      else console.log("llm warmup ok");
    })
    .catch((e) => console.warn("llm warmup failed:", e.message));
}

if (LIVEKIT_PROXY_ENABLED === "1") {
  app.use(LIVEKIT_PROXY_PREFIX, (req, res) => {
    req.url = req.url.replace(new RegExp(`^${LIVEKIT_PROXY_PREFIX}`), "") || "/";
    proxy.web(req, res, { target: LIVEKIT_UPSTREAM });
  });
}

app.post("/api/connection-details", async (req, res) => {
  warmupLlm();
  const serverUrl = clientLiveKitUrl(req);
  if (!serverUrl || !LIVEKIT_API_KEY || !LIVEKIT_API_SECRET) {
    return res.status(500).json({ error: "LiveKit env vars not configured" });
  }

  const agentName = req.body?.room_config?.agents?.[0]?.agent_name;
  const participantIdentity = `voice_assistant_user_${Math.floor(Math.random() * 10_000)}`;
  const roomName = `voice_assistant_room_${Math.floor(Math.random() * 10_000)}`;

  const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: participantIdentity,
    name: "user",
    ttl: "15m",
  });

  at.addGrant({
    room: roomName,
    roomJoin: true,
    canPublish: true,
    canPublishData: true,
    canSubscribe: true,
  });

  if (agentName) {
    at.roomConfig = { agents: [{ agentName }] };
  }

  const token = await at.toJwt();

  res.json({
    serverUrl,
    roomName,
    participantToken: token,
    participantName: "user",
  });
});

// In production, serve the built Vite app
const clientDist = path.join(__dirname, "../dist");
app.use(express.static(clientDist));
app.get("/{*path}", (_req, res) => {
  res.sendFile(path.join(clientDist, "index.html"));
});

const server = http.createServer(app);
server.on("upgrade", (req, socket, head) => {
  if (!req.url?.startsWith(LIVEKIT_PROXY_PREFIX)) {
    socket.destroy();
    return;
  }
  req.url = req.url.slice(LIVEKIT_PROXY_PREFIX.length) || "/";
  proxy.ws(req, socket, head, { target: LIVEKIT_UPSTREAM });
});

server.listen(Number(PORT), "0.0.0.0", () => {
  console.log(`Server running on port ${PORT}`);
  if (LIVEKIT_PROXY_ENABLED === "1") {
    console.log(`LiveKit WS proxy: ${LIVEKIT_PROXY_PREFIX} -> ${LIVEKIT_UPSTREAM}`);
  }
  warmupLlm();
});
