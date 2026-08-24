// Run: node tests/named-recording.test.mjs   (needs ffmpeg on PATH)
//
// End to end for named recordings, with NOTHING reaching the air: the bridge
// under test points at a fake harbor on a spare port, so the tone it broadcasts
// lands in a byte counter instead of in the station.
import fs from 'fs';
import net from 'net';
import http from 'http';
import cp from 'child_process';
import crypto from 'crypto';
import path from 'path';
import os from 'os';
import url from 'url';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const SRC = path.join(HERE, '..', 'live-bridge.js');
const TMP = path.join(os.tmpdir(), 'radio-named-recording-test');
const COPY = TMP + '/bridge-under-test.js';
const REC = TMP + '/recordings';
const TONE = TMP + '/tone.webm';
const BPORT = 18007;
const HPORT = 18005;

// The sidecar and the marks are YAML now. These are flat maps of quoted
// scalars, so a line reader is enough and this test stays dependency-free
// like the thing it is testing.
function unyaml(text) {
  const out = {};
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^([A-Za-z_][\w]*):\s*(.*)$/);
    if (!m) continue;
    let v = m[2].trim();
    if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) {
      v = v.slice(1, -1)
        .replace(/\\n/g, '\n').replace(/\\r/g, '\r').replace(/\\t/g, '\t')
        .replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    } else if (v === 'null') v = null;
    else if (v === 'true') v = true;
    else if (v === 'false') v = false;
    else if (/^-?\d+(\.\d+)?$/.test(v)) v = Number(v);
    out[m[1]] = v;
  }
  return out;
}
const ok = [];
const bad = [];
const t = (name, cond, detail) => (cond ? ok : bad).push(name + (detail ? '  [' + detail + ']' : ''));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

fs.rmSync(TMP, { recursive: true, force: true });
fs.mkdirSync(REC, { recursive: true });

// --- the bridge under test, pointed somewhere harmless ----------------------
let src = fs.readFileSync(SRC, 'utf8');
const anchor = 'const HARBOR_PORT = 8005;';
const hits = src.split(anchor).length - 1;
if (hits !== 1) {
  console.log('ABORT: HARBOR_PORT anchor matched ' + hits);
  process.exit(1);
}
src = src.replace(anchor, 'const HARBOR_PORT = ' + HPORT + ';');
src = src.replace('function harborPassword() {', 'function harborPassword() {\n  return "test";');
fs.writeFileSync(COPY, src);

// --- a harbor that says yes and swallows ------------------------------------
let harborBytes = 0;
let harborSaw = '';
const harbor = net.createServer((sock) => {
  let head = true;
  sock.on('data', (d) => {
    if (head) {
      harborSaw += d.toString('latin1');
      const i = harborSaw.indexOf('\r\n\r\n');
      if (i >= 0) {
        head = false;
        sock.write('HTTP/1.0 200 OK\r\n\r\n');
      }
    } else {
      harborBytes += d.length;
    }
  });
  sock.on('error', () => {});
});
await new Promise((r) => harbor.listen(HPORT, '127.0.0.1', r));

// --- a tone, cut at real cluster boundaries ---------------------------------
// MediaRecorder puts the header in the first blob and a whole cluster in each
// blob after it. Splitting anywhere else would be testing a stream no browser
// produces, so the split is on the Cluster id itself.
cp.execFileSync('ffmpeg', ['-hide_banner', '-v', 'error', '-y', '-f', 'lavfi',
  '-i', 'sine=f=440:r=48000:d=20', '-c:a', 'libopus', '-b:a', '96k',
  '-cluster_time_limit', '900', '-f', 'webm', TONE]);
const buf = fs.readFileSync(TONE);
const CLUSTER = Buffer.from([0x1f, 0x43, 0xb6, 0x75]);
const at = [];
for (let i = 0; (i = buf.indexOf(CLUSTER, i)) !== -1; i += 4) at.push(i);
const chunks = [buf.subarray(0, at[0])];
for (let i = 0; i < at.length; i++) {
  chunks.push(buf.subarray(at[i], i + 1 < at.length ? at[i + 1] : buf.length));
}
t('the tone split into clusters', at.length >= 8, at.length + ' clusters, header ' + at[0] + ' bytes');

// --- run it -----------------------------------------------------------------
const child = cp.spawn(process.execPath, [COPY], {
  env: Object.assign({}, process.env, { RADIO_BRIDGE_PORT: String(BPORT), RADIO_RECORD: REC }),
  stdio: ['ignore', 'pipe', 'pipe'],
});
let blog = '';
child.stdout.on('data', (d) => { blog += d; });
child.stderr.on('data', (d) => { blog += d; });
await sleep(900);

// --- a webcast client -------------------------------------------------------
function mask(op, payload) {
  const p = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const k = crypto.randomBytes(4);
  const n = p.length;
  let head;
  if (n < 126) {
    head = Buffer.alloc(2);
    head[1] = 0x80 | n;
  } else if (n < 65536) {
    head = Buffer.alloc(4);
    head[1] = 0x80 | 126;
    head.writeUInt16BE(n, 2);
  } else {
    head = Buffer.alloc(10);
    head[1] = 0x80 | 127;
    head.writeBigUInt64BE(BigInt(n), 2);
  }
  head[0] = 0x80 | op;
  const body = Buffer.from(p);
  for (let i = 0; i < n; i++) body[i] ^= k[i & 3];
  return Buffer.concat([head, k, body]);
}

const sock = net.connect(BPORT, '127.0.0.1');
await new Promise((r) => sock.once('connect', r));
sock.write('GET /host/onair HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n' +
  'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: webcast\r\n' +
  'X-Host-User: tester\r\nSec-WebSocket-Key: ' + crypto.randomBytes(16).toString('base64') + '\r\n\r\n');
let fromBridge = '';
sock.on('data', (d) => { fromBridge += d.toString('latin1'); });
await sleep(300);
t('the socket upgraded', /101 Switching Protocols/.test(fromBridge));

sock.write(mask(0x1, JSON.stringify({ type: 'hello', data: { mime: 'audio/webm' } })));
await sleep(1600);
t('the bridge went live against the fake harbor', /SOURCE|PUT/.test(harborSaw),
  harborSaw.split('\r\n')[0] || '(nothing arrived)');

const say = (op, p) => sock.write(mask(op, p));
const post = (p) => new Promise((res) => {
  const r = http.request({
    host: '127.0.0.1', port: BPORT, path: p, method: 'POST',
    headers: { 'X-Host-User': 'tester', 'Content-Type': 'application/json' },
  }, (x) => {
    let b = '';
    x.on('data', (d) => { b += d; });
    x.on('end', () => {
      let j = {};
      try { j = JSON.parse(b); } catch (e) { j = {}; }
      res({ code: x.statusCode, j: j });
    });
  });
  r.on('error', () => res({ code: 0, j: {} }));
  r.end();
});

// header plus three clusters before anybody asks for a recording
for (let i = 0; i < 4; i++) { say(0x2, chunks[i]); await sleep(60); }

const started = await post('/rec/start?name=Sweet%20Jane%20Test');
t('start accepted', started.code === 200 && started.j.ok === true,
  'HTTP ' + started.code + ' ' + JSON.stringify(started.j.why || started.j.file || ''));

const KEPT = 10;
for (let i = 4; i < 4 + KEPT; i++) { say(0x2, chunks[i]); await sleep(60); }

const stopped = await post('/rec/stop');
t('stop accepted', stopped.code === 200 && stopped.j.ok === true, 'HTTP ' + stopped.code);

// audio that must NOT end up in the named file
for (let i = 4 + KEPT; i < chunks.length; i++) { say(0x2, chunks[i]); await sleep(40); }
await sleep(600);
sock.destroy();
await sleep(1000);

// --- what landed ------------------------------------------------------------
const namedDir = REC + '/named';
const named = fs.existsSync(namedDir) ? fs.readdirSync(namedDir) : [];
const webm = named.filter((f) => f.endsWith('.webm'));
const side = named.filter((f) => f.endsWith('.yaml'));
t('one named recording exists', webm.length === 1, named.join(', ') || '(none)');
t('it is named after what was asked for', !!webm[0] && webm[0].indexOf('sweet-jane-test-') === 0, webm[0] || '');
t('it has a sidecar', side.length === 1);

let meta = {};
try { meta = unyaml(fs.readFileSync(namedDir + '/' + side[0], 'utf8')); } catch (e) { meta = {}; }
t('the sidecar names who asked', meta.by === 'tester', JSON.stringify(meta.by));
t('the sidecar keeps the name', meta.name === 'Sweet Jane Test', JSON.stringify(meta.name));
t('the sidecar points at its backup', !!meta.backup && fs.existsSync(REC + '/' + meta.backup), String(meta.backup));

function readBack(f) {
  try {
    const r = cp.spawnSync('ffmpeg', ['-hide_banner', '-v', 'error', '-stats', '-i', f, '-c', 'copy', '-f', 'null', 'NUL'],
      { encoding: 'utf8' });
    return String(r.stderr || '') + String(r.stdout || '');
  } catch (e) {
    return String(e.message);
  }
}
function secondsOf(out) {
  const m = out.match(/time=(\d+):(\d\d):([\d.]+)/g);
  if (!m) return -1;
  const p = m[m.length - 1].slice(5).split(':');
  return (+p[0]) * 3600 + (+p[1]) * 60 + (+p[2]);
}

const namedOut = readBack(namedDir + '/' + webm[0]);
const secs = secondsOf(namedOut);
t('the named recording DECODES', secs > 0, 'ffmpeg read ' + (secs > 0 ? secs + 's' : 'nothing'));
t('it holds the kept stretch, not the whole show', secs > 3 && secs < 14, secs + 's out of a 20s tone');

// --- the control ------------------------------------------------------------
// The same audio WITHOUT the kept header. If this decoded too, the header
// capture would be doing nothing and the assertion above would pass for free.
const headerless = TMP + '/headerless.webm';
fs.writeFileSync(headerless, Buffer.concat(chunks.slice(4, 4 + KEPT)));
const ctl = readBack(headerless);
t('CONTROL: the same audio without the header does NOT decode',
  secondsOf(ctl) <= 0,
  (ctl.split('\n').find((l) => l.trim()) || '').slice(0, 90) || 'it decoded fine - the header capture is doing nothing');

// --- and the backup carries the span ----------------------------------------
const jl = fs.readdirSync(REC).filter((f) => f.endsWith('.marks.yaml'));
let marks = [];
try {
  marks = fs.readFileSync(REC + '/' + jl[0], 'utf8')
    .split('---').filter((d) => d.trim()).map(unyaml);
} catch (e) {
  marks = [];
}
t('the backup records the span too',
  marks.some((x) => x.kind === 'rec-start') && marks.some((x) => x.kind === 'rec-stop'),
  marks.map((x) => x.kind).join(',') || '(no marks)');

try { child.kill(); } catch (e) { /* already gone */ }
harbor.close();

console.log('PASS');
for (const l of ok) console.log('  + ' + l);
if (bad.length) {
  console.log('');
  console.log('FAIL');
  for (const l of bad) console.log('  - ' + l);
}
console.log('');
console.log(ok.length + ' passed, ' + bad.length + ' failed');
console.log('');
console.log('bridge log:');
console.log(blog.split('\n').filter((l) => /record|backup|on air|flush/i.test(l)).join('\n'));
process.exit(bad.length ? 1 : 0);
