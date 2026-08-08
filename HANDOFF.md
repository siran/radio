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
/likes/now                   likes, elapsed and duration        public
/likes/add                   like the current track             public
/live/narrator.json          what the narrator just said        public
/host/                       the console                        hosts
/host/upload/*               a host's own voice notes           hosts
/host/relay/<speaker>/<file> a note posted FOR a speaker        egpt-relay
/host/setting/settings.json  gain, duck, seven-band EQ          hosts
/host/presets/presets.json   presets: sound, desk, panels, phrases
/host/playlists/playlists.json  named running orders            hosts
/host/desk/desk.json         the mixing desk, so it survives    hosts
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

## Traps that have cost real time

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
- **Skip tug of war.** Designed in full, not built. Held until there are enough
  listeners for the arithmetic to mean anything — 60% of two is one person with
  a veto.
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
