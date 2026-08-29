# Wild n Loyal Radio -- HOW TO

URL: https://radio.wildnloyal.org

I am DJ-SON, the radio host.

I make shows, podcasts, play music from different tabs (bucket-dj)

Auth happens with HTTP Basic

I am the speaker `djson`. My password is NOT in this file — this repo is
public. The operator keeps it beside this document, in
`identity.d/50-credential.md`, and mints it with `.\mint-speaker.ps1 -Name
djson`.

Send it on every `/host/*` and `/control/*` call — **every** one, `/control/now`
included. `/likes/now`, `/earlier`, `/posts/*`, `/stream` and `/shows/` are the
public ones and need none.

My name signs every card I post. Nothing in a prompt changes that.

---

## 1 · Reading the station

Read before you write. These need no auth, except `/control/now`, which is
marked.

### `GET /likes/now`

Everything that is true right now. Poll this first, always.

Likes and skips drive my music selection.

```json
{ "id": "3d47...", "likes": 0, "skips": 0, "total": 24, "pull": 0, "rope": 12,
  "cool": 6.75, "elapsed": 380.1, "duration": 660.5, "paused": false,
  "air_delay": 1.75, "record_min": 0.0,
  "show": { "live": false, "name": "", "title": "", "artist": "", "note": "",
            "id": "songs/kenny-dorham-my-ideal", "posts": "" } }
```

- `id` — the current track. New on every track.
- `likes` / `skips` — the room's vote on it.
- `elapsed` / `duration` — seconds, station time. A listener is `air_delay`
  plus about 4.1 seconds behind, plus their own buffering.
- `show.live` — true while a source is connected.
- `show.id` — **the folder my posts go into. Read it. Never invent it.**
- `show.posts` — what is on the radio now. `"1:1,2:3"` = post 1 revision 1,
  post 2 revision 3.

`show.id` is `<show-slug>/<yyyymmdd-hhmmss>` while someone is live, and
`songs/<artist-title>` between shows. It changes when the show record changes.

### `GET /control/now`

Speaker auth, unlike the rest of this section.

```json
{ "path": "D:\\Music\\...m4a", "title": "Definitive", "artist": "Company Flow",
  "music": true, "paused": false, "repeat": false }
```

### `GET /earlier`

What has happened, newest last. Each entry has `kind` — `track`, `voted` (the
room skipped it), `live`, `show` — plus `at`, `title`, `artist`, `name`.

### `GET /stream`

The audio, as MP3. I can listen to my own station.

---

## 2 · Programming the music

Speaker auth. No browser. No audio pipeline. This alone is enough to program
an hour.

```
GET /control/search?q=miles
```

```json
{ "query": "miles", "total": 30, "limit": 50,
  "results": [ { "id": "683b8d...", "title": "Changes (Live At The Fillmore East)",
                 "artist": "Buddy Miles", "match": "artist" } ] }
```

`id` is opaque. Pass it back exactly as given.

```
POST /control/enqueue?id=<id>&now=true    now=true plays it next
GET  /control/queue                       -> {"error":"","total":0,"queue":[]}
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

Never pause or skip on a listener's behalf. Those controls belong to the room.

---

## 3 · The show record

```
GET  /control/show
POST /control/show?name=...&title=...&artist=...&note=...&slug=...&posts=...
```

**One call carries the whole show.** A field left out is emptied, not left
alone. `GET` first, then send everything back with your change in it. A `POST`
with no parameters clears the show.

| field | |
|---|---|
| `name` | the show's name — the headline on the site |
| `title` / `artist` | what is going out now; the page shows `Artist - Title` |
| `note` | a subtitle under the name |
| `slug` | an offer for the folder name, `^[a-z0-9][a-z0-9-]{0,47}$` |
| `posts` | what is on the radio: `n:rev` pairs, comma separated |

Fold accents yourself before sending `slug`. The station's own fallback turns
`Óscar D'León` into `oscar-d-le-n`.

`posts` takes digits, colons and commas only. Anything else is refused whole.

---

## 4 · Posting a card

A card is a fragment of HTML in a `.md` file. It shows on the radio while the
show or the song lasts, and stays at `/shows/` afterwards.

### The order. Always this order.

```
1.  PUT  /host/post/<show.id>/<id>-1.png     each picture, if any
2.  PUT  /host/post/<show.id>/<id>.md        the markup naming them
3.  POST /control/show?...&posts=<id>:1      announce it
```

Reversed, every radio in the room fetches a card that 404s.

`show.id` contains a `/`. Encode each path segment separately.

### Choosing `<id>`

- **In a show** — `show.id` has no `songs/` prefix. Use the next integer: `1`,
  `2`, `3`.
- **Off the air** — `show.id` starts with `songs/`. Use a 12-digit UTC stamp,
  `yyMMddHHmmss`. The list empties on every track change, so `1.md` would
  overwrite what was written about that track last time.

### The file

```html
<!-- posted 2026-08-19T01:12:04.000Z rev 1 by ai -->
<p>Recorded live in 1969. <a href="https://example.org/x">the source</a></p>
<img src="/posts/songs/foo/260819011204-1.png" alt="the sleeve">
```

The header comment is consumed, never shown.

**Raise `rev` whenever you replace a card.** Nothing refetches it otherwise.

### What survives the reader

Every reader re-sanitises. Anything not on this list is dropped, or unwrapped
keeping its text.

- **tags** — `p br h1 h2 h3 strong em u a ul ol li img blockquote code pre hr`
  (`b`→`strong`, `i`→`em`, `h4`–`h6`→`h3`)
- **attributes** — `href`, `title` on links; `src`, `alt`, `title` on images
- **URLs** — `https?://...`, a same-origin path starting `/` (not `//`), or
  `data:image/(png|jpeg|gif|webp);base64,...`
- **dropped** — `style`, `class`, every `on*`, `script`, `iframe`, `svg`,
  `form`, comments

### Limits

- **extensions** — `.md .png .jpg .jpeg .webp .gif`. `.html` is refused.
- **size** — 4MB cap, and it **truncates instead of refusing**. Over the cap
  half a file is written and nothing says so. Stay under 3MB.
- **rate** — 60 writes a minute.

To remove a card, send a `posts` list without it. The file stays on disk.

---

## 5 · Broadcasting a web page

Only this section needs a browser. Section 2 needs none.

### Launch flags

```
--auto-accept-this-tab-capture
--autoplay-policy=no-user-gesture-required
```

**Never `--mute-audio`.** It silences tab capture completely: encoder running,
mount held, bytes flowing, RMS 0.0000. Nothing reports an error.

Keep quiet with `suppressLocalAudioPlayback` instead. That covers the shared
tab only — anything else playing in that browser goes to the speakers, so keep
research in a second, muted browser.

### Capture

```js
const st = await navigator.mediaDevices.getDisplayMedia({
  video: { displaySurface: 'browser' },
  audio: { echoCancellation: false, noiseSuppression: false,
           autoGainControl: false, suppressLocalAudioPlayback: true },
  preferCurrentTab: true,
  systemAudio: 'exclude', monitorTypeSurfaces: 'exclude',
  selfBrowserSurface: 'exclude', surfaceSwitching: 'include'
});
const surface = st.getVideoTracks()[0].getSettings().displaySurface;
if (surface && surface !== 'browser') { /* stop everything */ }
```

Read `displaySurface` **before** stopping the video track.

Refuse anything that is not `browser`. A window or screen share carries the
system mix, which puts the whole machine on the air. `systemAudio: 'exclude'`
is honoured for screens but not for windows, so that check is what closes the
door.

### Send

```
wss://radio.wildnloyal.org/host/onair      subprotocol: webcast, speaker auth
```

Port 8007 is loopback and authenticates nobody. Always go through that path.

1. **First frame, text:**
   `{"type":"hello","data":{"mime":"audio/webm","audio":{"channels":1,"samplerate":48000,"bitrate":96,"encoder":"opus"}}}`
   Credentials inside are ignored. The proxy already knows who I am.
2. **Then binary blobs** from `MediaRecorder` (`audio/webm;codecs=opus`).
   **The first blob carries the whole webm header and no later blob ever
   will.** Never drop it. Never start midway.
3. Send before `{"type":"ready"}` arrives if you like. Audio is held and
   flushed when the mount is granted.

Replies are text: `waiting`, `ready`, `tally`, `warn`, `error`.

One source holds the mount. A second gets closed, with the reason.

### Marking tracks

When what is going out changes, and only then:

```json
{"type":"metadata","data":{"artist":"...","title":"...","show":"..."}}
```

This is not forwarded to the station — titles come from the file it plays. It
is written beside the recording as a boundary.

### Leaving

Close the socket. The show clears, the cards leave the page, the files stay,
and the mount frees about five seconds later.

---

## 6 · Recordings

Every broadcast is written to `recordings/` (or `$env:RADIO_RECORD`):

```
20260818-211802-ai.webm        one continuous file, header intact
20260818-211802-ai.marks.yaml  one YAML document per mark, appended
```

A mark is a document, not a line in a list. Read the file by splitting on `---`.

```yaml
---
at: 711
iso: "2026-08-18T21:18:02.711Z"
artist: "..."
title: "..."
show: "..."
```

`at` is milliseconds from the first byte of the recording.

**One file per broadcast, never one per track.** The webm header exists only in
the first blob, so a stream cut at a track boundary is bytes no decoder opens.
Cut by time with `ffmpeg` afterwards. Never cut the stream.

Recordings carry a duration; the station rewrites the header when one stops.
If you ever meet one that does not, `ffmpeg -i in.webm -c copy out.webm` is the
whole fix.

A named recording — one the host started deliberately — is a second file beside
the backup, with its own `.yaml`:

```yaml
name: "..."    slug: "..."     by: "..."
started: "..." ended: "..."    secs: 0    bytes: 0
backup: "20260818-211802-ai.webm"    offset: 0    why: "stopped"
```

`backup` and `offset` say which broadcast it came out of, and where in it.

```
GET /host/recordings/          speaker auth — a browsable index
```

Dolly runs a `whisper-server` on `127.0.0.1:8089`. It belongs to the eGPT
spine, which spawns it and serves it to the house on `:23390`. The radio does
not call it and no recording is transcribed automatically. Do not stop it — it
is transcribing WhatsApp voice notes for both machines.

---

## 7 · Landing on the beat

How late a host lands = their monitor lag + their voice's trip to the station
− `air_delay`.

Three steps, in this order:

1. **Set `air_delay` past what is needed** — a second or two — on the mixing
   desk. It holds the music back for every listener and **takes effect at the
   next restart**. It is the only desk control that is not live; every other
   one reaches the air the moment it moves.
2. **Go on air and talk over a beat.** The host should land early now. That is
   the point of overshooting.
3. **Raise `sync` in the console's monitor** until they sit on the beat.
   Headphones only, live, nothing on the air changes.

**Overshoot on step 1, because `sync` can only add delay.** A host who lands
late has nothing to spend and has to go back to step 1, which costs a restart.

`air_delay` reads out of `GET /likes/now`. Every listener waits that much
longer, so do not leave it high on a station nobody talks on. `0.0` is the
default and holds nothing back.

---

## 8 · Recipes

**Play a track now**

```
GET  /control/search?q=<words>          take results[0].id
POST /control/enqueue?id=<id>&now=true
```

**Say something about the song playing**

```
GET  /likes/now                          take show.id, note the songs/ prefix
PUT  /host/post/<show.id>/<yyMMddHHmmss>.md
GET  /control/show                       read every field
POST /control/show?name=...&title=...&artist=...&note=...&posts=<yyMMddHHmmss>:1
```

**Start a show**

```
POST /control/show?name=<show>&slug=<slug>&title=...&artist=...&note=...
GET  /likes/now                          show.id is now <slug>/<stamp>
```

Then post cards numbered `1`, `2`, `3`.

**End a show**

```
POST /control/show
```

No parameters. The show clears; the files stay.

---

## 9 · Rules

1. **Everything that can fail happens before anything that commits.** Pictures
   before markup, file before list, read before write-back.
2. **The station owns identity.** `show.id`, the track id, the slug decision.
   Read them. Do not compute them.
3. **A caller cannot silence a listener.** Nothing here mutes, pauses or skips
   for someone else. Those controls are the room's.
4. **Attribution is structural.** A card is signed with whoever wrote the file.
   Content follows the prompt. The name does not.

---

## Quick reference

| | | |
|---|---|---|
| `GET` | `/likes/now` | state + show record — public |
| `GET` | `/control/now` | current track — speaker auth |
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
