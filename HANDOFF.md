# Handoff — 2026-08-05

Read `CLAUDE.md` in this repo first. It is the working agreement.

The repo is **public**: `git@github.com:siran/radio.git`. History has been rewritten
twice to purge things that should not have been published. Anything committed
here is published.

## Operating it

```
.\restart-radio.ps1 -Status              look, change nothing
.\restart-radio.ps1                      icecast then liquidsoap, then the watchers
.\restart-radio.ps1 -What liquidsoap     just the station
```

Order matters: restarting icecast drops liquidsoap's connection, so liquidsoap
follows it. Caddy is excluded from `-What all` on purpose — restarting it
disconnects every listener; reload it instead (`caddy reload --config Caddyfile`),
and note that `caddy validate` needs `ACME_EMAIL`, which is a machine variable.

Four services, all as `svc-radio`, all automatic: `IcecastServer`,
`LiquidsoapRadio`, `CaddyServer`, `JellyfinServer`. Two scheduled tasks:
`RadioNarratorWatcher`, `RadioAdminWatcher`.

## What it is

A radio you can host from a phone, anywhere. Sign in at `/host/`, press one
button, and your voice goes out over the music in 1.5-second slices. A narrator
speaks between the tracks. Anyone listening can like a song. Everything is
files on disk and something noticing them.

### Endpoints

```
/                            the station                       public
/stream                      raw audio                         public
/likes/now  /likes/add       likes, no login by design          public
/live/narrator.json          what the narrator just said        public
/host/                       the console                        hosts
/host/upload/*               voice slices land here             hosts
/host/setting/settings.json  gain, duck, seven-band EQ          hosts
/host/presets/presets.json   named presets                      hosts
/host/logout                 401 with a real page               hosts
/whoami                      the server says who you are        hosts
/control/*                   now, skip, previous, again,        hosts
                             repeat, music, pause, knobs,
                             search, enqueue
/interactive                 liquidsoap's own knobs             hosts
/narrator/                   the narrator dashboard             hosts
/narrator/config/*           its settings                       hosts
/narrator/announcer/*        its volume, and the say box        hosts
/admin*                      make and remove hosts              admins
/talk*                       308 to /host                        —
```

Realms are separate: `wild n loyal host` and `wild n loyal admin`. They used to
share one, which meant a browser holding a host password would send it to
`/admin/` and never prompt.

### The two shapes, and why it matters

**File-drop.** The browser PUTs a file, Caddy writes it, something polls and
finds it. Voice notes, settings, presets, chat, the guestbook, narrator config.
Nothing we wrote sits between the click and the disk.

**Live call.** The browser POSTs, Caddy proxies to liquidsoap's own HTTP server
on 8005, and `radio.liq` — our code — answers. Transport, likes, knobs, search.

The old line "no application server anywhere" was sloppy and the operator caught
it. Caddy *is* the server. What is absent is *our* server, and only on the
file-drop half. The browser code is ours everywhere and can fail everywhere —
it did, for twenty minutes, from one stray backslash.

## Debts, largest first

### 1. The capture path loses audio at every seam — the big one

`/host/` records by constructing a `MediaRecorder`, running it for the slice
length, calling `stop()`, and then constructing a **new one**. Stopping is what
produces a self-contained file that can be played on its own. But between
`stop()` and the next `start()`, **nothing is recording**. That audio is gone —
not smeared, not badly decoded. Gone, every 1.5 seconds. Each slice is also a
fresh Opus session, so encoder priming restarts too.

The operator hears this as choppiness and has been fighting it with EQ. No
setting fixes it.

**The fix**: an `AudioWorklet` taking continuous PCM off the stream, cut at exact
sample boundaries, each cut wrapped in a WAV header. No stop/start, no lost
samples, no priming. Liquidsoap decodes WAV happily — the narrator proves it.
Cost is bandwidth: 48 kHz mono 16-bit is ~768 kbps against the current 96. At
24 kHz it is ~384. That belongs on the Streaming panel like everything else.

This is the difference between polishing a chopped signal and having a clean one.

### 2. Port 8005 is shared, and it races

`input.harbor` (where Cool Mic connects) and every `harbor.http.register` share
port 8005. Which one ends up serving HTTP depends on initialisation order. On
2026-08-05 the station came up after an unattended restart with the source
harbor answering, so **every `/control/*` returned 404 while the station played
perfectly**. The console showed "Music controls: HTTP 404" and nothing else was
wrong.

Diagnosis is unambiguous when it happens — the 404 body says
`<title>Liquidsoap source harbor</title>` rather than being a plain 404.

A restart usually takes it back. **The real fix is to stop sharing: leave 8005 to
the source protocol and move the HTTP surface to its own port**, repointing the
`/control/*`, `/likes/*` and `/interactive` proxies in the Caddyfile. Then there
is nothing to race. Not yet done.

### 3. Caddy and liquidsoap share `svc-radio`

So granting Caddy write access to `config/` necessarily gave the *station* write
access to its own settings. `live/` and `config/` are both writable by the
account that also runs liquidsoap. Only a separate Caddy account fixes it, which
is an argument for the `C:\services\` split below.

### 4. Smaller

- `messages/voice/announcer/settings.json` still carries a three-band `eq`
  (`low/mid/high`) from before the seven-band change. Harmless — a mismatched
  shape reads as null and plays flat — but stale.
- `interactive.float` accepts a value past its own slider maximum without
  complaint, so a bad number gives a dial reading off its own end.
- The `dj` preset seeds from whichever browser opens `/host/` first. If that is
  not the phone the operator tuned on, it seeds page defaults and the file then
  exists, so the real tuning never seeds. Recoverable by saving over it.
- Guestbook posts are gitignored and never committed. Deliberate, for now.

## What the numbers actually are

Measured on this machine. Several of these contradict what was assumed:

- **1,175 audio files**, 0.5 s for a recursive walk, 0.1 MB of paths.
- **216 of them have neither title nor artist** — about one in five, not one in
  twenty. A 60-file sample said one in twenty and was unrepresentative.
- **Reading tags costs 13 ms per file**, 15.6 s for the library. It does *not*
  stall the stream: `file.metadata` shells out to ffmpeg and releases the runtime
  lock while it waits. **The recursive walk does stall it** — it holds the lock
  throughout. The opposite of the intuition.
- **`string.contains` costs ~1 ms per call.** Searching three fields across the
  library that way would hold the lock ~2.8 s per query. `string.index` is 16×
  cheaper; entries carry one pre-joined field and a search is 0.13 s flat.
- **A search holds the lock 0.13 s.** One is inaudible; forty in a burst leave the
  clock 4.3 s behind. The UI debounces at 350 ms with a two-character floor.
- **`hold` is real seconds** as of 2026-08-03. It used to be worth half its face
  value, so any tuning from before that date meant half what it said.
- **icecast `burst-size` 16384 → 65536.** Through Caddy, 64 kB of audio arrived
  in 3578 ms before and 484 ms after. Listeners now start almost immediately, at
  the cost of joining ~4 s further behind live.
- **Piper renders ~1.7 s per line.** End to end, text file to air, is 5–8 s,
  dominated by the watcher's 3 s poll and its two-poll stability rule.
- **Piper has no pitch control and no SSML.** Measured: repeated vowels stretch a
  word 54%, hyphenated repeats 65%, ellipses *shorten* it 19%, and `[[ l aI v ]]`
  does nothing. Spelling is the only lever.

## Vision, and the backburner

The operator's framing, worth keeping: this is *a collaborative audio-note
radio-hosts radio, infused with an AI narrator*. Voice notes are not a
workaround for failed streaming — they are the first-class way to host a show,
and the same shape as everything else here.

- **Skip tug of war.** 12 clicks per listener per song, both directions, net
  force against half the pool. Designed in full, not built. Held until likes
  prove themselves.
- **Per-track `.md`** for notes and statistics, and the natural home for a
  `lang:` field. Needs a 404 on the folder or it publishes the library layout.
- **Bilingual announcements.** A voice *and* a sentence template per language,
  keyed off `lang:`. Three Spanish voices are already installed
  (`es_ES-sharvard`, `es_ES-davefx`, `es_MX-claude`). Not a piper feature — piper
  is one language per model, which is why the pronunciation table existed and
  why removing it means Spanish names stay wrong.
- **Guest DJ takeover.** Mixxx speaks Icecast source natively and points at
  `/live` today. What is missing is the *mode*: music off rather than ducked
  while a guest is connected, visible on the console, restored on disconnect.
  `music_on` and `connected` both already exist.
- **System audio from the browser.** `getDisplayMedia({audio:true})` on
  Chrome/Edge for Windows captures system or tab audio into the same pipeline —
  a Zoom call or anything else, over the ducked music. Firefox cannot. Probably
  wants mic and system audio mixed rather than either alone.
- **Chat with the radio.** whisper in, an answer, piper out. Every piece exists.
  "Machines queue, hosts mix" already governs when it may speak.
- **Clean intro.** Pause the music, introduce the song, resume. The `paused` ref
  exists; the hard part is knowing when the line has finished.
- **Video notes.** Audio on the radio, `<video>` opened and closed on the site.
  Not a video channel.
- **Podcasts on demand**, **multilingual mounts** (`sources` is 10 now),
  **±15 s seeking**, **autocommit guestbook posts**.
- **Services out of the profile** — `D:\services\{...}`, which has the space;
  `C:` has 1.8 GB free. Sources stay in `src`. Piper already lives there.
- **Tag the library.** 216 untagged files is the root of several irritations at
  once, and it would fix Jellyfin browsing too.
- **China.** Still waiting on whether `/stream` opens directly there.

## Decisions not to relitigate

- Identity has two kinds: **verified** for hosts, **claimed** for everyone else.
  Never the word *anonymous* — it describes the system's ignorance and then
  blames the person for it.
- **Hosts mix, machines queue.** A new note from a person mixes with one already
  on air; an automated one waits for a gap.
- Notes that arrive while the station is down are dropped.
- The folder is the interface. Identity comes from the server, never the client.
- Likes are kept forward; skip votes die with the track.
- Search returns an opaque id and never a path.
- **A question is a question.** "What do you think?" asks for an answer, not an
  implementation.

## Traps that have cost real time

- **Liquidsoap caches compiled scripts.** `Loading main script from cache!` means
  your edit did not run. `restart-radio.ps1` clears it.
- **`file.ls` with `recursive = true` ignores `pattern`**, returns directories,
  and yields mixed separators.
- **`string.split` takes a REGEX**; a bare backslash throws and silently kills
  the thread it is on.
- **`x = try ... end` does not parse.** A `try` is only valid where a statement is.
- **`string.char` is a BYTE, not a code point.** `string.char(0x1F4E2)` throws at
  load and takes the station off air.
- **A throw inside a metadata callback kills it silently** and titles stop
  reaching icecast while the music plays on.
- **`file.mtime` does NOT throw on an unreadable file** on this build.
- **`filter.iir.eq.lowshelf`/`highshelf` take a slope and no gain** and are
  useless as tone controls. `peak` behaves. A filter parameter can be a getter,
  so it can follow the current note — bind the getters BEFORE `amplify` or
  `last_metadata` stops typechecking.
- **Caddy's `request_body max_size` TRUNCATES rather than rejecting**, and webdav
  writes the truncated bytes. A too-small cap silently corrupts a settings file.
- **`Move-Item` carries the SOURCE ACL**, so a file moved into a voice folder is
  unreadable to `svc-radio` and reported as a codec error. Files created *in* the
  folder inherit it. Stage in place, then rename — which also closes the
  half-written race, since the pickup polls four times a second.
- **`Set-Content -Encoding UTF8` writes a BOM.** Use `[IO.File]::WriteAllText`
  with `UTF8Encoding($false)`, or `scp`.
- **A `.ps1` must be pure ASCII or carry a UTF-8 BOM** — PowerShell 5.1 reads a
  BOM-less file as ANSI and one em-dash breaks parsing.
- **Never write `\$(...)` in a PowerShell here-string.** PowerShell escapes with a
  BACKTICK; the backslash form is evaluated and writes a literal `\x`. This broke
  the station page for twenty minutes.
- **`cd` in a PowerShell one-liner does not move .NET's working directory.**
- **PowerShell 5.1 has no `-SkipHttpErrorCheck`**, `Restart-ScheduledTask` does
  not exist, and `Invoke-WebRequest`'s exception path may consume the response
  body — which made a working page look like it returned zero bytes, twice.
- **`ConvertFrom-Json` throws on two keys differing only in case**, taking the
  whole file with it.
- **Line endings are per file**: `radio.liq` and `Caddyfile` pure LF, the HTML
  pure CRLF, `admin/index.html` LF. Check, never assume. Use `--index-filter`
  for history rewrites; `--tree-filter` checks files out and normalises them.
- **Caddy writes progress to stderr on success.** Read the exit code. Git does
  the same on push.

## How to work here

Source work goes to a background agent with a brief that names the existing code
to route into, forbids parallel paths, and demands a stated shape. Verify every
diff yourself before committing — over this session agents caught a live
unauthenticated route, a prototype-pollution bug, a lock-holding search that
would have glitched the air, and several of my own wrong premises. They also
reported a CSS bug that did not exist, so verify their findings too.

Two checks are not optional on any page edit: `node --check` on the extracted
script, **and** confirming every id the script references exists in the markup.
`node --check` passes happily on `$('gone').value`; the browser throws. That
exact pair broke the console twice.

And the thing that made the audio better was not reasoning. It was putting every
capture parameter in front of the person who can hear the result. `autoGainControl`
was switched off on the theory that it was telephone processing; the operator
turned it on and it helped. No amount of thinking from here would have found that.
