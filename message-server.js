#!/usr/bin/env node
// Guestbook for the radio station.
// Binds loopback only - Caddy proxies /api/* here and terminates TLS.
// Zero dependencies (Node built-ins only).

const http = require('http');
const fs   = require('fs');
const path = require('path');

const PORT      = 8787;
const DIR       = path.join(__dirname, 'messages');
const ICECAST   = 'http://127.0.0.1:8000/status-json.xsl';

const MAX_NAME  = 40;
const MAX_TEXT  = 500;
const MAX_PER_FILE = 5000;          // sanity cap per day file
const RATE_WINDOW  = 20 * 1000;     // one message per 20s per IP
const HOURLY_CAP   = 12;            // and at most 12 per hour per IP

fs.mkdirSync(DIR, { recursive: true });

// --- naive in-memory rate limiting. Resets on restart; that is fine. ---
const lastPost = new Map();   // ip -> timestamp
const hourly   = new Map();   // ip -> [timestamps]

function rateLimited(ip) {
  const now = Date.now();
  const last = lastPost.get(ip) || 0;
  if (now - last < RATE_WINDOW) return 'too fast';
  const hits = (hourly.get(ip) || []).filter(t => now - t < 3600 * 1000);
  if (hits.length >= HOURLY_CAP) return 'hourly limit reached';
  hits.push(now);
  hourly.set(ip, hits);
  lastPost.set(ip, now);
  return null;
}

function dayFile(d = new Date()) {
  const iso = d.toISOString().slice(0, 10);
  return path.join(DIR, `${iso}.jsonl`);
}

async function nowPlaying() {
  try {
    const res = await fetch(ICECAST, { signal: AbortSignal.timeout(3000) });
    const j = await res.json();
    let s = j.icestats && j.icestats.source;
    if (!s) return null;
    if (!Array.isArray(s)) s = [s];
    const src = s.find(x => (x.listenurl || '').endsWith('/stream')) || s[0];
    return (src && src.title) || null;
  } catch { return null; }
}

function readRecent(limit = 100) {
  const files = fs.readdirSync(DIR).filter(f => f.endsWith('.jsonl')).sort().reverse();
  const out = [];
  for (const f of files) {
    const lines = fs.readFileSync(path.join(DIR, f), 'utf8').trim().split('\n').filter(Boolean);
    for (let i = lines.length - 1; i >= 0; i--) {
      try { out.push(JSON.parse(lines[i])); } catch {}
      if (out.length >= limit) return out;
    }
  }
  return out;
}

function send(res, code, body, type = 'application/json') {
  const data = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(code, {
    'content-type': type,
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(data),
  });
  res.end(data);
}

const server = http.createServer(async (req, res) => {
  // Caddy passes the real client address in X-Forwarded-For.
  const ip = (req.headers['x-forwarded-for'] || '').split(',')[0].trim()
             || req.socket.remoteAddress || 'unknown';

  if (req.method === 'GET' && req.url.startsWith('/api/messages')) {
    return send(res, 200, { messages: readRecent(100) });
  }

  if (req.method === 'POST' && req.url.startsWith('/api/message')) {
    let raw = '';
    let tooBig = false;
    req.on('data', c => {
      raw += c;
      if (raw.length > 4000) { tooBig = true; req.destroy(); }
    });
    req.on('end', async () => {
      if (tooBig) return;
      let body;
      try { body = JSON.parse(raw); } catch { return send(res, 400, { error: 'bad json' }); }

      // honeypot: real browsers leave this empty, bots fill everything
      if (body.website) return send(res, 200, { ok: true });

      const name = String(body.name || 'anonymous').trim().slice(0, MAX_NAME) || 'anonymous';
      const text = String(body.text || '').trim().slice(0, MAX_TEXT);
      if (!text) return send(res, 400, { error: 'message is empty' });

      const limited = rateLimited(ip);
      if (limited) return send(res, 429, { error: limited });

      const file = dayFile();
      if (fs.existsSync(file)) {
        const count = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).length;
        if (count >= MAX_PER_FILE) return send(res, 429, { error: 'busy, try tomorrow' });
      }

      // No IP is stored - rate limiting is in memory only.
      const entry = {
        at: new Date().toISOString(),
        name,
        text,
        playing: await nowPlaying(),
      };
      fs.appendFileSync(file, JSON.stringify(entry) + '\n', 'utf8');
      return send(res, 200, { ok: true, entry });
    });
    return;
  }

  send(res, 404, { error: 'not found' });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`guestbook listening on 127.0.0.1:${PORT}, writing to ${DIR}`);
});
