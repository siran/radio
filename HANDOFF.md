# Handoff — 2026-08-02

Read `CLAUDE.md` in this repo first. It is the working agreement.

## Where we are

The station is a **talk radio you can speak on from a phone, anywhere**.

An opens `https://radio.wildnloyal.org/talk/`, signs in once, clicks a button,
and talks. His voice is recorded in 1.5-second slices, each uploaded as an
ordinary file, and played on air over the music within about a second of
arriving. Several people can talk at once without cutting each other off.

Four services on Dolly, all non-admin, all automatic:
`IcecastServer` (transmitter, loopback only), `LiquidsoapRadio` (the station),
`CaddyServer` (TLS, every public URL), `JellyfinServer` (the library).

The repo now has a remote: `git@github.com:siran/radio.git`, and it is PUBLIC.
History was rewritten on 2026-08-02: the ACME address and 37 guestbook posts
were purged from every commit. Anything committed here is published.

### How a voice note travels

```
/talk/ records 1.5s  ->  PUT /talk/upload/<name>.webm
                          caddy writes it to messages/voice/{who authenticated}/
                          liquidsoap polls that folder 4x a second
                          queues it into that speaker's lane
                          plays it over the music, which ducks if they asked
                          deletes the file five minutes later
```

**No application server anywhere in that path.** Caddy writes the file, a poll
finds it. That is the same shape as the guestbook, and it is why eGPT needs no
integration: dropping a file in `messages/voice/egpt/` is the entire API.

### The two ideas worth not breaking

**The folder is the interface.** Comments are markdown files, broadcasts are
audio files, admin requests are json files with a watcher. Nothing sits in a
request path that can be running-but-broken.

**Identity comes from the server, never the client.** Caddy's webdav root is
`messages/voice/{http.auth.user.id}`, so a speaker can only write into their own
folder. Liquidsoap reads the speaker from the folder name. There is no name
field anywhere, and there must not be — an earlier version had one and it was
a claim, not a fact.

### Endpoints

```
/                            the station          public
/stream                      raw audio            public
/status-json.xsl             now playing          public
/next/                       staging copy         public
/talk/                       speak on air         speakers  (sign in once)
/talk/upload/*               where slices land    speakers
/talk/setting/settings.json  your own settings    speakers
/talk/logout                 401, clears the login
/interactive                 liquidsoap's knobs   speakers  (embedded in /talk/)
/admin*                      create speakers      admins
/live                        harbor over TLS      for a source client
```

Speakers: `dj`, `roger`, `reinie`, `egpt`. Admin: `djadmin`. Credentials in
`CREDENTIALS.md` (gitignored). Add one with `/admin` or `.\mint-speaker.ps1`.

### Per-speaker settings — done 2026-08-02

Each speaker owns one file, written by the talk page over the same webdav route
Caddy already files under whoever authenticated:

```json
{ "gain": 2.5, "duck": true }
```

Both values ride with the note as annotations — `liq_amplify` and `liq_duck` —
so they apply to that note alone, and two speakers can be on air at once with
different answers. The rms threshold detection is gone: both thresholds had been
set to `0.0`, which was not a tuning but the mechanism switched off.

Verified on air: `music down` when a note with `liq_duck="true"` starts,
`music back up` after it ends.

## Decisions already made — do not relitigate

- **Ducking is per speaker**, carried by the note. "Radio control is
  collaborative, people are not competing on settings."
- **The manual duck button is the same file mechanism.** "No button needs fake
  latency." A 0.25s poll is fine.
- **Hosts mix, machines queue.** A new note from a human host mixes with one
  already on air. An automated note — the time, an announcer, a podcast segment
  — waits for the air to clear. This becomes an `automated` flag in
  `settings.json` when the announcer is built; do not add the field before
  something reads it.
- **Notes that arrive while the station is down are dropped.** Only notes
  written after the process started get queued. A three-minute-old "hello
  everyone" landing mid-song is worse than silence.
- **Piper for text to speech**, not Windows SAPI, and not a cloud API by
  default. Local, offline, one binary plus `.onnx` voice files — the same shape
  as everything else here, and the mirror image of the whisper server eGPT
  already runs.
- **Piper runs as a server, with a CLI fallback.** Shape borrowed from eGPT's
  own config: `fallback_order: [ remote, cli ]`. The station keeps talking
  through a restart instead of going mute. A resident model also answers fast
  enough to feel conversational, which matters the moment it answers anything.
- **The announcer talks over the ramp and over the outro.** At track start,
  "you're listening to X"; near track end, "and we just heard X by Y". Both come
  off metadata the station already has. Announcing what is coming *next* is the
  expensive variant — the library is `mode = "randomize"`, so the next track
  does not exist until it is needed — and is not being built.
- **Admin is a role a host holds**, not a separate person. The account goes in
  both `admins.caddy` and `speakers.caddy`. Admin transport and duck commands
  take precedence: peers do not compete, but someone can arbitrate.
- **Video notes**: audio on the radio, `<video>` opened and closed on the site.
  Not a video channel. That was considered and is much larger.

## Where we are going

### 1. The host console at `/talk/` — DONE 2026-08-02

One URL for everyone; the link that makes them log in, not a per-host URL. A
per-host URL would be a name the client claims, which is the one thing this
station does not do. A "i'm a radio host" link goes in the footer of the station
page next to `stream` and `try the newest version`.

The console shows the station plus, on top: duck on/off, recording on/off,
music on/off, pause/play/repeat/skip, the filename being played, an equalizer,
and liquidsoap's own controls.

All of it is built and on air:

- per-speaker `settings.json` — gain, duck, and a three-band EQ
- `/control/*` on the harbor at 8005 behind `import speakers`: now-playing path,
  skip, again, repeat, music on/off, pause. Any host may drive the music.
- the page itself, plus a microphone picker that shows real device names

Three wide peak bells at 160Hz, 1kHz and 4kHz carry the EQ. NOT a shelf pair:
`filter.iir.eq.lowshelf` and `.highshelf` exist but take a `slope` and no gain,
and measured here they are unusable as tone controls — a 100Hz tone through
`lowshelf(frequency=500)` came out 56dB DOWN, and a negative slope returned inf.
A peak is unity away from its centre, so 0dB on all three sliders is exactly
flat. An earlier note in this file said shelves were missing; they exist, they
are just the wrong tool.

The per-note trick: a filter parameter can be a GETTER, `{...}`, re-evaluated as
it runs, so it reads `q.last_metadata()` and follows the current note without
any `override` parameter. Bind the getters BEFORE `amplify` — amplify returns a
plain source, and passing the queue to it first pins the type so `last_metadata`
stops typechecking.

Transport was originally headed for `/admin`. It belongs on the console
instead; `/admin` stays the place you make speakers.

### 2. Startup must not replay the backlog — FIXED 2026-08-02

`seen` lives only in memory, so **every restart re-queues every note still on
disk** — up to five minutes' worth, all at once. This replayed 21 notes on air
on 2026-08-02 while the operator was recording. Fix: only queue notes whose
mtime is after process start, and let the existing cleanup sweep the rest.

Fixed: `started = time()` at load, and `is_new(f)` gates the queueing while
`seen` still records every path, so an old note costs one stat rather than four
a second. Verified across a restart: 0 notes queued.

### 3. The narrator

A `.md` dropped in a voice folder gets read aloud. Frontmatter for the
parameters, body for the words:

```markdown
---
voice: zira
rate: -1
pitch: +10%
---
Good evening. Coming up, three hours of Ethiopian jazz.
```

**The shape:** a watcher renders the `.md` to a `.wav` in the same folder, and
the existing pickup plays it. Liquidsoap never learns what markdown is. Same
pattern as `admin-watcher.ps1`.

**The watcher must stage the wav inside the speaker's own folder** under a name
the pickup ignores, then rename it. See the traps below — this is not a style
preference, both of the obvious alternatives are broken.

The guestbook connects to this for nothing: `chat/` is already `.md` files and
the narrator already eats `.md` files. Reading listeners' comments on air is a
small change once the announcer exists.

### Later, agreed but not urgent

- **EQ per note** — same annotation channel as gain. This build DOES have
  `filter.iir.eq.lowshelf`, `highshelf` and `peak`, so a real three-band EQ is
  available. (An earlier version of this file said otherwise. It was wrong.)
- **Presets** — a named bundle of per-note values, chosen in `/talk/`.
- **Reduce `lane_count`** — 8 was arbitrary. Last, because nothing else should
  depend on lane identity.
- **China** — his wife loads the page but the audio stalls. HLS is the likely
  fix and this build has `output.file.hls` and `output.harbor.hls`. **Waiting on
  one datum**: can she open `/stream` directly, or does that stall too?
- **Autocommit guestbook posts** — untracked for now, deliberately.
- **A station-level `config.json`** for announcer cadence and house voice, read
  with `json.parse` and `file.watch`. Liquidsoap can also `json.stringify`, so
  the save button and the file are the same object. **If it lands, the rule is:
  the file is truth at startup, the `interactive` knobs are live overrides, and
  save writes the knobs back.** Otherwise a restart silently reverts a tuning.

## Who anyone is — the identity model

Two kinds, ordered by authority, and there is no third:

- **Verified** — hosts. The server decides who they are, because they can talk
  on air and drive liquidsoap. Authority needs proof.
- **Claimed** — everyone else. They put a name to what they say and nobody
  checks it. Enough, because the only thing at stake is their own words.

Do NOT call the second kind anonymous. An's ruling, and he is right: that word
describes the system's ignorance and then pins it on the person as though it
were a property they have. If you want to know who someone is, ask who they
claim to be.

## Skip votes — designed, not built

- **12 clicks per listener, per song.** The budget refills each track, so every
  song is its own contest.
- **Clicks go both ways.** Skip and keep. A tug of war, not a poll. The
  counter-click IS the veto, which is why the threshold need not be the whole
  pool — requiring every click in the room lets one absent listener veto it.
- **Threshold is net force against a fraction of the pool.** Half is the
  working proposal: 60 net out of 120 with ten listeners.
- **Show the tug while it happens.** Watching the bar move is the feature. A
  vote you cannot see is admin; one you can see is a crowd.
- **The counter lives in memory, not on disk** — votes die with the song, so a
  restart clearing them is correct rather than data loss. The one place where
  folder-is-the-interface is the wrong answer.
- `on_metadata` already fires on every track change, so the count resets itself.
- Voting is public, so it needs its own unauthenticated route; `/control/*` is
  behind the speaker credential.
- The per-listener budget is browser-local and defeatable. Fine. It is a song.
## Traps that have already cost real time

The README has the full list. These bit hardest:

- **Liquidsoap caches compiled scripts.** `Loading main script from cache!` in
  the log means your edit did not run. Clear `D:\Liquidsoap\cache`. The running
  station was not the file on disk for a stretch of one session.
- **`file.ls` with `recursive = true` ignores `pattern`**, returns directories
  too, and yields MIXED separators — forward slashes for the directory you gave
  it, backslashes below. `path.*` only understands `/`.
- **`string.split` takes a REGEX.** A bare backslash is not one; it throws and
  kills the polling thread silently.
- **There is no `path.extension`.** `path.remove_extension` exists.
- **`x = try ... end` does not parse** in liquidsoap 2.4.5 — a `try` is only
  valid where a statement is. Anything fallible has to be its own function.
- **`Set-Content -Encoding UTF8` writes a BOM**, which makes liquidsoap's parse
  fail and silently fall back — a slider that appears to do nothing. Use
  `[IO.File]::WriteAllText(p, t, (New-Object System.Text.UTF8Encoding($false)))`.
- **`Move-Item` from TEMP carries the SOURCE ACL**, so `svc-radio` gets
  `Permission denied` and the file never plays. A file *created* inside the
  folder inherits the folder's ACL. Stage in place, then rename.
- **A file written in place gets picked up half-written** — the poll runs four
  times a second. Rename is atomic; writing directly is not. Both halves of this
  and the ACL trap have to be solved together.
- **Caddy's `request_body max_size` truncates rather than rejecting**, and
  webdav writes the truncated bytes. An oversized PUT returns 405 *and* leaves a
  corrupt file. Measured 2026-08-02.
- **`hold` on the dial is worth half what it reads.** The accumulator adds
  `0.04` per call against a `0.02s` frame. Measured: 14 seconds at a setting of
  28. Every hold value tuned by ear means half its number.
- **Windows PowerShell 5.1 has no `-SkipHttpErrorCheck`.** A 4xx throws; read
  the status off `$_.Exception.Response`.
- **Caddy writes progress to stderr**, which PowerShell under
  `$ErrorActionPreference = 'Stop'` treats as a terminating error on success.
  Git does the same on push.
- **Caddy reload, never restart.** Restarting drops listeners.
- **Restarting Liquidsoap replays the note backlog** — see the pending fix
  above. Do not restart the service while anyone is on air.
- **Line endings are consistent per file, deliberately**: `radio.liq` and
  `Caddyfile` are pure LF, the HTML pure CRLF. They used to be mixed, and mixed
  is what let a whole file get converted by accident twice in one day — once by
  a `--tree-filter`, once by an agent's editor. Use `--index-filter` for history
  rewrites; it never checks a file out.
- **`file.mtime` does NOT throw on an unreadable file** on this build — it
  returns the true mtime, and 0.0 for a missing one. An earlier note here said
  otherwise. Measured 2026-08-02.
- **`{http.auth.user.id}` in a webdav root works** — verified, and it is the
  whole basis of identity here.
- **SAPI wav decodes fine** at 44100/16/stereo (`pcm_s16le`). Dolly has only
  David and Zira installed; no natural voices are present.

## How this session was run, and why

Source work goes to background agents with briefs that name the existing code to
route into, forbid parallel paths, and demand a stated shape. Every diff is
verified independently before committing — twice an agent's summary was right
but incomplete, and once one found a real bug the brief had not asked about.

One correction worth carrying: *a question is a question*. "What do you think?"
and "where does X come from?" ask for an answer, not an implementation.

And one from today: **a permission granted in one context does not carry to
another.** "Uptime is not sacred during transitions" was true when nobody was
listening. Handing that line to an unattended agent while the operator was
recording put 21 of his notes back on air.
