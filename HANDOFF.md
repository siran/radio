# Handoff — 2026-08-08

Read `CLAUDE.md` in this repo first. It is the working agreement, and §5 is the
one that changes how you work: **source work goes to a background agent, and this
file wins if your harness says otherwise.** Your own hands are for scoping,
briefing, verifying, committing, deploying, ops and this document.

The repo is **public**: `git@github.com:siran/radio.git`. History has been
rewritten twice to purge things that should not have been published. Anything
committed here is published. Credentials live in files that are gitignored by
name — check `.gitignore` before adding one.

## What this is

A radio you can host from a phone, anywhere. Sign in at `/host/`, press one
button, and your voice goes out over the music as one whole note. A narrator
speaks between the tracks. Anyone listening can like a song, leave a note, or
queue one. The operator's own description, which is better than anything above:
**a web music player your friends can join, and to which you can talk.**

Two ideas carry almost everything:

**A file appears, something notices it.** Voice notes, narrator lines, admin
requests, restart requests, settings, presets, playlists, the desk, the phrase
ledger. Each new feature has been a folder and a poller rather than a subsystem.

**The folder is the identity.** Caddy files uploads under
`{http.auth.user.id}`, so "whose is this" is answered by the server before our
code sees it. There is no user model in this station and there never needed to
be.

The one place a note's settings do NOT come from its folder is worth knowing:
**a speaker's gain, ducking and EQ ride with the note** as an `annotate:` URI
baked in at pickup. Lanes are only about concurrency — eight of them, so several
people can talk at once instead of queueing. A ninth speaker shares a lane and
waits, and still sounds exactly like themselves.

## Operating it

```
restart-radio.cmd -Status              look, change nothing
restart-radio.cmd                      icecast then liquidsoap, then the watchers
restart-radio.cmd -What liquidsoap     just the station
```

It asks for administrator rights itself. `-Status` does not, because looking
should not need a prompt. Caddy is excluded from `-What all` on purpose —
restarting it disconnects every listener; reload it instead, and note that both
`caddy validate` and `caddy reload` need `ACME_EMAIL`, a machine variable, and
must run **from inside the repo directory** because `import` resolves relative to
the config.

A liquidsoap restart is ~15 seconds of silence. It no longer costs the desk
tuning: `config/desk.json` is read at startup.

## Endpoints

```
/                            the station                        public
/stream                      raw audio                          public
/likes/now                   likes, elapsed, duration, the skip
                             counter and its cool-off           public
/likes/add                   like the current track             public
/tug/skip  /tug/keep         push the skip counter up, or pull
                             it back down                       public
/live/narrator.json          what the narrator just said        public
/host/                       the console                        hosts
/host/upload/*               a host's own voice notes           hosts
/host/relay/<speaker>/<file> a note posted FOR a speaker        egpt-relay
/host/setting/settings.json  gain, duck, seven-band EQ          hosts
/host/presets/presets.json   presets: sound, desk, panels, phrases
/host/playlists/playlists.json  named running orders            hosts
/host/desk/desk.json         the mixing desk, so it survives    hosts
/host/onair                  going live: a webcast websocket    hosts
/host/restart/req|res/*      ask a watcher to restart           hosts
/control/*                   now, skip, previous, again, repeat,
                             music, pause, knobs, search, enqueue
/control/queue/*             add, remove, move, clear           hosts
/interactive                 liquidsoap's own knobs             hosts
/narrator/                   the narrator dashboard             hosts
/narrator/history/*          every phrase it keeps              hosts
/admin*  /adminapi/*         make and remove hosts              admins
```

Four realms, deliberately separate: `speakers`, `admins`, `relays`, and icecast's
own. Being able to talk on the radio must not mean being able to add people to
it, and relaying a note for somebody must not mean being able to talk as them.

## The eGPT bridge — designed, built, not yet carrying traffic

Three documents outside the repo, in `C:\Users\an\`:
`egpt-radio-brief.md` (what the station offers, with credentials),
`egpt-radio-requirements.md` (their first proposal),
`egpt-radio-reply.md` and `egpt-radio-relay-route.md` (the negotiation and the
agreed design).

**The route is live and passes its three acceptance checks.** eGPT relays a
WhatsApp voice note into a speaker's folder with one credential, `egpt-relay`,
and the speaker comes from the URL path rather than from the authenticated
identity — the opposite of `/host/upload/`, deliberately.

A password store was proposed and rejected. The deciding argument was theirs:
`/host/` sits behind the same credential as the upload, so under
mint-and-remember the first time eGPT forgot `roger` and re-minted to recover,
**Roger would be locked out of his own console** — and re-minting was that
design's documented recovery path.

Still to happen: the operator maps WhatsApp identities to speaker names in
eGPT's own config, and mints those speakers in the admin page. Nothing about
chat identity crosses to the station.

## Going live from the console

A host can now open the microphone and stay open, over the music, instead of
only recording a whole note and sending it when it ends. Both remain; a note is
still the better way to say something once, and this is the only way to say
something WITH the bed under it.

```
/host/ page  --webcast over ws-->  live-bridge.js  --icecast source-->  8005/live
```

`live-bridge.js` is a scheduled task, `RadioLiveBridge`, registered by
`install-live-bridge.ps1` and restarted and reported by `restart-radio.ps1`
alongside the two watchers. It listens on **127.0.0.1:8007 and nowhere else**;
caddy is the only thing that reaches it, which is what makes it safe for it to
authenticate nobody. It has no dependencies — the RFC 6455 server framing is in
the file — and it decodes nothing: MediaRecorder makes webm/opus, the harbor
takes webm/opus, and every byte crosses unchanged.

**It speaks `webcast`, savonet's protocol, not a framing of ours**
(`github.com/webcast/webcast.js`): subprotocol `webcast`, a first text frame
`{type:"hello",data:{mime,audio}}`, then binary frames. So webcaster, or
anything else that speaks it, points at `/host/onair` unchanged. Server-to-
client frames (`ready`, `waiting`, `tally`, `warn`, `error`) are an extension —
the spec defines the client's half only — written in the same `{type,data}`
shape, and a client that ignores them loses only the explanations.

**Why a bridge at all, since this build's harbor speaks webcast natively.** It
does — measured, not assumed, and it is worth not re-deriving: a websocket
upgrade to `/live` on 8005 is answered `101 Switching Protocols` with
`Sec-WebSocket-Protocol: webcast` echoed, from loopback, from 192.168.1.102 and
from another machine on the LAN; hello plus webm/opus gave `[live:3]
Decoding...`; and a wrong password came back as a websocket close `1011` with
the text `Authentication failed.`. The page could talk to the station directly.

It does not, for one permanent reason: **the webcast hello frame carries the
source password, and the source password must not be in a page.** The bridge is
where the credential changes hands — caddy checks the speaker, the bridge
supplies the station's own, read from the `LiquidsoapRadio` service key. That is
not a stopgap and does not go away.

The second reason it takes the icecast source protocol on the way out, rather
than relaying webcast to webcast, is how the two fail:

```
                 websocket                        icecast source
wrong password   close 1011 "Authentication..."   401 Wrong Authentication data
mount taken      close 1006, NO reason at all     403 Mountpoint already taken
```

A mount already taken is the failure a host actually meets, and only one of
those two can be turned into a sentence.

**In the page**: `Go on air` is its own panel with its own button, a fixed red
bar across the top of the screen, and `● ON AIR` in the tab title. That is
deliberate and not decoration — the monitor's `Hear my mic` had already been
mistaken for transmitting once. The note recorder is disabled while on air, so
one voice cannot go out twice.

## Debts, largest first

### 1. Port 8005 is shared, and it races

`input.harbor` and every `harbor.http.register` share it. Which one serves HTTP
depends on initialisation order. When the source harbor wins, **every
`/control/*` returns 404 while the station plays perfectly** — and the 404 body
says `<title>Liquidsoap source harbor</title>`, which is how you know.

A restart usually takes it back. The real fix is to move the HTTP surface to its
own port. **The operator's framing lowers this**: if voice notes are the primary
path and Cool Mic is secondary, the contended port may be retired rather than
fixed.

### 2. Caddy and liquidsoap share `svc-radio`

So granting Caddy write access to `config/` gave the station write access to its
own settings. Only a separate account fixes it, which argues for the
`C:\services\` split.

### 3. Absolute paths are baked in everywhere

41 of them: `radio.liq` 14, `Caddyfile` 18, the watchers and scripts the rest.
This is what stands between the station and moving to `C:\services\`. Fixable —
Caddy reads `{$ENV_VAR}` and liquidsoap has `environment.get` — but it touches
every file and needs a restart. **The operator has asked for "nothing hardcoded,
everything rides configuration"; this is the outstanding half of that.**

### 4. Smaller

- `/host/upload/*` has the same `max_size` truncation exposure the relay route
  now guards against: an oversized PUT answers 405 and leaves the truncated
  bytes on disk. Safe today only because the page caps at 15MB client-side.
- The accepted extension list exists in two programs that cannot share config.
  One statement per program is the floor; `radio.liq`'s `exts` is authoritative
  and the Caddyfile says so.
- **The chat panel can list its messages and cannot read any of them.** Found
  while testing something else, not fixed, and not caused by it. `@docs` 404s
  every `*.md` on the site bar the relay route, and `/chat/` has no `handle` of
  its own ahead of it - so `GET /chat/` returns a listing of 21 files and every
  one of the 21 bodies behind it answers 404. `/messages/` is unaffected because
  its own block runs first and is terminal: those `.md` files answer 200.
  Measured on the live site. The fix is presumably one more exception on `@docs`
  or a `/chat/*` block above it, but which of those is right is a question about
  what chat is meant to be, so it is left for a ruling.
- `messages/voice/announcer/settings.json` still carries a three-band `eq` from
  before the seven-band change. Harmless, stale.
- `mmss` has no hours branch, so a long listening session would read `181:05`.

## What the numbers are

Measured on this machine. Several contradict what was assumed.

- **1175 tracks**, about 1 in 5.4 with no usable title.
- **Voice**: a DJI note measured peak −0.5 dBFS, mean −21.3 dB, −18.1 LUFS,
  range 15.1 LU. Peak-loud and average-quiet, which is why gain alone never
  helped and why the compressor is the tool that does.
- **Desk as tuned**: mic_gain 3.0, voice_gain 1.0, hp_freq 80, comp_thr −26,
  comp_ratio 6.0, comp_gain 12.0, duck_to 0.6, hold 2.0, glide 0.01.
- **Longest note**: ~12:45 at 160 kbps. It is a byte cap (15MB page, 16MB caddy),
  so it moves with the bitrate.
- **Listeners**: icecast caps at 200; the real limit is upstream bandwidth at
  128 kbps each. 96 kbps or mono would buy a third to a half more.
- **Stream start**: `burst-size` 65536 gets 64kB to a joining player in 484ms,
  against 3578ms at 16384.
- **Going live, mouth to listener: 830–1140 ms, median 875.** Five runs, and it
  is a real end-to-end figure rather than a sum of guesses: the music was turned
  off so the stream was digital silence, /stream was read by a process that
  recorded the wall clock of its first byte, the browser's fake microphone was
  opened, and the tone's onset was found in the decoded capture. Aligning the
  capture costs one known constant — icecast's 65536-byte burst is 4.096 s at
  128 kbps CBR, and everything after it arrives in real time. The budget:
  MediaRecorder's 300 ms timeslice, the harbor's 200 ms `buffer`, then mp3
  encoding and icecast.
- **Getting on the air**: the mount is granted in **35–50 ms** from the socket
  opening. Pressing the button to the first audio actually leaving the page is
  **~1.6 s** the first time, because that is opening the device; on a second go
  with the microphone already warm it is **~420 ms**.
- **A source is let go of five seconds after its last byte**, whether the socket
  is half-closed or reset — the two are indistinguishable to the harbor. So
  stopping and starting again inside that window is refused, and the bridge
  waits it out: measured at 5 attempts over 5.0 s before it went on.
- **ogg/opus releases the mount at once, webm/opus waits the full five.** An ogg
  end-of-stream page tells liquidsoap the stream is over; webm has nothing that
  says so, so only the timeout ends it.

## Traps that have cost real time

- **`/control/music` is NOT a toggle.** `radio.liq` reads
  `req.query["on"] == "true"`, so a POST with no query string is not a no-op —
  it is an explicit OFF, and calling it again does not undo it. A probe that
  "toggled" music off left the station silent and then could not put it back.
  `POST /control/music?on=true`. The same is true of `/control/pause` and
  `/control/repeat`.
- **Do not POST at 8005 directly.** `/control/*` through caddy works; the same
  POST straight at the harbor is reset before it answers, with or without a
  `Content-Length`, which reads as the station being down and is not. The
  console page has never done it and neither should a script.
- **`reg.exe` prints a REG_MULTI_SZ on ONE line** with a literal two-character
  `\0` between entries, not a NUL byte. Splitting the value on whitespace to
  find `RADIO_HARBOR_PASSWORD` captures it AND the icecast password after it as
  one 53-character string, and the harbor answers 401.
- **A browser throws away userinfo in a websocket URL.** `new
  WebSocket("ws://user:pass@host/")` sends no credential of any kind: measured
  against a listener that printed the raw handshake, the request was identical
  to one with no userinfo and carried no `Authorization` header. Anything that
  appears to authenticate that way is parsing the URI itself and putting the
  credential in the protocol — which is what webcast's hello frame is for. A
  websocket under `/host/` is authenticated by the credential the browser
  already cached for the realm, the same mechanism `/host/monitor` relies on.
- **A silence-onset detector will find icecast's burst.** A latency measurement
  that looked for "first sound after two seconds of silence" locked onto the
  PREVIOUS run's music resuming inside the 4.1 s burst and reported a latency of
  minus twenty seconds. Constrain the search to audio emitted after the event
  being measured. It is the same lesson as the disc-centre artifact below: a
  measuring script will happily invent a number.
- **Liquidsoap caches compiled scripts.** `restart-radio.ps1` clears it.
- **`--check` and a clean startup prove almost nothing about a source operator.**
  A `gate()` in the voice chain typechecked, started, played for an hour, then
  killed the audio clock with a stack overflow inside `Gate.gate#generate_frame`.
  **Prefer a change that adds no operator to the audio path** — the playlist
  queue was built that way deliberately, inside the playlist's own request queue.
- **`Move-Item` carries the SOURCE ACL.** A file moved in is unreadable to
  `svc-radio` and fails as a *codec error*, which sends you a long way from the
  problem. Create in place, or `icacls <file> /reset`.
- **`messages/voice/announcer/` is an INPUT, not a directory.** Anything ending
  `.txt` or `.md` dropped anywhere under `messages/voice/` is spoken. An archive
  written there was rendered and broadcast as 26MB of a synthetic voice reading a
  failure log.
- **`@(ConvertFrom-Json $raw)` is wrong for a JSON array.** PowerShell 5.1 writes
  a top-level array to the pipeline as ONE object. Assign first, then wrap.
- **PowerShell variable names are CASE-INSENSITIVE.** `$b` and `$B` are one
  variable. A test script held its base url in `$B` and used `$b` as a loop
  accumulator; every request after the first went to a url with no host, and the
  error said "the hostname could not be parsed" rather than anything about
  scope. Nothing warns. Give one-letter names a wide berth in a script that also
  holds configuration.
- **`request.resolve` returns TRUE for a file the account cannot read.**
  `content_type = library` is what makes it fail honestly.
- **`playlist.set_queue` DROPS requests already in the queue**, and empties
  before it fills — resolve first or a track ending in that window gets silence.
- **Caddy's `max_size` TRUNCATES and answers 405.** Refuse on `Content-Length`
  before the handler opens the file. `16MB` means 16,000,000, not 16 MiB.
- **A binding after the FIRST `})();` in a page is dead.** These pages have a
  second `/whoami` closure; code appended at the end lands in a scope with no
  `$`, throws at load, and silently kills the feature. `node --check` cannot see
  it. Assert the offset.
- **`* { animation: none !important }` never matches a pseudo-element.** It has
  never worked here. Stop animations by name.
- **A bare `1fr` grid row cannot be smaller than its contents.** Use
  `minmax(0, 1fr)` or a line box will silently steal space.
- **Set-Content -Encoding UTF8 writes a BOM.** Use `[IO.File]::WriteAllText` with
  `UTF8Encoding($false)`.
- **Never write `\$(...)` in a PowerShell here-string.** PowerShell escapes with a
  BACKTICK. This broke the station page for twenty minutes.
- **Line endings are per file**: `radio.liq` and `Caddyfile` pure LF, the HTML
  pure CRLF, `admin/index.html` LF. Measure, never assume — editors silently
  convert.
- **Chrome DevTools ports 9381–9480 are reserved on this machine.** Headless
  harnesses using 9401/9403 fail with a bare "fetch failed". Use 9601+.
- **Measure the disc centre at h/2 − 0.5.** Pixel centres sit at 0.5, so a
  sampler using `h/2` reads every radius half a pixel short. One agent's "wall"
  was entirely this artifact.

## Vision, and the backburner

The operator's framing: *a collaborative audio-note radio-hosts radio, infused
with an AI narrator.* Voice notes are not a workaround for failed streaming —
they are the first-class way to host a show.

- **Multiple language streams.** One liquidsoap can feed several mounts; the
  music is decoded once and shared, and only the narrator differs. Costs one
  encode and each stream's own listener bandwidth.
- **Time-aware overlap** of notes, so several hosts sound like a conversation
  rather than a queue. The lanes already sum; what is missing is playing a note
  at the time it was recorded.
- **A voice chat**, and joining several groups — the operator's latest thought,
  and the natural extension of the relay route.
- **Playlist download/upload**, per host. The store already keeps `title` and
  `artist` beside each `id` for exactly this: an id is `string.digest(path)` and
  goes stale if a file moves.
- Per-track `.md` notes; bilingual `lang:`; guest-DJ takeover; browser
  system-audio capture; podcasts on demand; the `C:\services\` split; tagging
  the library.

## Decisions not to relitigate

- **Whole notes, not slices.** The capture path used to stop and restart the
  recorder every 1.5s and lost everything between. One note is one recording.
  The AudioWorklet rebuild that was once the plan is unnecessary unless
  conversational async becomes a format worth having.
- **The desk lives in a file.** It was destroyed three times in one day when it
  did not.
- **The playlist queue lives inside the playlist's own request queue**, not a
  second source behind a fallback. A fallback puts a source on air that
  `library.current()`, `skip`, `previous` and the outro cannot see.
- **The relay route, not a password store.** See above.
- **The skip counter is asymmetric, and 0 is only a floor.** One counter per
  track, 0 to 12, shared by everybody; a skip click adds one, a keep click takes
  one away, at 12 the track goes. The obvious tidy-up is to make the bottom mean
  something too - a saved track, a veto, a rope with two ends. Don't. Keeping a
  song is meant to be EFFORT, not a veto: you have to keep clicking it back down
  while others push it up, so a brief loud opinion cannot win and nobody holds a
  block for the rest of the song. There is no percentage, no quorum and no
  per-person budget, which is what makes it work with two listeners in the room.
  One person clicking twelve times can skip, on purpose. The minimum gap between
  clicks in the page and caddy's rate limit on `/tug/*` bound the RATE against a
  held key or a script; neither is a vote budget and neither should grow into
  one. The five-second cool-off after every track change is a separate rule and
  is about latency, not voting: the page reads the station live while the ear is
  several seconds behind the stream, so clicks in that window would be votes on
  a song not yet heard. Clicks in it are REFUSED, never queued - releasing them
  when the window lifts would chain-skip the new song on the old song's votes.
- **Flat is the default for a new host.** Not a guess at a good sound — the
  absence of one, which is the only honest default for a microphone the station
  has never heard.

## How to work here

Scope from evidence, dispatch source work with a brief that names the existing
code to route into and forbids parallel paths, then **verify every diff yourself
before committing** — over these sessions agents have caught a size guard
counting UTF-16 units against a byte cap, a JSON array collapsing to one object,
a resolve that lied about unreadable files, two CSS classes silently applying at
once, and a measuring script that invented a wall. They have also reported
confidently wrong numbers. Both happen; checking is what separates them.

Keep verification proportionate. A full render sweep is right for a new
mechanism and wrong for a nudge — one of them turned "add two grooves" into
forty-one minutes, and the operator noticed.

Commit per chunk, name the paths, never `add -A`. Update this file.

---

# Session close — 2026-08-28

## Do this first

**There are uncommitted edits to `AI-DJ.md` on Dolly.** The operator rewrote it
by hand while I was working; `git status` on Dolly shows ` M AI-DJ.md`, 15,262 B.
**Do not overwrite it, and do not `git checkout` it.** Pull it to reve and read
it before touching anything:

```
scp an@dolly:C:/Users/an/src/radio/AI-DJ.md ./AI-DJ.md
```

Their direction is unmistakable from the diff: **first person, as dj-son**
("I make shows, podcasts, play music from different tabs (bucket-dj)"), all
explanatory prose stripped, and a placeholder left in the text:
`<put djsons password (must be somewhere if it was dj-ing)>`.

**Do not fill that placeholder.** Speaker passwords exist only as bcrypt hashes
in `speakers.caddy`; nobody has the plaintext, and minting a new one is the
operator's to do (`.\mint-speaker.ps1 -Name dj-son`). Leave the placeholder and
say so.

## The task that follows

**Pi is a ~3B model.** The operator said so explicitly and it changes what
`AI-DJ.md` has to be. The version I wrote is 16 KB of careful prose with
measured/untested markings, rationale, and history — written for a large model
reading once. A 3B model needs the opposite:

- imperative, one instruction per line
- concrete literals, not descriptions of literals
- the request shape, then the response shape, then nothing
- no rationale, no history, no "why this was built this way"
- short enough to sit in a small context beside the actual task

The endpoint facts in it are correct and hard-won — keep them, strip everything
around them. Their hand edits are the register to match, not a first draft to
improve.

`HOWTO.md` is the opposite document and should stay long: it is for a person at
the machine and nothing about it is Pi's problem.

## What is canonical, and the trap that made it matter

`AI-DJ.md` **in the repo** is canonical. It says so in its own second paragraph.
Two copies live under `.egpt/rooms/radio/identity.d/` and
`.egpt/rooms/dj-son/identity.d/`; both are copies, both were synced from the
repo on 2026-08-28, and all three hashed identically at that moment.

They had silently diverged for four days because every edit I made went to the
`.egpt` copy — which had itself moved from `.egpt/conversations/room/radio/` to
`.egpt/rooms/radio/` without my noticing. The repo copy, the one anyone cloning
reads, was the stale one. **After editing the repo copy, sync both.**

## Shipped this session

Themes across all five pages (`028ef48`), `<noscript>` telling a scripting-off
reader the stream link works (`cd206c0`), `start-radio.cmd` (`b1a4de4`),
`HOWTO.md` (`7bccfcf`), saved shows kept apart from audio presets (`5373fb0`),
recordings that carry a duration (`62b08dc`), and the removal of the tab watcher
and the whole reader contract (`7af64c8`, `5274a5e`).

The station is healthy: three Automatic services, three tasks, liquidsoap flat
at ~160 MB, 0 of 30 recordings without a duration.

## Three corrections I had to make to myself, worth not repeating

**I reported a boot-resilience gap that did not exist.** I said caddy and icecast
were bare processes that would not survive a reboot and called it the top
priority. They are `IcecastServer` and `CaddyServer`, Automatic services, and
always were — they run under **nssm**, so their service `PathName` is
`nssm.exe` and a filter matching on binary name misses both. The real command is
under `HKLM:\SYSTEM\CurrentControlSet\Services\<name>\Parameters`.

**I twice announced a root cause I had reasoned to rather than measured** — an
ACL that was fine (I had read a `Get-Acl` dump my own `tail` had truncated) and
a `RADIO_HOME` that resolved perfectly. The actual cause of the `/host/ai` 404
was Caddy's own handle-block ordering, found by `caddy adapt` and printing the
routes in evaluation order. When a request behaves wrongly, enumerate the
server's decision order early; identical-looking config blocks are the trap.

**I wrote a fallback into `start-radio.ps1`** — a built-in copy of the parts list
used silently when the JSON was missing. `CLAUDE.md` forbids fallbacks by name.
Removed; it stops and names the file now.

## Open, none of it blocking

- **whisper-server**: running on `127.0.0.1:8089`, holding **4.3 GB**, called by
  nothing. Wire transcription up or stop it — it is the most expensive idle
  thing on the machine.
- **`air_delay` is 0.0**, so no host can land on the beat. Step 1 of §8 in
  `AI-DJ.md` needs doing once and costs a liquidsoap restart.
- **Named recordings work but have never been used** — all 30 are anonymous
  whole broadcasts, which is why nothing says what they are.
- **Shows archive is a bare link**, not a listing. The operator has said this is
  fine for now.
- **Theme choice is read after first paint** — one frame of dark for a
  light-theme reader. Needs an inline `<head>` script to fix properly.

## Standing permissions the operator has given

`caddy reload` when needed **unless someone is on air**, then ask — check
`curl http://127.0.0.1:8005/likes/now` for `show.live`. Liquidsoap restarts were
authorised when there are no listeners. Commit and push without asking when work
is complete. Translation is dropped: browser auto-translate is the answer.
