# Driving a show as the AI

Everything an automated DJ needs already exists. Nothing in this document asks
for a feature to be built; it is a description of doors that are already open.

The one idea underneath all of it: **the AI is a speaker that calls the station.**
The station never calls out. There is no key here, no webhook, no integration —
just a credential and the same endpoints a human host uses.

Marked throughout:

- **(measured)** — verified on this machine, with the numbers in git history.
- **(untested)** — believed, not proven. Treat as the first thing to check.

---

## 1. Get a credential

```powershell
cd C:\Users\an\src\radio
.\mint-speaker.ps1 -Name ai
```

The name becomes the identity for everything that follows: the folder uploads
land in, the `X-Host-User` the bridge sees, and **the name every post is signed
with**. A card written by this credential says `— ai` on the radio, and no prompt
can make it claim otherwise. That is deliberate: content comes from the prompt,
attribution from who wrote the file.

Use it as HTTP Basic auth on every `/host/*` and `/control/*` request below.

---

## 2. Read the noticeboard before doing anything

```
GET https://radio.wildnloyal.org/host/ai/ai.json     (speaker auth)
```

```json
{ "auto": false, "prompt": "…", "at": "2026-08-19T…", "by": "an" }
```

- `prompt` — what the host wants this AI to be. Written in the console's **The
  AI** panel.
- `auto` — **whether it may post without a human.** `false` means prepare
  something and leave it; `true` means post.

`auto` is off by default and is the one setting in this station that is about
somebody else's judgement. Honour it. If it is false and there is something worth
saying, the correct behaviour is to hold it, not to post it quietly.

---

## 3. Know what is on, without asking anyone

All public, no credential:

| | |
|---|---|
| `GET /likes/now` | the whole live state: track id, likes, skips, `paused`, `air_delay`, and the `show` record |
| `GET /control/now` | what is playing, in more detail |
| `GET /earlier` | what has played, what the room voted off, who went live |
| `GET /stream` | the audio itself — listen to it like anyone else |

`show` looks like:

```json
{ "live": false, "name": "", "title": "", "artist": "", "note": "",
  "id": "songs/kenny-dorham-my-ideal", "posts": "" }
```

**`show.id` is the folder posts go into, and it is not yours to choose.** The
station mints it: `<show-slug>/<when>` while somebody is live, `songs/<track>`
between shows. It changes when the record changes. Read it; never invent it.

---

## 4. DJ the library — available now, nothing to build

Behind speaker auth, all on `https://radio.wildnloyal.org`:

```
GET  /control/search?q=miles
POST /control/enqueue?id=<id>&now=true      # true = play it next
GET  /control/queue
POST /control/queue/add?id=<id>
POST /control/queue/remove?id=<id>
POST /control/queue/move?id=<id>&to=<n>
POST /control/queue/clear
POST /control/skip
POST /control/previous
POST /control/pause?on=true|false
```

Search, build a set, run it. This needs no browser and no audio pipeline at all.
**If the goal is an AI-programmed radio hour rather than a bucket set, stop here —
step 4 is the whole feature.**

---

## 5. Name the show

```
POST /control/show?name=…&title=…&artist=…&note=…&slug=…&posts=…
```

One call carries the **whole** show; a parameter left out means an empty field,
not an unchanged one. So read the current record first and send it back with your
change in it.

- `name` — the show. `title` / `artist` — what is going out right now.
  `note` — a subtitle line.
- `slug` — an offer for the folder name, `^[a-z0-9][a-z0-9-]{0,47}$`. The station
  validates it and falls back to its own if it does not fit. **Fold accents
  before sending** — the station's fallback cannot, so `Óscar D'León` becomes
  `oscar-d-le-n` if you leave it to do the work.
- `posts` — the list of what is on the radio, `n:rev,n:rev`. Digits, colons and
  commas only; anything else is refused **whole**.

The folder can still move while it is empty, and is fixed the moment something is
written into it.

---

## 6. Post a card

Two writes and one announcement, **in this order, always**:

```
1.  PUT /host/post/<show.id>/<id>-1.png     each picture, if any
2.  PUT /host/post/<show.id>/<id>.md        the markup that names them
3.  POST /control/show?…&posts=<id>:1       tell the station it exists
```

Reversed, listeners fetch a file that is not there yet — the station would be
advertising a card whose picture 404s on every radio in the room.

**Choosing `<id>`:**

- during a show (`show.id` has no `songs/` prefix) — the next integer: 1, 2, 3.
- off the air (`show.id` starts `songs/`) — a **12-digit UTC stamp**,
  `yyMMddHHmmss`. It must be, because the list is emptied every time the record
  changes, so `1.md` would overwrite the last thing anybody wrote about that
  track.

**The file:**

```html
<!-- posted 2026-08-19T01:12:04.000Z rev 1 by ai -->
<p>Recorded live in 1969. <a href="https://example.org/x">the source</a></p>
<img src="/posts/songs/foo/260819011204-1.png" alt="the sleeve">
```

The header comment is read and consumed, never displayed. `rev` must increase
when you replace a card, or nothing refetches it.

**What survives the reader's sanitiser** — everything else is dropped or
unwrapped, on the page and in the archive:

- tags: `p br h1 h2 h3 strong em u a ul ol li img blockquote code pre hr`
- attributes: `href` `title` on links; `src` `alt` `title` on images
- URLs: `https?://…`, a same-origin path starting `/`, or `data:image/(png|jpeg|gif|webp);base64,…`
- anything else — `style`, `class`, every `on*`, `script`, `iframe`, `svg` — is gone

Write inside those bounds and what you post is what appears.

**Extensions accepted:** `.md .png .jpg .jpeg .webp .gif` — nothing else, and a
`.html` will be refused. **Size:** the route caps a body at 4MB and **truncates
rather than refusing (measured)**, so stay under ~3MB per picture or you will
write a file that is silently half an image.

Taking a card down is a `posts` list without it. The file stays; that is the
archive at `/shows/`.

---

## 7. Go on air — the bucket set

This is the only part that needs a browser.

### 7.1 The flag that will cost you an evening

**`--mute-audio` silences tab capture (measured).**

```
WITH --mute-audio     RMS 0.0000    the capture is SILENT
WITHOUT it (control)  RMS 0.2485    the capture carries the tone
```

Launched with it, everything looks correct — the encoder runs, the mount is
held, bytes flow — and there is nothing in them. No error anywhere.

**So the DJ browser runs unmuted**, and stays quiet by asking for
`suppressLocalAudioPlayback` instead, which was granted in the same measurement
with the audio still arriving.

That only covers the **shared** tab. Anything else playing in that browser will
come out of the machine's speakers, so research belongs in a second,
`--mute-audio` instance.

### 7.2 Launch

```
--auto-accept-this-tab-capture         no picker for a self-capture
--autoplay-policy=no-user-gesture-required
                                       (and NOT --mute-audio)
```

### 7.3 Capture

```js
navigator.mediaDevices.getDisplayMedia({
  video: { displaySurface: 'browser' },
  audio: { echoCancellation: false, noiseSuppression: false,
           autoGainControl: false, suppressLocalAudioPlayback: true },
  preferCurrentTab: true,
  systemAudio: 'exclude', monitorTypeSurfaces: 'exclude'
})
```

Then **refuse anything that is not a tab** — read `displaySurface` off the video
track before stopping it. A window or screen share carries only the system mix,
which is the whole machine on the air.

### 7.4 Speak webcast

```
wss://radio.wildnloyal.org/host/onair       (speaker auth, subprotocol: webcast)
```

Port 8007 is loopback and **authenticates nobody** — it must only ever be reached
through that path.

1. First frame, text: `{"type":"hello","data":{"mime":"audio/webm","audio":{…}}}`
   Credentials in it are ignored on purpose; Caddy has already decided who you are.
2. Then binary blobs from `MediaRecorder`. **The first blob carries the whole webm
   header and no other blob ever will** — never drop it, never start midway.
3. Wait for `{"type":"ready"}`. Before that you may already send; audio is held
   and flushed when the mount is granted.

Only one source can hold `/live`. Another attempt gets a close with a reason.

### 7.5 Mark the tracks

When what is going out changes, send:

```json
{"type":"metadata","data":{"artist":"…","title":"…","show":"…"}}
```

It is **not** forwarded to the station — the station takes titles from the file
it plays. It is written beside the recording as a boundary. Send it only when it
actually changed.

**(untested)** Driving the *existing console page* instead of implementing the
above would reuse its EQ, gains, talkover and marks. The blocker is the picker;
`--auto-select-tab-capture-source-by-title` is the lever to try. Speaking webcast
directly is the proven path — it is how the recording was tested.

---

## 8. The recording writes itself

Every broadcast lands in `recordings/` (or `$env:RADIO_RECORD`):

```
20260818-211802-ai.webm     one continuous file, header intact
20260818-211802-ai.jsonl    {"at":711,"iso":"…","artist":"…","title":"…"}
```

One file per broadcast, **not one per track** — a webm header exists only in the
first blob, so a stream cut at a boundary is bytes no decoder opens. `at` is
milliseconds from the first byte. Cut by time with ffmpeg; never cut the stream.

This is the input for transcription. Note there is **no Whisper on this machine**
as of 2026-08-19 — that is a service still to add.

---

## 9. Leaving

Close the socket. The station clears the show, the cards leave the page, the
files stay, and the mount is released about five seconds after the last byte.

---

## The order that keeps being right

Everything that can fail happens before anything that commits.

Pictures before the markup that names them. The file before the list that
advertises it. Read the state before writing it back. It is the same rule every
time, and every bug in this system that reached a listener came from breaking it.
