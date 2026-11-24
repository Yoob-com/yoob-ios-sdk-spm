// Minimal backend for the Yoob examples. It keeps your keys on the server and hands the app short-lived credentials.
//
//   YOOB_API_KEY=yoob_test_... YOOB_EXAMPLE_ALLOW_ANONYMOUS=1 [OPENAI_API_KEY=sk-...] node server.mjs
//
// POST /yoob-session   → a full-mode Yoob session: character downloads, metering, and one conversation in Yoob's own
//                        voice (YoobDuotoneConversation; no provider key, minutes billed to your workspace)
// POST /openai-secret  → an OpenAI Realtime client secret, for YoobConversation with your own OpenAI account
//                        (only if OPENAI_API_KEY is set)
//
// Every session is metered to your workspace, so this server refuses to mint anything until you decide who may ask.
// Replace requireUser() with your own sign-in check before you deploy it. YOOB_EXAMPLE_ALLOW_ANONYMOUS=1 skips the
// check for local development only.
//
// Settings:
//   YOOB_API_KEY                   required. A yoob_test_ key opens sandbox sessions; a yoob_live_ key bills credits.
//   YOOB_CHARACTERS                characters this server hands out, comma-separated (default luna-realistic,luna-anime)
//   YOOB_EXAMPLE_ALLOW_ANONYMOUS   1 lets anyone mint sessions. Local development only.
//   YOOB_RATE_LIMIT                sessions per user per minute, across all routes (default 10)
//   PORT                           default 3100. The server listens on 127.0.0.1 only.
import http from "node:http";

const apiKey = process.env.YOOB_API_KEY;
const apiBase = process.env.YOOB_API_BASE ?? "https://app.yoob.com";
const port = Number(process.env.PORT ?? 3100);
const allowAnonymous = process.env.YOOB_EXAMPLE_ALLOW_ANONYMOUS === "1";
const allowedCharacters = new Set(
  (process.env.YOOB_CHARACTERS || "luna-realistic,luna-anime").split(",").map((id) => id.trim()).filter(Boolean),
);
const perMinute = Math.max(1, Number(process.env.YOOB_RATE_LIMIT || 10) || 10);
if (!apiKey) throw new Error("Set YOOB_API_KEY: a yoob_test_ key from your workspace on the Yoob console");
if (allowedCharacters.has("*")) throw new Error("YOOB_CHARACTERS must list character ids, not *");

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

/**
 * Who is asking. Replace this with your own authentication: verify your session cookie or bearer token and return a
 * stable user id. Throw HttpError(401) when the caller isn't signed in.
 */
async function requireUser(req) {
  if (allowAnonymous) return `anonymous:${req.socket.remoteAddress ?? "local"}`;
  throw new HttpError(401,
    "This example token server has no authentication. Implement your own auth in requireUser() in token-server/server.mjs, "
    + "or set YOOB_EXAMPLE_ALLOW_ANONYMOUS=1 for local development only.");
}

// A fixed-window limit per user, in memory. Use a shared store (Redis, your database) when you run more than one server.
const windows = new Map();
function rateLimit(user) {
  const now = Date.now();
  const window = windows.get(user);
  if (!window || now - window.start >= 60_000) {
    windows.set(user, { start: now, count: 1 });
    return;
  }
  window.count += 1;
  if (window.count > perMinute) throw new HttpError(429, "Too many sessions. Try again in a minute.");
}
setInterval(() => {
  const cutoff = Date.now() - 60_000;
  for (const [user, window] of windows) if (window.start < cutoff) windows.delete(user);
}, 60_000).unref();

function requireCharacter(body) {
  const character = body?.character;
  if (typeof character !== "string" || !allowedCharacters.has(character)) {
    throw new HttpError(400, `character must be one of: ${[...allowedCharacters].join(", ")}`);
  }
  return character;
}

async function readJson(req) {
  let body = "";
  for await (const part of req) {
    body += part;
    if (body.length > 16_384) throw new HttpError(413, "Request too large.");
  }
  try {
    const value = JSON.parse(body || "{}");
    return value && typeof value === "object" ? value : {};
  } catch {
    throw new HttpError(400, "Send a JSON body.");
  }
}

async function forward(res, upstream) {
  res.writeHead(upstream.status, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(await upstream.text());
}

function yoob(path, body) {
  return fetch(`${apiBase}${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    // Built field by field: nothing from the app's request is passed through. Sandbox mode comes from the key.
    body: JSON.stringify(body),
  });
}

const routes = {
  async "/yoob-session"(req, res) {
    rateLimit(await requireUser(req));
    const character = requireCharacter(await readJson(req));
    // Full mode: the session also carries a credential for one conversation in Yoob's own voice (live_token, live_url).
    return forward(res, await yoob("/api/v1/avatar/sessions", { characters: [character], mode: "full", yoob_voice: true }));
  },
  async "/openai-secret"(req, res) {
    if (!process.env.OPENAI_API_KEY) throw new HttpError(501, "Set OPENAI_API_KEY to enable conversations.");
    rateLimit(await requireUser(req));
    return forward(res, await fetch("https://api.openai.com/v1/realtime/client_secrets", {
      method: "POST",
      headers: { authorization: `Bearer ${process.env.OPENAI_API_KEY}`, "content-type": "application/json" },
      body: JSON.stringify({ session: { type: "realtime", model: "gpt-realtime" } }),
    }));
  },
};

http.createServer(async (req, res) => {
  const route = req.method === "POST" ? routes[req.url] : undefined;
  if (!route) return res.writeHead(404).end();
  try {
    await route(req, res);
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 502;
    const message = error instanceof HttpError ? error.message : "Couldn't reach Yoob.";
    if (!(error instanceof HttpError)) console.error(`${req.url}: ${error?.message ?? error}`);
    if (!res.headersSent) res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
    res.end(JSON.stringify({ error: message }));
  }
}).listen(port, "127.0.0.1", () => {
  console.log(`Yoob token server on http://localhost:${port} (characters: ${[...allowedCharacters].join(", ")})`);
  if (allowAnonymous) console.warn("YOOB_EXAMPLE_ALLOW_ANONYMOUS=1: anyone who can reach this server can mint sessions. Local development only.");
});
