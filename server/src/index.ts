import http from "node:http";
import os from "node:os";
import { WebSocketServer } from "ws";
import { CONFIG } from "./config.js";
import { Store } from "./store.js";
import { GameServer } from "./game/game-server.js";
import { DEFAULT_CONTENT_DIR, loadContent } from "./content/loader.js";

const content = loadContent(process.env.CONTENT_DIR ?? DEFAULT_CONTENT_DIR);
const store = new Store(CONFIG.dataDir);
const game = new GameServer(store, content);
const bootedAt = Date.now();

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json; charset=utf-8" });
    res.end(
      JSON.stringify({
        status: "ok",
        online: game.onlineCount,
        uptimeSeconds: Math.floor((Date.now() - bootedAt) / 1000),
        characters: store.characterCount()
      })
    );
    return;
  }
  if (req.url === "/") {
    res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
    res.end("BWMMO prototype server. Connect with the Godot client.\n");
    return;
  }
  res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
  res.end("Not found\n");
});

const wss = new WebSocketServer({
  server,
  maxPayload: CONFIG.maxMessageBytes,
  clientTracking: true
});

wss.on("connection", (ws, req) => {
  game.attach(ws, req.socket.remoteAddress ?? "unknown");
});

wss.on("error", (error) => {
  console.error("[net] websocket server error:", error);
});

server.on("error", (error) => {
  console.error("[http] server error:", error);
  process.exitCode = 1;
});

server.listen(CONFIG.port, CONFIG.host, () => {
  console.log("");
  console.log("  BWMMO prototype server");
  console.log(`  WebSocket: ws://localhost:${CONFIG.port}`);
  const lanAddresses: string[] = [];
  for (const addresses of Object.values(os.networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family === "IPv4" && !address.internal) {
        lanAddresses.push(`ws://${address.address}:${CONFIG.port}`);
      }
    }
  }
  if (lanAddresses.length > 0) {
    console.log("  LAN (use this on your phone):");
    for (const url of lanAddresses) console.log(`    ${url}`);
  }
  console.log(`  Health:    http://localhost:${CONFIG.port}/health`);
  console.log(`  Data:      ${CONFIG.dataDir}`);
  console.log(
    `  Content:   ${Object.keys(content.maps).length} maps, ${Object.keys(content.species).length} species, ${Object.keys(content.moves).length} moves`
  );
  console.log(
    `  Encounter: ${
      CONFIG.encounterRateOverride === null
        ? "map default"
        : `forced to ${CONFIG.encounterRateOverride}`
    }`
  );
  console.log("");
});

let shuttingDown = false;
function shutdown(signal: string): void {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`[server] ${signal} received, saving and shutting down...`);
  try {
    game.stop();
    wss.close();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1500).unref();
  } catch (error) {
    console.error("[server] shutdown error:", error);
    process.exit(1);
  }
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
