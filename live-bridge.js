// The live bridge: a browser speaking `webcast` on one side, the icecast
// source protocol on the other.
//
//     /host/ page  --webcast over ws-->  this  --icecast source-->  127.0.0.1:8005/live
//
// WHY THIS EXISTS, and it is not the reason you would guess.
//
// The station has always accepted a live source: `input.harbor` on 8005 sits
// there waiting for butt or ffmpeg. What a browser could not do was BE one -
// the icecast source protocol wants a raw TCP socket carrying an HTTP body
// that never ends, and a page cannot open one.
//
// But liquidsoap solved the browser half years ago. savonet wrote the
// `webcast` protocol - a websocket subprotocol for pushing audio out of a page
// - and THIS BUILD IMPLEMENTS IT. That was measured rather than assumed,
// because it is the sort of thing that gets asserted both ways: a websocket
// upgrade to /live on port 8005 is answered `101 Switching Protocols` with
// `Sec-WebSocket-Protocol: webcast` echoed, from 127.0.0.1 and from
// 192.168.1.102 alike and from another machine on the LAN; a hello frame and
// webm/opus binary frames after it produced `[live:3] Decoding...` and
// `[duck:3] music down`; and a deliberately wrong password was refused with a
// websocket close 1011 carrying the text "Authentication failed.", which
// nothing but liquidsoap's own webcast implementation could have produced.
//
// So the harbor does not need a bridge in order to talk to a browser. It needs
// one for a different and permanent reason: THE WEBCAST HELLO FRAME CARRIES
// THE SOURCE PASSWORD, and the source password must not be in a page. A page
// pointed straight at 8005 would work on the first attempt and would hand the
// station's microphone credential to every host with a devtools window.
//
// This is therefore not a stopgap and not a shim around a missing feature. It
// is where the credential changes hands, it is the permanent shape of
// live-from-the-browser here, and it should be maintained as a component
// rather than tolerated as one.
//
// SO WHY NOT RELAY WEBCAST TO WEBCAST, and let liquidsoap's own implementation
// do the rest? Because of how the two paths FAIL, which was also measured:
//
//   wrong password   websocket: close 1011 "Authentication failed."   clear
//                    icecast:   401 Wrong Authentication data          clear
//   mount taken      websocket: close 1006, no reason at all          opaque
//                    icecast:   403 Mountpoint already taken           clear
//
// A mount already taken is the failure a host will actually meet - only one
// source can hold /live, and butt or a phone may be on it - and it is the one
// the console has to explain rather than spin on. The websocket path drops the
// connection without a word (liquidsoap logs `Harbor.Make(T).Mount_taken` and
// tells the client nothing). The icecast path says it in a sentence. Since the
// bridge has to exist either way, it takes the side that can answer the
// question.
//
// NOTHING IS TRANSCODED. MediaRecorder produces webm/opus, the harbor decodes
// webm/opus, and every byte that arrives is written out unchanged. This
// process never opens an encoder, an audio library or ffmpeg.
//
// NO DEPENDENCIES. `ws` would do the framing, and a node_modules here would
// make the station's uptime depend on npm resolving. Server-side RFC 6455 is
// about ninety lines and all of it is below; the only subtle part is that a
// client frame is always masked and a server frame never is.

'use strict';

const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const cp = require('child_process');

// --- where things are ------------------------------------------------------
// Machine environment, like everything else here. Nothing absolute is written
// in this file.
const HOME = process.env.RADIO_HOME;
if (!HOME) { console.error('RADIO_HOME is not set'); process.exit(2); }

// Loopback only. Caddy is the only thing that should ever reach this, because
// caddy is what asks who you are; a bridge on 0.0.0.0 would be an
// unauthenticated microphone into the station.
const PORT = Number(process.env.RADIO_BRIDGE_PORT || 8007);
// Where broadcasts are kept. An environment variable rather than a constant
// because this is the one thing here that grows without limit - an hour of a
// show is tens of megabytes - and the machine this runs on has had C: at zero
// twice. Moving it to another drive should not need an edit to this file.
const RECORD = process.env.RADIO_RECORD || (HOME ? path.join(HOME, 'recordings') : '');
const HOST = '127.0.0.1';

const HARBOR_HOST = '127.0.0.1';
const HARBOR_PORT = 8005;
const HARBOR_MOUNT = '/live';
// input.harbor's own default, and radio.liq does not override it.
const HARBOR_USER = 'source';

// The harbor keeps the mount for `timeout` seconds after the last byte - 5.0
// in radio.liq - and answers 403 to anything arriving inside that window.
// MEASURED, not assumed: a source destroyed at 17:40:10 was still holding at
// +0.3s and the harbor gave it up at 17:40:15, five seconds later to the
// tenth, whether the socket was half-closed or reset. So a host who stops and
// immediately starts again is NORMAL and must not see an error; this retries
// across that window and only then decides somebody else is on the air.
const RETRY_EVERY_MS = 1200;
const RETRY_FOR_MS = 12000;

// A client that does not wait to be told the mount is held - webcaster does
// not, it sends hello and starts - would otherwise lose its first audio, and
// for webm the first blob is the one carrying the header. So audio arriving
// before the mount is kept, up to here. The console page never uses this: it
// waits for `ready`, which costs nothing when the mount is granted in tens of
// milliseconds and avoids paying for the wait in latency afterwards.
const PREROLL_MAX = 512 * 1024;

// A hello frame is the first thing a webcast client sends. One that never
// arrives is a client that is not speaking this protocol.
const HELLO_WAIT_MS = 10000;

const LOG = process.env.RADIO_LIQ ? path.join(process.env.RADIO_LIQ, 'log', 'live-bridge.log') : null;
const LOG_MAX = 4 * 1024 * 1024;

function log(...a) {
  const line = new Date().toISOString() + ' ' + a.join(' ');
  console.log(line);
  if (!LOG) return;
  try {
    // No rotation library, and no roll-over at a size boundary mid-line: if it
    // has grown past the cap, start it again. This is a diary, not a ledger.
    let st = null;
    try { st = fs.statSync(LOG); } catch {}
    if (st && st.size > LOG_MAX) fs.writeFileSync(LOG, '');
    fs.appendFileSync(LOG, line + '\n');
  } catch {}
}

// --- the password ----------------------------------------------------------
// It is not a machine environment variable. It lives on the LiquidsoapRadio
// service key, which is how liquidsoap itself gets it, so this reads the same
// one from the same place and there is no second copy to go stale.
//
// reg.exe prints a REG_MULTI_SZ on ONE line with a literal backslash-zero
// between entries, not a NUL byte. Splitting on whitespace instead cost a 401
// and ten minutes: it captured the harbor password and the icecast one that
// follows it as a single 53-character string.
//
// Read fresh on every attempt rather than cached at startup, so rotating it
// and restarting liquidsoap does not also need this restarted. It is never
// logged, never sent to a client and never in an error message.
const SERVICE_KEY = ['HKLM', 'SYSTEM', 'CurrentControlSet', 'Services', 'LiquidsoapRadio'].join('\\');
const PW_NAME = 'RADIO_HARBOR_PASSWORD';

function harborPassword() {
  const out = cp.execFileSync('reg.exe', ['query', SERVICE_KEY, '/v', 'Environment'],
                              { encoding: 'latin1', windowsHide: true });
  for (const line of out.split(/\r?\n/)) {
    const m = line.match(/^\s*Environment\s+REG_MULTI_SZ\s+(.*)$/);
    if (!m) continue;
    for (const entry of m[1].split('\\0')) {
      if (entry.startsWith(PW_NAME + '=')) return entry.slice(PW_NAME.length + 1);
    }
  }
  throw new Error(PW_NAME + ' is not on the LiquidsoapRadio service key');
}

// --- yaml -------------------------------------------------------------------
// A tiny emitter for flat maps, which is all these records are. Written rather
// than pulled in: this process has no dependencies and a recording sidecar is
// not a reason to acquire the first one.
//
// EVERY STRING IS QUOTED, unconditionally. A track called "Movement II: Adagio"
// is a syntax error unquoted, "7" stops being a string, and a title that happens
// to read "yes" becomes a boolean. Quoting always is shorter than the rules for
// when not to.
function yamlValue(v) {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  return '"' + String(v)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\r/g, '\\r')
    .replace(/\n/g, '\\n')
    .replace(/\t/g, '\\t')
    // control characters would end the document rather than the line
    .replace(/[\u0000-\u001f]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')) + '"';
}

function yamlDoc(obj) {
  const keys = Object.keys(obj);
  if (!keys.length) return '--- {}\n';
  return '---\n' + keys.map((k) => k + ': ' + yamlValue(obj[k])).join('\n') + '\n';
}

// --- websocket, server side ------------------------------------------------
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const accept = key => crypto.createHash('sha1').update(key + GUID).digest('base64');

// One server frame. Server frames are never masked, and nothing sent from here
// is ever big - status lines and the odd tally.
function frame(opcode, payload) {
  const len = payload.length;
  let head;
  if (len < 126) { head = Buffer.alloc(2); head[1] = len; }
  else if (len < 65536) { head = Buffer.alloc(4); head[1] = 126; head.writeUInt16BE(len, 2); }
  else { head = Buffer.alloc(10); head[1] = 127; head.writeUInt32BE(0, 2); head.writeUInt32BE(len, 6); }
  head[0] = 0x80 | opcode;
  return Buffer.concat([head, payload]);
}

// A client frame is always masked. Returns null when the frame has not all
// arrived yet.
function readFrame(buf) {
  if (buf.length < 2) return null;
  const fin = (buf[0] & 0x80) !== 0;
  const opcode = buf[0] & 0x0f;
  const masked = (buf[1] & 0x80) !== 0;
  let len = buf[1] & 0x7f;
  let off = 2;
  if (len === 126) {
    if (buf.length < 4) return null;
    len = buf.readUInt16BE(2); off = 4;
  } else if (len === 127) {
    if (buf.length < 10) return null;
    if (buf.readUInt32BE(2) !== 0) throw new Error('frame larger than 4GB');
    len = buf.readUInt32BE(6); off = 10;
  }
  let mask = null;
  if (masked) {
    if (buf.length < off + 4) return null;
    mask = buf.subarray(off, off + 4); off += 4;
  }
  if (buf.length < off + len) return null;
  const payload = Buffer.from(buf.subarray(off, off + len));
  if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
  return { fin, opcode, payload, size: off + len, masked };
}

// --- what a hello frame is allowed to say ----------------------------------
// The mime goes straight into a Content-Type header on the harbor socket, so
// it is the one field a client controls that reaches another protocol. A
// newline in it would be header injection into the source connection. This
// refuses anything that is not a plain type/subtype with an optional codecs
// parameter, and refuses a type the harbor has no decoder for rather than
// letting it fail later as a codec error.
const MIME_OK = /^(audio|video)\/(webm|ogg|mpeg|mp4|aac|flac|wav|x-wav|mp3)(\s*;\s*codecs\s*=\s*"?[A-Za-z0-9.,\- ]{1,40}"?)?$/;

function cleanMime(m) {
  if (typeof m !== 'string') return null;
  const s = m.trim().slice(0, 100);
  if (!MIME_OK.test(s)) return null;
  return s;
}

// --- one console on the air ------------------------------------------------
// At most one of these is on the air. `current` is it.
let current = null;

class Air {
  constructor(sock, who) {
    this.ws = sock;               // the client
    this.who = who || 'a host';
    this.harbor = null;           // the icecast source socket
    this.mime = null;
    this.live = false;
    this.closed = false;
    this.bytes = 0;
    this.startedAt = 0;
    this.began = Date.now();
    this.buf = Buffer.alloc(0);
    this.fragBinary = false;
    this.text = '';
    this.preroll = [];
    this.prerollBytes = 0;
    this.attempt = 0;
    this.firstTry = 0;
    this.retryTimer = null;
    this.tallyTimer = null;
    this.warnedBackpressure = false;
    // The webm initialisation segment, kept deliberately. MediaRecorder writes
    // it once, into the very first blob, and never again - so a file that
    // begins at any later chunk is one no decoder will open. There is nowhere
    // to re-derive it from once those bytes have gone past, so it is held here.
    this.recHead = null;
    // The named recording in progress, if there is one. Going live leaves a
    // BACKUP: automatic, one per broadcast, named after nothing but the clock,
    // there so nothing is ever lost. A RECORDING is a deliberate act - a host
    // presses record, or whatever is watching the shared tab notices a track
    // begin - and it carries a name because somebody meant to keep this
    // particular stretch. They are not the same thing and no longer share a
    // word.
    this.cut = null;

    sock.on('data', d => this.onData(d));
    sock.on('error', e => this.stop('the console socket failed: ' + e.message));
    sock.on('close', () => this.stop('the console went away'));
    // A dropped wifi that never sends a FIN would otherwise hold the mount for
    // as long as this process lives. A ping every fifteen seconds makes the OS
    // notice.
    this.pingTimer = setInterval(() => this.send(0x9, Buffer.alloc(0)), 15000);
    this.helloTimer = setTimeout(() => {
      if (!this.mime) this.giveUp('no hello frame arrived - this port speaks the webcast protocol');
    }, HELLO_WAIT_MS);
  }

  send(opcode, payload) {
    if (this.closed) return;
    try { this.ws.write(frame(opcode, payload)); } catch {}
  }
  // Server-to-client frames are an EXTENSION: the webcast specification
  // defines the client's side only. They are written in the spec's own shape -
  // a `type` and a `data` - and a client that ignores them, as webcaster does,
  // loses nothing but the explanations.
  say(type, data) { this.send(0x1, Buffer.from(JSON.stringify({ type, data: data || {} }))); }

  // --- from the client ---
  onData(d) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, d]) : d;
    for (;;) {
      let f;
      try { f = readFrame(this.buf); }
      catch (e) { return this.stop('bad frame: ' + e.message); }
      if (!f) return;
      this.buf = this.buf.subarray(f.size);
      if (!f.masked && f.opcode !== 0x8) return this.stop('an unmasked frame from a client');
      this.onFrame(f);
      if (this.closed) return;
    }
  }

  onFrame(f) {
    switch (f.opcode) {
      case 0x0:                                     // continuation
        if (this.fragBinary) this.audio(f.payload);
        else this.text += f.payload.toString('utf8');
        if (f.fin && !this.fragBinary) { this.control(this.text); this.text = ''; }
        if (f.fin) this.fragBinary = false;
        return;
      case 0x1:                                     // text: a webcast frame
        if (f.fin) return this.control(f.payload.toString('utf8'));
        this.fragBinary = false; this.text = f.payload.toString('utf8');
        return;
      case 0x2:                                     // binary: audio
        // Forwarded as it arrives rather than waiting for FIN. A fragmented
        // message is the same bytes in the same order, and this is a stream,
        // not a document.
        this.fragBinary = !f.fin;
        return this.audio(f.payload);
      case 0x8: return this.stop('the console said goodbye');
      case 0x9: return this.send(0xa, f.payload);   // ping -> pong
      case 0xa: return;                             // pong
      default: return this.stop('opcode ' + f.opcode);
    }
  }

  // A webcast text frame: `{ type, data }`. The spec says to discard silently
  // anything whose type is not understood, which is what the default does.
  control(s) {
    let m = null;
    try { m = JSON.parse(s); } catch { return; }
    if (!m || typeof m.type !== 'string') return;
    const data = m.data || {};
    switch (m.type) {
      case 'hello': {
        if (this.mime) return;                      // one hello, the first frame
        const mime = cleanMime(data.mime);
        if (!mime) {
          return this.giveUp('hello asked for ' + JSON.stringify(String(data.mime).slice(0, 60)) +
                             ', which is not a content type this station decodes');
        }
        // data.user and data.password are IGNORED, deliberately. The spec
        // allows a client to send credentials and this is the one place that
        // must not honour them: caddy has already decided who this is, and
        // taking a password from the socket would put a second, weaker door on
        // the station's microphone. A webcast client may send whatever it
        // likes there; it is never read.
        this.mime = mime;
        clearTimeout(this.helloTimer);
        log('hello from', this.who + ':', mime,
            data.audio ? JSON.stringify(data.audio).slice(0, 120) : '');
        this.say('waiting', { why: 'asking the station for the mount', attempt: 0, waited: 0 });
        return this.connect();
      }
      case 'metadata':
        // Accepted and not forwarded, and this is worth being explicit about.
        // The station takes its metadata from the file it is playing; a source
        // has no route to set it here that would not mean a change in
        // radio.liq. The spec makes metadata frames optional, so a client that
        // sends them is not broken by being ignored - it just does not get
        // titles.
        // Not forwarded, and now not discarded either: it is written beside the
        // recording as a boundary. The station still takes its own metadata from
        // the file it is playing, which is what the paragraph above is about; a
        // source saying what it is playing is a fact about the RECORDING.
        log('metadata from', this.who, '(marked, not forwarded):',
            JSON.stringify(data).slice(0, 200));
        this.recMark(data);
        return;
      default:
        return;
    }
  }

  audio(chunk) {
    if (!chunk.length) return;
    if (!this.live || !this.harbor) {
      // Kept, not dropped. MediaRecorder puts the whole webm header in its
      // first blob and never again, so dropping it would leave the station
      // decoding a stream it can never make sense of - which reads as a codec
      // fault and is not one. Bounded, because a client that never gets a
      // mount must not grow this process without limit.
      if (this.prerollBytes + chunk.length <= PREROLL_MAX) {
        this.preroll.push(chunk);
        this.prerollBytes += chunk.length;
      }
      return;
    }
    // The first byte of a broadcast, at millisecond resolution. The station's
    // own log keeps whole seconds, so this is the only place the delay between
    // a host speaking and the station holding the audio can actually be read.
    if (!this.firstAudioAt) {
      this.firstAudioAt = Date.now();
      log('first audio from', this.who + ':', chunk.length, 'bytes,',
          this.firstAudioAt - this.startedAt, 'ms after the mount was granted');
    }
    this.bytes += chunk.length;
    this.harbor.write(chunk);
    // After the station and never before it. The broadcast is the point; the
    // recording is a copy of it, and a copy must not be in the way.
    this.recWrite(chunk);
    // Loopback should never back up. If it does, the operator should hear
    // about it from the page rather than from the audio.
    if (this.harbor.writableLength > 1024 * 1024 && !this.warnedBackpressure) {
      this.warnedBackpressure = true;
      log('backpressure to the harbor:', this.harbor.writableLength, 'bytes queued');
      this.say('warn', { why: 'the station is not taking audio as fast as it arrives' });
    }
  }

  // --- keeping the broadcast ------------------------------------------------
  // Opened on the first byte written rather than when the socket arrives, so a
  // client that connects and says nothing leaves no file behind.
  recOpen() {
    if (this.rec || this.recFailed || !RECORD) return;
    try { fs.mkdirSync(RECORD, { recursive: true }); } catch {}
    const d = new Date(), z = (n) => String(n).padStart(2, '0');
    const stamp = d.getUTCFullYear() + z(d.getUTCMonth() + 1) + z(d.getUTCDate()) +
                  '-' + z(d.getUTCHours()) + z(d.getUTCMinutes()) + z(d.getUTCSeconds());
    // A speaker name becomes part of a path here, so it is reduced to characters
    // that cannot be anything else. It arrives from caddy's own auth and is not
    // hostile; it is also not this file's job to be the only thing standing
    // between a name and a filesystem.
    const who = String(this.who || 'someone').replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 40);
    this.recBase = path.join(RECORD, stamp + '-' + who);
    this.recAt = Date.now();
    try {
      this.rec = fs.createWriteStream(this.recBase + '.webm');
      // A recording that fails must never take the broadcast with it. Every
      // path here logs and gives up on the file; nothing throws back towards
      // the audio.
      this.rec.on('error', (e) => {
        log('recording stopped for', this.who + ':', e.message);
        this.rec = null; this.recFailed = true;
      });
      log('recording', this.who, 'to', this.recBase + '.webm');
    } catch (e) {
      log('cannot record', this.who + ':', e.message);
      this.rec = null; this.recFailed = true;
    }
  }

  recWrite(chunk) {
    if (!this.rec) this.recOpen();
    if (this.rec) { try { this.rec.write(chunk); } catch {} }
    // The first thing written carries the header, whether or not the backup
    // itself opened. Kept even when RECORD is unset, because a named recording
    // is still possible without a backup and would be impossible without this.
    if (!this.recHead && chunk && chunk.length) this.recHead = Buffer.from(chunk);
    this.cutWrite(chunk);
  }

  // A boundary, written beside the audio rather than into it. `at` is the
  // offset from the first byte of the recording, which is what anything
  // cutting this into tracks actually needs - a wall clock would have to be
  // subtracted from another wall clock nobody wrote down.
  recMark(data) {
    if (!this.rec || !this.recBase) return;
    let line;
    try {
      line = yamlDoc(Object.assign(
        { at: Date.now() - this.recAt, iso: new Date().toISOString() },
        data || {}));
    } catch { return; }
    // One YAML document per mark, appended. A stream of records wants documents
    // rather than one growing list: appending to a list means rewriting it, and
    // a half-written list is unparseable where a half-written document is just
    // the last one missing.
    fs.appendFile(this.recBase + '.marks.yaml', line, (e) => {
      if (e) log('could not write a mark for', this.who + ':', e.message);
    });
  }

  // --- a named recording -----------------------------------------------------
  // A SECOND FILE written alongside the backup, not a cut taken out of it
  // afterwards. Cutting afterwards would mean seeking a webm that is still
  // being appended to and has no index yet - the same header problem recOpen
  // is careful about, arriving from the other end. Teeing costs one write and
  // yields a finished, playable file the moment it stops.
  //
  // The span is ALSO written into the backup's marks, so a recording survives
  // as a pair of offsets even if this file fails. Two records of the same fact,
  // because the cheap one is the one that still works when the other does not.
  cutStart(name, who) {
    if (!RECORD) return { ok: false, why: 'no recordings folder is configured' };
    // Nothing has carried the header past yet, so there is nothing a file could
    // begin with. Saying so is better than leaving an empty file that looks
    // like a recording until somebody tries to play it.
    if (!this.recHead) return { ok: false, why: 'no audio has arrived yet' };
    // Starting while one runs ENDS it and begins the next. Segments that meet
    // end to end are exactly what a change detector produces - one track stops
    // because the next started - and refusing would silently lose the second.
    if (this.cut) this.cutStop('a new recording started');

    const clean = String(name || '').trim().replace(/\s+/g, ' ').slice(0, 120);
    const slug = (clean.toLowerCase().replace(/[^a-z0-9]+/g, '-')
                       .replace(/^-+|-+$/g, '') || 'untitled').slice(0, 60);
    const d = new Date(), z = (n) => String(n).padStart(2, '0');
    const stamp = d.getUTCFullYear() + z(d.getUTCMonth() + 1) + z(d.getUTCDate()) +
                  '-' + z(d.getUTCHours()) + z(d.getUTCMinutes()) + z(d.getUTCSeconds());
    // Its own folder, so a listing answers "what did somebody mean to keep"
    // without having to know which filenames are backups.
    const dir = path.join(RECORD, 'named');
    try { fs.mkdirSync(dir, { recursive: true }); } catch {}
    const base = path.join(dir, slug + '-' + stamp);
    const cut = { name: clean || slug, slug, by: String(who || this.who || 'someone'),
                  base, at: Date.now(), bytes: 0, stream: null };
    try {
      cut.stream = fs.createWriteStream(base + '.webm');
      // Same rule as the backup, for the same reason: a file that goes wrong
      // must never reach the audio. Every path here logs and drops the file.
      cut.stream.on('error', (e) => {
        log('recording failed for', cut.slug + ':', e.message);
        if (this.cut === cut) this.cut = null;
      });
      cut.stream.write(this.recHead);
      cut.bytes += this.recHead.length;
    } catch (e) {
      log('cannot record', cut.slug + ':', e.message);
      return { ok: false, why: e.message };
    }
    this.cut = cut;
    this.recMark({ kind: 'rec-start', name: cut.name, slug: cut.slug, by: cut.by });
    log('recording started:', cut.name, '->', base + '.webm', 'asked by', cut.by);
    return { ok: true, name: cut.name, slug: cut.slug, file: path.basename(base) + '.webm' };
  }

  cutWrite(chunk) {
    const cut = this.cut;
    if (!cut || !cut.stream) return;
    try { cut.stream.write(chunk); cut.bytes += chunk.length; } catch {}
  }

  cutStop(why) {
    const cut = this.cut;
    if (!cut) return { ok: false, why: 'nothing is being recorded' };
    this.cut = null;
    const secs = (Date.now() - cut.at) / 1000;
    try { if (cut.stream) cut.stream.end(); } catch {}
    // A sidecar rather than a filename made to carry everything. `backup` and
    // `offset` are the useful half: they say which broadcast this came out of
    // and where in it, so the claim can be checked against the original.
    const meta = {
      name: cut.name, slug: cut.slug, by: cut.by,
      started: new Date(cut.at).toISOString(),
      ended: new Date().toISOString(),
      secs, bytes: cut.bytes,
      backup: this.recBase ? path.basename(this.recBase) + '.webm' : null,
      offset: this.recAt ? cut.at - this.recAt : null,
      why: why || 'stopped'
    };
    fs.writeFile(cut.base + '.yaml', yamlDoc(meta), (e) => {
      if (e) log('could not write the sidecar for', cut.slug + ':', e.message);
    });
    this.recMark({ kind: 'rec-stop', name: cut.name, slug: cut.slug, secs });
    log('recording stopped:', cut.name + ',', secs.toFixed(1) + 's,', cut.bytes,
        'bytes -', why || 'stopped');
    return { ok: true, name: cut.name, slug: cut.slug, secs,
             file: path.basename(cut.base) + '.webm' };
  }

  recClose() {
    // The named recording goes first. It is a span inside the broadcast, so it
    // cannot outlive it, and stopping it here is what gives a host who simply
    // went off the air a closed file with a sidecar rather than a stub.
    if (this.cut) this.cutStop('the broadcast ended');
    if (!this.rec) return;
    const r = this.rec;
    this.rec = null;
    try { r.end(); } catch {}
    log('recording closed:', this.recBase + '.webm');
  }

  // --- towards the harbor ---
  connect() {
    if (this.closed) return;
    this.attempt++;
    if (!this.firstTry) this.firstTry = Date.now();
    let auth;
    try {
      auth = Buffer.from(HARBOR_USER + ':' + harborPassword()).toString('base64');
    } catch (e) {
      return this.giveUp('cannot read the harbor password: ' + e.message);
    }
    const sock = net.connect(HARBOR_PORT, HARBOR_HOST);
    sock.setNoDelay(true);
    let head = '', settled = false;

    sock.on('connect', () => {
      // PUT with no Content-Length and no chunking: the icecast source
      // protocol is an HTTP request whose body simply never ends. `Expect:
      // 100-continue` is NOT sent - measured, the harbor answers
      // "HTTP/1.1 200 OK" straight away, and waiting for a 100 would be
      // waiting for something it does not send.
      sock.write(
        'PUT ' + HARBOR_MOUNT + ' HTTP/1.1\r\n' +
        'Host: ' + HARBOR_HOST + ':' + HARBOR_PORT + '\r\n' +
        'Authorization: Basic ' + auth + '\r\n' +
        'User-Agent: wnl-live-bridge\r\n' +
        'Content-Type: ' + this.mime + '\r\n' +
        'Ice-Name: ' + this.who + ' live from the console\r\n' +
        'Ice-Public: 0\r\n' +
        '\r\n');
    });

    sock.on('data', d => {
      if (settled) return;                      // once streaming, it says nothing
      head += d.toString('latin1');
      if (!/\r\n\r\n|\n\n/.test(head)) return;
      settled = true;
      const status = head.split(/\r?\n/)[0];
      if (/ 200 /.test(status)) return this.onAir(sock);
      sock.destroy();
      if (/ 403 /.test(status)) return this.maybeRetry('taken');
      if (/ 401 /.test(status)) {
        // Retrying will not fix a wrong password, and the harbor answers 401
        // for exactly one reason.
        return this.giveUp('the station refused the password the bridge sent');
      }
      return this.maybeRetry('refused', status);
    });

    sock.on('error', e => {
      if (settled && this.harbor === sock) return this.stop('the station dropped the source: ' + e.message);
      if (settled) return;
      settled = true;
      this.maybeRetry('unreachable', e.code || e.message);
    });
    sock.on('close', () => {
      if (this.harbor === sock && this.live) this.stop('the station closed the source');
    });
  }

  onAir(sock) {
    this.harbor = sock;
    this.live = true;
    this.startedAt = Date.now();
    clearTimeout(this.retryTimer); this.retryTimer = null;
    if (this.prerollBytes) {
      // Everything held while the mount was being waited for, in order, header
      // first. A client that waited for `ready` has none of this.
      log('flushing', this.prerollBytes, 'bytes held while waiting for the mount');
      // Recorded from HERE, not from the first live chunk. This is the audio
      // held while the mount was being granted, and it is where the webm header
      // is - a recording that started after it would be a file no decoder opens,
      // which is the same fault the comment above is being careful about.
      for (const c of this.preroll) {
        this.bytes += c.length;
        sock.write(c);
        this.recWrite(c);
      }
    }
    this.preroll = []; this.prerollBytes = 0;
    log('on air:', this.who, this.mime + ',', 'after', this.attempt, 'attempt(s),',
        Date.now() - this.began, 'ms from the socket opening');
    this.say('ready', { waited: Date.now() - this.began, mime: this.mime });
    this.tallyTimer = setInterval(() => {
      this.say('tally', { bytes: this.bytes, secs: (Date.now() - this.startedAt) / 1000 });
    }, 2000);
  }

  maybeRetry(kind, detail) {
    if (this.closed) return;
    const waited = Date.now() - this.firstTry;
    if (waited < RETRY_FOR_MS) {
      this.say('waiting', {
        kind, attempt: this.attempt, waited,
        // The honest reading of an early 403: it is almost always this same
        // host's own last broadcast still being let go of.
        why: kind === 'taken'
          ? 'the station is still letting go of the last broadcast'
          : kind === 'unreachable'
            ? 'the station is not answering'
            : 'the station said ' + (detail || 'no')
      });
      this.retryTimer = setTimeout(() => this.connect(), RETRY_EVERY_MS);
      return;
    }
    if (kind === 'taken') {
      return this.giveUp('somebody else is on /live. Only one source can hold it - ' +
                         'if that is butt or a phone, stop it there first.');
    }
    if (kind === 'unreachable') {
      return this.giveUp('the station is not answering on the harbor (' + (detail || '') + ')');
    }
    return this.giveUp('the station refused the source: ' + (detail || ''));
  }

  giveUp(why) {
    log('giving up for', this.who + ':', why);
    this.say('error', { why });
    this.stop(why, true);
  }

  stop(why, quiet) {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.retryTimer);
    clearTimeout(this.helloTimer);
    clearInterval(this.tallyTimer);
    clearInterval(this.pingTimer);
    const secs = this.startedAt ? (Date.now() - this.startedAt) / 1000 : 0;
    if (this.live) log('off air:', this.who + ',', secs.toFixed(1) + 's,', this.bytes, 'bytes,', why);
    else if (!quiet) log('closed before going on air:', this.who + ',', why);
    this.live = false;
    this.recClose();
    if (this.harbor) {
      // end(), not destroy(). Measured: the harbor releases the mount five
      // seconds after the last BYTE either way - a half-close and a reset are
      // indistinguishable to it - so this picks the polite one. Those five
      // seconds are radio.liq's `timeout` and are not a fault to be fixed.
      const h = this.harbor;
      try { h.end(); } catch {}
      setTimeout(() => { try { h.destroy(); } catch {} }, 6000);
      this.harbor = null;
    }
    try { this.ws.end(frame(0x8, Buffer.from([0x03, 0xe8]))); } catch {}
    setTimeout(() => { try { this.ws.destroy(); } catch {} }, 500);
    if (current === this) current = null;
  }
}

// --- the front door --------------------------------------------------------
const server = http.createServer((req, res) => {
  const reply = (code, body) => {
    res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(body));
  };

  // The path as it arrives, which is two spellings of the same place: caddy
  // proxies /host/onair without stripping it, and this port is also reachable
  // directly on loopback for a script or a check from a shell. Both have to
  // mean the same thing, so the prefix comes off here rather than being
  // required of every caller.
  let p;
  try { p = new URL(req.url, 'http://bridge').pathname; } catch { p = '/'; }
  p = (p.replace(/^\/host\/onair/, '').replace(/\/+$/, '')) || '/';

  // What is on the air, what it is leaving behind, and whether any of it is
  // being kept on purpose. `backup` and `recording` are separate fields because
  // they are separate things: there is always a backup while somebody is on,
  // and a recording only when somebody asked for one.
  const state = () => current
    ? { onair: current.live, who: current.who, mime: current.mime,
        secs: current.startedAt ? (Date.now() - current.startedAt) / 1000 : 0,
        bytes: current.bytes,
        backup: current.recBase ? path.basename(current.recBase) + '.webm' : null,
        recording: current.cut
          ? { name: current.cut.name, slug: current.cut.slug, by: current.cut.by,
              secs: (Date.now() - current.cut.at) / 1000 }
          : null }
    : { onair: false, backup: null, recording: null };

  if (p === '/rec/start' || p === '/rec/stop') {
    if (req.method !== 'POST') return reply(405, { ok: false, why: 'POST to this' });
    // Whoever caddy decided this is. A console with a button, a script, the
    // thing watching the shared tab - they arrive the same way, are named the
    // same way, and the name lands in the sidecar. Nothing here authenticates
    // anybody; that is why it listens on loopback only.
    const who = (req.headers['x-host-user'] || '').replace(/[^A-Za-z0-9._-]/g, '').slice(0, 40);
    let body = '';
    req.on('data', d => {
      body += d;
      // A name, not a payload. Anything bigger is a mistake or a probe.
      if (body.length > 4096) { body = ''; req.destroy(); }
    });
    req.on('end', () => {
      if (!current || !current.live) {
        return reply(409, { ok: false, why: 'nobody is on the air', state: state() });
      }
      let name = '';
      try { name = new URL(req.url, 'http://bridge').searchParams.get('name') || ''; } catch {}
      if (!name && body) {
        // JSON if it parses, otherwise the body itself - so `curl -d "a name"`
        // works as well as a console posting a field.
        try { name = (JSON.parse(body) || {}).name || ''; } catch { name = body.slice(0, 200); }
      }
      const r = p === '/rec/start'
        ? current.cutStart(name, who)
        : current.cutStop('asked by ' + (who || 'someone'));
      reply(r.ok ? 200 : 409, Object.assign({}, r, { state: state() }));
    });
    return;
  }

  // Anything else is the state, which is all this port answered before there
  // was anything to ask it for.
  reply(200, state());
});

server.on('upgrade', (req, sock, head) => {
  const key = req.headers['sec-websocket-key'];
  if ((req.headers.upgrade || '').toLowerCase() !== 'websocket' || !key) {
    const text = 'this is a webcast websocket';
    sock.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: ' +
               Buffer.byteLength(text) + '\r\nContent-Type: text/plain\r\n\r\n' + text);
    return sock.destroy();
  }
  // The subprotocol must be echoed or a browser fails the connection itself.
  // savonet's name for it, because this speaks savonet's protocol: anything
  // that already talks webcast - webcaster, and liquidsoap's own harbor -
  // points at this unchanged.
  const offered = (req.headers['sec-websocket-protocol'] || '')
    .split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
  if (offered.length && !offered.includes('webcast')) {
    const text = 'this port speaks the webcast subprotocol';
    sock.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: ' +
               Buffer.byteLength(text) + '\r\nContent-Type: text/plain\r\n\r\n' + text);
    return sock.destroy();
  }

  // Caddy has already decided who this is - basic auth in the `speakers`
  // realm - and passes the name through. Nothing here authenticates anybody;
  // that is the whole reason it listens on loopback only.
  const who = (req.headers['x-host-user'] || '').replace(/[^A-Za-z0-9._-]/g, '').slice(0, 40) || 'a host';

  sock.setNoDelay(true);
  sock.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    (offered.includes('webcast') ? 'Sec-WebSocket-Protocol: webcast\r\n' : '') +
    // Sec-WebSocket-Extensions is deliberately NOT echoed, so permessage-
    // deflate is never negotiated. Compressing opus would cost cpu to make it
    // very slightly larger, and it would put an inflate in the audio path.
    'Sec-WebSocket-Accept: ' + accept(key) + '\r\n\r\n');

  if (current && !current.closed) {
    // The mount holds one. Say so by name here rather than letting the station
    // answer 403 to a page that cannot explain it.
    const air = new Air(sock, who);
    air.say('error', { why: current.who + ' is already on the air from a console.' });
    air.stop('a second console arrived', true);
    return;
  }

  const air = new Air(sock, who);
  current = air;
  log('console connected:', who);
  if (head && head.length) air.onData(head);
});

server.listen(PORT, HOST, () => log('live bridge listening on ' + HOST + ':' + PORT));
server.on('error', e => { log('server error', e.message); process.exit(1); });

process.on('uncaughtException', e => {
  // Never take the microphone down for something that was not in the audio
  // path. The task restarts this if it really does die.
  log('uncaught', e && e.stack ? e.stack : String(e));
});
