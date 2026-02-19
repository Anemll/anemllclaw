#!/usr/bin/env node
import http from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const portArg = process.argv[2];
const envPort = process.env.OPENCLAW_TVOS_CHAT_WEB_PORT;
const port = Number(portArg || envPort || 8088);

if (!Number.isInteger(port) || port <= 0 || port > 65535) {
  console.error("Invalid port. Use 1-65535.");
  process.exit(1);
}

const root = __dirname;
const defaultFile = "index.html";

const mimeByExt = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".mjs", "text/javascript; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".txt", "text/plain; charset=utf-8"],
  [".svg", "image/svg+xml"],
  [".png", "image/png"],
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".ico", "image/x-icon"],
]);

function normalizeRequestPath(urlPath) {
  const raw = decodeURIComponent((urlPath || "/").split("?")[0]);
  const clean = raw === "/" ? `/${defaultFile}` : raw;
  const joined = path.join(root, clean);
  const normalized = path.normalize(joined);
  if (!normalized.startsWith(root)) {
    return null;
  }
  return normalized;
}

const server = http.createServer(async (req, res) => {
  const filePath = normalizeRequestPath(req.url || "/");
  if (!filePath) {
    res.writeHead(403, { "content-type": "text/plain; charset=utf-8" });
    res.end("Forbidden");
    return;
  }

  try {
    const data = await readFile(filePath);
    const ext = path.extname(filePath).toLowerCase();
    const contentType = mimeByExt.get(ext) || "application/octet-stream";
    res.writeHead(200, { "content-type": contentType });
    res.end(data);
  } catch {
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("Not found");
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`OpenClaw tvOS chat web server listening on http://127.0.0.1:${port}`);
  console.log(`Serving: ${root}`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
  });
}
