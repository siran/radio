# Wild n Loyal Radio — driving a show as a program

A self-contained reference. Assumes no prior knowledge of this station.

**What it is.** An internet radio. A `liquidsoap` process holds everything that is
*now* — what is playing, who is live, the show — and answers HTTP on a handful of
endpoints. Files on disk hold everything that is *then*. A `caddy` in front does
routing and credentials. There is no application server and no database.

**What you are.** A *speaker*: a named credential. Everything below is done with
ordinary HTTP as that speaker. The station never calls you; you call it.

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

### Or over HTTP, with an admin credential

There is an endpoint, and it is **not** the speaker credential — it is a separate
`admins` login:

```
PUT /adminapi/req/<anything>.json      {"action":"add","name":"ai"}
                                       ("password" optional; omitted = generated)
GET /adminapi/res/<same name>.json     a few seconds later
    → {"ok":true,"name":"ai","password":"…"}
```

A watcher outside the request path does the work and writes the answer back. The
result carries a password in plain text and is **deleted within minutes**, so read
it promptly. Other actions on that folder: `disable`, `enable`, `remove`.

**This is a larger grant than it looks and an AI DJ does not need it.** Whoever
holds the admin credential can mint credentials, disable other speakers and
restart the station. Nothing else in this document requires it. The intended
shape is: **a human mints once and hands over only the speaker password.** Ask
for that rather than for admin.

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

There are **two** of these and they are not the same thing.

### 7.1 The backup — automatic, nobody asks for it

Going live starts it. One file per broadcast, written to `recordings/` (or
`$env:RADIO_RECORD`), named after the clock and the speaker:

```
20260818-211802-ai.webm     one continuous file, header intact
20260818-211802-ai.marks.yaml   one YAML document per mark, --- separated
```

**One file per broadcast, not one per track** — a webm header exists only in the
first blob, so a stream cut at a boundary is bytes no decoder opens. `at` is
milliseconds from the first byte of the recording. Cut by time with `ffmpeg`;
never cut the stream.

This is insurance. It needs no decision from you and you cannot turn it off.

### 7.2 A named recording — deliberate, and yours to trigger

**Going live does not mean "recording".** A recording is a stretch somebody
meant to keep, and it carries a name, because "tonight's show" and "that track
that just played" are different objects and only one of them can be asked for
later by name.

```
POST /host/onair/rec/start?name=Ossanha%20-%20Baden%20Powell
POST /host/onair/rec/stop
GET  /host/onair                     → what is on air, and what is being kept
```

Speaker credential, same as everything else here. The name may also be sent as
a JSON body `{"name":"…"}` or as the raw body.

```jsonc
// 200 from /rec/start
{ "ok": true, "name": "Ossanha - Baden Powell",
  "slug": "ossanha-baden-powell",
  "file": "ossanha-baden-powell-20260823-172410.webm",
  "state": { "onair": true, "who": "ai",
             "backup": "20260823-172410-ai.webm",
             "recording": { "name": "…", "by": "ai", "secs": 0.1 } } }
```

Lands in `recordings/named/` as a **playable file plus a sidecar**:

```jsonc
{ "name": "Ossanha - Baden Powell", "slug": "…", "by": "ai",
  "started": "2026-08-23T17:24:10.451Z", "ended": "…", "secs": 214.6,
  "backup": "20260823-172410-ai.webm",   // which broadcast it came out of
  "offset": 261                          // and where in it, in ms
}
```

`backup` and `offset` are the useful half: they let anything check the named
file against the original rather than take its word for it.

Four things worth knowing before you drive this:

- **Starting while one runs ends it and starts the next.** That is deliberate:
  segments that meet end to end are exactly what a change detector produces —
  one track stops because the next began — and refusing would silently lose the
  second one. So on a detected track change, just POST `start` again.
- **It is a second file written alongside, not a cut made afterwards.** It is
  finished and playable the moment you stop it; there is nothing to extract.
- `409 "nobody is on the air"` means what it says. `409 "no audio has arrived
  yet"` means the header has not gone past yet — wait a moment and retry.
- Going off the air closes any named recording with `why: "the broadcast ended"`,
  so a show that drops does not leave a stub.

The span is **also** written into the backup's `.marks.yaml` as `rec-start` /
`rec-stop` marks. Two records of the same fact, because the cheap one still
works when the other does not.

### On formats

Files this station writes for **you** are YAML: the recording marks, the
sidecars, the noticeboard. Files liquidsoap reads back are still JSON, and that
is a tool constraint rather than a preference - the build has `yaml.stringify`
but no `yaml.parse`, so anything the station must read again has to stay JSON.

HTTP responses are JSON throughout. Those are an API, not a file.

There is **no Whisper on this machine** as of 2026-08-19.

---

## 8 · The host's instructions

```
GET /host/ai/ai.yaml      (speaker auth)
PUT /host/ai/ai.yaml      max 8KB
```

```yaml
auto_post: false      # write cards on its own
auto_tag: false       # set artist and title on the live show, which the room sees
auto_record: false    # start and stop named recordings
auto_music: false     # queue and skip
prompt: "who you are, what to notice, how long to be"
at: "2026-08-24T18:00:00Z"   # written by the console, not by you
by: "an"                      # who last changed it
```

- `prompt` — what the host wants. Written by a human in the console.
- **The four `auto_*` flags** are separate permissions, all `false` by default.
  Honour each one on its own: `auto_post` is not permission to retitle the show,
  and `auto_tag` is the one the whole room sees - a wrong title sits on the
  public page until a person notices. Anything not granted you may still prepare
  and leave for the host.

The single `auto` flag this replaced asked one question where there were four.
Writing a card signed with your name, renaming what the whole room can see,
cutting a recording and choosing the next record are four different amounts of
trust, and a host will grant one while refusing another.

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
| `GET/PUT` | `/host/ai/ai.yaml` | the host's instructions, and four permissions |
| `WSS` | `/host/onair` | the audio in, subprotocol `webcast` |
| `POST` | `/host/onair/rec/start?name=` | begin a NAMED recording |
| `POST` | `/host/onair/rec/stop` | end it, write its sidecar |
| `GET` | `/host/onair` | who is on, the backup, what is being kept |
