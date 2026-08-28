# Wild n Loyal Radio — driving a show as a program

A self-contained reference. Assumes no prior knowledge of this station.

**Where this lives.** The copy that counts is `AI-DJ.md` in the station repo
(`$env:RADIO_HOMEAI-DJ.md`, and `radio/AI-DJ.md` in git). Anything under an
agent's `identity.d/` is a COPY, refreshed from that one. If two disagree, the
repo is right and the copy is stale.

**What it is.** An internet radio. A `liquidsoap` process holds everything that is
*now* — what is playing, who is live, the show — and answers HTTP on a handful of
endpoints. Files on disk hold everything that is *then*. A `caddy` in front does
routing and credentials. There is no application server and no database.

**What you are.** A *speaker*: a named credential. Everything below is done with
ordinary HTTP as that speaker. The station never calls you; you call it.

**What is NOT here any more (2026-08-28).** There was a tab watcher that read a
host's shared tab, split it into moving and still parts, and handed frames to
`/host/read/` for something to identify. There was an `ai.yaml` noticeboard of
permissions. Both are gone, along with their routes — nothing was ever on the
other end of them, and a DJ that can read a tab's DOM gets the title exactly,
instantly, as text, with no crop, no OCR and no threshold. If you find those
paths in an older copy of this document, they will 404.

**Base URL.** `https://radio.wildnloyal.org` (also plain `http://`). One host, all
paths below.

**Auth.** HTTP Basic, on every `/host/*` and `/control/*` path. `/likes/now`,
`/control/now`, `/earlier`, `/posts/*`, `/stream` and `/shows/` are public.

**Marking.** **(measured)** = verified on this machine. **(untested)** = believed,
not proven — check it first.

---

## 1 · Getting a credential

On the machine (`C:\Users\an\src\radio`):

```powershell
.\mint-speaker.ps1 -Name ai                     # prints a password
.\mint-speaker.ps1 -Name ai -Password "chosen"
.\mint-speaker.ps1 -Name ai -Remove
```

The name is the identity everywhere: the folder uploads land in, and **the
signature on every card posted with it**. A card written by `ai` displays `— ai`
and no instruction can make it claim otherwise.

---

## 2 · Reading the station

All public, no auth.

### `GET /likes/now`
```json
{ "id": "3d47…", "likes": 0, "skips": 0, "total": 24, "pull": 0, "rope": 12,
  "cool": 6.75, "elapsed": 380.1, "duration": 660.5, "paused": false,
  "air_delay": 1.75, "record_min": 0.0,
  "show": { "live": false, "name": "", "title": "", "artist": "", "note": "",
            "id": "songs/kenny-dorham-my-ideal", "posts": "" } }
```

- `id` — the current track. Changes on every track.
- `elapsed` / `duration` — seconds, as the *station* sees them. A listener hears
  roughly `air_delay + 4.1s burst + their own buffering` later.
- `show.live` — is a source connected.
- **`show.id` — the folder posts go into. Read it; never invent it.** The station
  mints it: `<show-slug>/<yyyymmdd-hhmmss>` while somebody is live,
  `songs/<artist-title>` between shows, changing with the record.
- `show.posts` — what is currently on the radio: `"1:1,2:3"` = post 1 revision 1,
  post 2 revision 3.

### `GET /control/now`
```json
{ "path": "D:\\Music\\…m4a", "title": "Definitive", "artist": "Company Flow",
  "music": true, "paused": false, "repeat": false }
```

### `GET /earlier`
Array of what has happened, newest last. Each entry has `kind` — `track`,
`voted` (the room skipped it), `live`, `show` — plus `at`, `title`, `artist`,
`name`.

### `GET /stream`
The audio, as MP3. Listen to it like any listener.

---

## 3 · Programming the music

Speaker auth. This needs **no browser and no audio pipeline**. If the goal is an
AI-programmed hour rather than broadcasting a web page, this section is the
entire feature.

```
GET  /control/search?q=miles
```
```json
{ "query": "miles", "total": 30, "limit": 50,
  "results": [ { "id": "683b8d…", "title": "Changes (Live At The Fillmore East)",
                 "artist": "Buddy Miles", "match": "artist" } ] }
```

```
POST /control/enqueue?id=<id>&now=true    # now=true plays it next
GET  /control/queue                        → {"error":"","total":0,"queue":[]}
POST /control/queue/add?id=<id>
POST /control/queue/remove?id=<id>
POST /control/queue/move?id=<id>&to=<n>
POST /control/queue/clear
POST /control/skip
POST /control/previous
POST /control/again
POST /control/repeat?on=true|false
POST /control/music?on=true|false
POST /control/pause?on=true|false
```

`id` is the opaque id from `search`.

---

## 4 · The show record

```
GET  /control/show
POST /control/show?name=…&title=…&artist=…&note=…&slug=…&posts=…
```

**One call carries the whole show.** A parameter left out means an empty field,
not an unchanged one — so `GET` first and send everything back with your change
in it. A `POST` with no parameters clears the show.

| field | |
|---|---|
| `name` | the show's name — the headline on the site |
| `title` / `artist` | what is going out right now; the page shows `Artist - Title` |
| `note` | a subtitle line under the name |
| `slug` | an *offer* for the folder name, `^[a-z0-9][a-z0-9-]{0,47}$` |
| `posts` | what is on the radio: `n:rev` pairs, comma separated |

`slug` is validated and refused if it does not fit, falling back to the station's
own. **Fold accents yourself** — the station's fallback turns `Óscar D'León` into
`oscar-d-le-n`. The folder may still change while it is empty and is fixed the
moment something is written into it.

`posts` accepts digits, colons and commas only, and is refused **whole**
otherwise — it becomes a URL in every listener's browser.

---

## 5 · Posting a card

A card is a fragment of HTML in a `.md` file. It appears on the radio while the
show or the song lasts, and stays on disk for the archive at `/shows/`.

### Order — always

```
1.  PUT  /host/post/<show.id>/<id>-1.png     each picture, if any
2.  PUT  /host/post/<show.id>/<id>.md        the markup naming them
3.  POST /control/show?…&posts=<id>:1        announce it
```

Reversed, the station advertises a card whose file 404s on every radio in the
room. Encode each path segment separately — `show.id` contains a `/`.

### Choosing `<id>`

- **During a show** (`show.id` has no `songs/` prefix) — the next integer: `1`, `2`.
- **Off the air** (`show.id` starts `songs/`) — a **12-digit UTC stamp**,
  `yyMMddHHmmss`. It must be: the list is emptied on every track change, so `1.md`
  would overwrite whatever was written about that track last time.

### The file

```html
<!-- posted 2026-08-19T01:12:04.000Z rev 1 by ai -->
<p>Recorded live in 1969. <a href="https://example.org/x">the source</a></p>
<img src="/posts/songs/foo/260819011204-1.png" alt="the sleeve">
```

The header comment is read and consumed, never shown. **`rev` must increase when
you replace a card** or nothing refetches it.

### What survives the reader

Every reader re-sanitises with an allow-list. Anything else is dropped, or
unwrapped keeping its text.

- **tags** — `p br h1 h2 h3 strong em u a ul ol li img blockquote code pre hr`
  (`b`→`strong`, `i`→`em`, `h4`–`h6`→`h3`)
- **attributes** — `href`, `title` on links; `src`, `alt`, `title` on images
- **URLs** — `https?://…`, a same-origin path starting `/` (not `//`), or
  `data:image/(png|jpeg|gif|webp);base64,…`
- **gone** — `style`, `class`, every `on*`, `script`, `iframe`, `svg`, `form`,
  and comments

### Limits

- **extensions** — `.md .png .jpg .jpeg .webp .gif` only; `.html` is refused
- **size** — the route caps a body at 4MB and **truncates rather than refusing
  (measured)**. Over the cap you write half a file and nothing tells you. Stay
  under ~3MB.
- rate — 60 writes/minute per host

Removing a card is a `posts` list without it. The file stays.

---

## 6 · Broadcasting a web page

Only this section needs a browser. Skip it entirely for section 3.

### 6.1 The flag that costs an evening

**`--mute-audio` silences tab capture (measured).**

```
WITH --mute-audio     RMS 0.0000    silent
WITHOUT (control)     RMS 0.2485    carries the audio
```

Everything else looks correct — encoder running, mount held, bytes flowing — and
there is nothing in them, with no error anywhere.

Run the DJ browser **unmuted** and stay quiet with `suppressLocalAudioPlayback`
instead: granted in the same measurement, with the audio still arriving. That
covers the **shared tab only** — anything else playing in that browser reaches the
machine's speakers, so put research in a second, muted instance.

### 6.2 Launch flags

```
--auto-accept-this-tab-capture
--autoplay-policy=no-user-gesture-required
                                   ← and NOT --mute-audio
```

### 6.3 Capture

```js
const st = await navigator.mediaDevices.getDisplayMedia({
  video: { displaySurface: 'browser' },
  audio: { echoCancellation: false, noiseSuppression: false,
           autoGainControl: false, suppressLocalAudioPlayback: true },
  preferCurrentTab: true,
  systemAudio: 'exclude', monitorTypeSurfaces: 'exclude',
  selfBrowserSurface: 'exclude', surfaceSwitching: 'include'
});
// Refuse anything that is not a tab: read it BEFORE stopping the video track.
const surface = st.getVideoTracks()[0].getSettings().displaySurface;
if (surface && surface !== 'browser') { /* stop everything; a window or screen
   share carries only the system mix, which is the whole machine on the air */ }
```

`systemAudio: 'exclude'` is honoured for screens but **not for windows
(measured)** — the refusal above is what actually closes that door.

### 6.4 Encode and send

```
wss://radio.wildnloyal.org/host/onair      subprotocol: webcast, speaker auth
```

Port 8007 is loopback and **authenticates nobody** — reach it only through that
path.

1. **First frame, text:**
   `{"type":"hello","data":{"mime":"audio/webm","audio":{"channels":1,"samplerate":48000,"bitrate":96,"encoder":"opus"}}}`
   Any credentials inside are ignored; the proxy already decided who you are.
2. **Then binary blobs** from `MediaRecorder` (`audio/webm;codecs=opus`).
   **The first blob carries the whole webm header and no later blob ever will** —
   never drop it, never start midway.
3. You may send before `{"type":"ready"}` arrives; audio is held and flushed when
   the mount is granted.

Replies are text: `waiting`, `ready`, `tally`, `warn`, `error`. Only one source
can hold the mount; a second gets a close with the reason.

### 6.5 Marking tracks

When what is going out changes:

```json
{"type":"metadata","data":{"artist":"…","title":"…","show":"…"}}
```

Not forwarded to the station — the station takes titles from the file it plays.
It is written beside the recording as a boundary. Send only on an actual change.

### 6.6 Leaving

Close the socket. The show clears, cards leave the page, files stay, and the
mount frees about five seconds after the last byte.

---

## 7 · Recordings

Every broadcast is written automatically to `recordings/` (or `$env:RADIO_RECORD`):

```
20260818-211802-ai.webm        one continuous file, header intact
20260818-211802-ai.marks.yaml  one YAML document per mark, appended
```

A mark is a document, not a line in a list:

```yaml
---
at: 711
iso: "2026-08-18T21:18:02.711Z"
artist: "…"
title: "…"
show: "…"
```

Documents rather than one growing list, deliberately: appending to a list means
rewriting it, and a half-written list is unparseable where a half-written
document is only the last one missing. Read it by splitting on `---`.

**One file per broadcast, not one per track** — a webm header exists only in the
first blob, so a stream cut at a boundary is bytes no decoder opens. `at` is
milliseconds from the first byte of the recording. Cut by time with `ffmpeg`;
never cut the stream.

**They have a duration (measured 2026-08-28).** A webm that MediaRecorder wrote
and the host cut off has none — the length is written at the *end* of a normal
file and this one never had an end written, so `ffprobe` says `duration=N/A`, a
browser plays it but shows no scrubber, and some players refuse it. The station
now runs a stream copy when a recording stops, which rewrites the header and
re-encodes nothing. All thirty files that predate that were given one the same
way. If you meet one without a duration, `ffmpeg -i in.webm -c copy out.webm`
is the whole fix.

A *named* recording (one the host started deliberately) is written as a second
file alongside the backup, with its own `.yaml` sidecar rather than a filename
made to carry everything:

```yaml
name: "…"      slug: "…"       by: "…"
started: "…"   ended: "…"      secs: 0    bytes: 0
backup: "20260818-211802-ai.webm"    offset: 0    why: "stopped"
```

`backup` and `offset` are the useful half: they say which broadcast this came
out of, and where in it.

### Listing them

```
GET /host/recordings/          (speaker auth) — a browsable index
```

`Accept: application/json` should get JSON back instead of the HTML listing —
that is Caddy's `file_server browse` behaviour, **(untested here)**.

### Transcription

A `whisper-server` **is** running on this machine, listening on
`127.0.0.1:8089` **(measured 2026-08-25)**. That corrects the older note here
saying there was none. It is loopback-only, so it is reachable from a process on
the machine and from nowhere else, and **nothing in the radio calls it yet
(measured)** — no route proxies to it and no recording is transcribed
automatically. Treat it as available hardware, not as a feature.

---

## 8 · Getting a voice onto the beat

Asked often enough by the operator to belong here. It matters to you because
two of the three steps are settings you can read and set over HTTP, and because
a host who sounds late is usually looking at the wrong control.

The arithmetic is one line:

> how late a host lands = their monitor lag + their voice's trip to the station
> − `air_delay`

So there are three steps, in this order:

1. **Set `air_delay` past what is needed** — a second or two — on the mixing
   desk. It holds the music back for *every listener*, and **takes effect at the
   next restart**: it is the one desk control that is not live. Every other one
   is `interactive.float` and reaches the air the moment it moves.
2. **Go on air and talk over a beat.** The host should now land EARLY, ahead of
   the beat they aimed at. That is the point of overshooting.
3. **Raise `sync` in the console's monitor** until they sit on it. That is
   headphones only, it moves the moment it is let go, and nothing about the air
   changes.

**Overshoot deliberately, because `sync` can only ADD delay.** A host who lands
late has nothing to spend and must go back to step 1 — and step 1 costs a
restart, which is why it is worth getting past on the first try.

`air_delay` is readable in `GET /likes/now` and settable on the desk. Its cost
is real and shared: every listener waits that much longer, so it is not a knob
to leave high for a station nobody talks on. `0.0` is the default and means the
station holds nothing back.

---

## 9 · Rules that are not style

1. **Everything that can fail happens before anything that commits.** Pictures
   before markup, file before list, read before write-back. Every bug in this
   system that reached a listener came from breaking this.
2. **The station owns identity.** `show.id`, the track id, the slug decision. Read
   them; do not compute them.
3. **A caller cannot silence a listener.** Nothing here mutes, pauses or skips on
   a listener's behalf except the controls in section 3, which are the room's.
4. **Attribution is structural.** A card is signed with whoever wrote the file.
   Content follows the prompt; the name does not.

---

## Quick reference

| | | |
|---|---|---|
| `GET` | `/likes/now` | state + show record — public |
| `GET` | `/control/now` | current track — public |
| `GET` | `/earlier` | history — public |
| `GET` | `/stream` | audio — public |
| `GET` | `/control/search?q=` | search the library |
| `POST` | `/control/enqueue?id=&now=` | queue a track |
| `GET/POST` | `/control/queue[/add\|remove\|move\|clear]` | the queue |
| `POST` | `/control/skip` `/previous` `/again` | move the needle |
| `POST` | `/control/pause?on=` `/music?on=` `/repeat?on=` | switches |
| `GET/POST` | `/control/show` | the show record |
| `PUT` | `/host/post/<show.id>/<file>` | a card or its pictures |
| `GET` | `/posts/<show.id>/<file>` | read one back — public |
| `GET` | `/host/recordings/` | browse the recordings |
| `POST` | `/control/voice/flush` | drop the voice notes queued to air |
| `WSS` | `/host/onair` | the audio in, subprotocol `webcast` |
