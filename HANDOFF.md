# Handoff — 2026-08-02

Read `CLAUDE.md` in this repo first. It is the working agreement, and the last
session went wrong in exactly the ways it describes before it was written.

## Where we are

The station is a **talk radio you can speak on from a phone, anywhere**.

An opens `https://radio.wildnloyal.org/talk/`, signs in once, clicks a button,
and talks. His voice is recorded in 1.5-second slices, each uploaded as an
ordinary file, and played on air over the music within about a second of
arriving. Several people can talk at once without cutting each other off.

Four services on Dolly, all non-admin, all automatic:
`IcecastServer` (transmitter, loopback only), `LiquidsoapRadio` (the station),
`CaddyServer` (TLS, every public URL), `JellyfinServer` (the library).

### How a voice note travels

```
/talk/ records 1.5s  ->  PUT /talk/upload/<name>.webm
                          caddy writes it to messages/voice/{who authenticated}/
                          liquidsoap polls that folder 4x a second
                          queues it into that speaker's lane
                          plays it over the music, which ducks
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
/                      the station          public
/stream                raw audio            public
/status-json.xsl       now playing          public
/next/                 staging copy         public
/talk/                 speak on air         speakers  (sign in once)
/talk/upload/*         where slices land    speakers
/talk/setting/gain     your own volume      speakers
/talk/logout           401, clears the login
/interactive           liquidsoap's knobs   speakers  (embedded in /talk/)
/admin*                create speakers      admins
/live                  harbor over TLS      for a source client
```

Speakers: `dj`, `roger`, `reinie`, `egpt`. Admin: `djadmin`. Credentials in
`CREDENTIALS.md` (gitignored). Add one with `/admin` or `.\mint-speaker.ps1`.

## Where we are going

In order. Each has a decision already made — do not relitigate them.

### 1. Ducking, rewritten — PER SPEAKER

**Decided:** ducking is per speaker, carried by the note, not a station-wide
switch. One speaker's notes duck the music; another's do not; both can be on air
at once. An chose this over a global setting because "radio control is
collaborative, people are not competing on settings".

**Decided:** the manual duck button uses the same file mechanism as everything
else. An: *"no button needs fake latency"*. A 0.25s poll is fine.

This is a **net deletion**. Delete `on_thresh`, `off_thresh` and the RMS
detection. An had already configured his way out of that model — both thresholds
at `0.0` and `hold` at 28s, which is not a tuning, it is switching the mechanism
off. Replace with: duck while a note whose speaker wants ducking is playing, or
while someone is holding the button.

It also removes a wart of mine: `duck_gain` uses `not list.is_empty(seen())` to
mean "are there notes", and `seen` now also holds `undeletable:` sentinels. Two
jobs in one variable. That condition is being rewritten anyway.

### 2. The narrator — a `.md` dropped in a voice folder gets read aloud

Frontmatter for the parameters, body for the words:

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

Verified on this machine: voice (`David`, `Zira`), rate (-10..10) and volume
(0..100) are properties; **pitch needs SSML** and works — tested. Inflection is
SSML too: `<emphasis>`, `<break>`, prosody contours.

**The thing that actually matters here** is not the parameters. David and Zira
are 2013-era and sound it. Windows 11 has free neural voices (Aria, Jenny, Guy)
installable through Narrator settings — **whether they are reachable from the
`svc-radio` service account is an open question nobody has answered.** If they
are, that is worth more than every SSML tag combined. Check it first.

### 3. Video notes — an afternoon, not a project

An's clarification: *"open and then close a `<video />` player just for that"*.
So: **audio on the radio, video on the site.** Not a video broadcast.

The audio half is nearly free — ffmpeg decodes the file and the audio track
plays like a voice note; it may be little more than adding extensions to the
list. The site shows the clip. There is no continuous video stream, no encoder
running forever, no black-screen-between-clips problem.

Do not build a video channel. That was considered and is much larger than
everything built so far.

### Later, agreed but not urgent

- **EQ per note** — same annotation channel as gain. No shelving filters in this
  build; `filter.iir.eq.low/high` and a notch exist, shelves do not.
- **Presets** — a named bundle of per-note values, chosen in `/talk/`.
- **Reduce `lane_count`** — 8 was arbitrary and lanes only carry simultaneity
  now. Last, because nothing else should depend on lane identity.
- **China** — his wife loads the page but the audio stalls. HLS is the likely
  fix and this build has `output.file.hls` and `output.harbor.hls`. **Waiting on
  one datum**: can she open `/stream` directly, or does that stall too?
- **Autocommit guestbook posts** — untracked for now, deliberately.

## Traps that have already cost real time

The README has the full list. The ones that bit in this session:

- **Liquidsoap caches compiled scripts.** `Loading main script from cache!` in
  the log means your edit did not run. Clear `D:\Liquidsoap\cache`. The running
  station was not the file on disk for a stretch of one session.
- **`file.ls` with `recursive = true` ignores `pattern`**, returns directories
  too, and yields MIXED separators — forward slashes for the directory you gave
  it, backslashes below. `path.*` only understands `/`.
- **`string.split` takes a REGEX.** A bare backslash is not one; it throws and
  kills the polling thread silently.
- **There is no `path.extension`.** `path.remove_extension` exists.
- **`Set-Content -Encoding UTF8` writes a BOM**, which makes liquidsoap's parse
  of `gain` fail and silently fall back — a slider that appears to do nothing.
- **Caddy writes progress to stderr**, which PowerShell under
  `$ErrorActionPreference = 'Stop'` treats as a terminating error on success.
- **Caddy reload, never restart.** Restarting drops listeners.
- **An unreadable file used to re-queue forever** — fixed, but the reason is
  worth knowing: `file.mtime` uses `stat`, which opens the file and fails on an
  unreadable one; `file.exists` uses `GetFileAttributes`, which does not.
- **`{http.auth.user.id}` in a webdav root works** — verified, and it is the
  whole basis of identity here.

## How this session was run, and why

Source work went to background agents with briefs that named the existing code
to route into, forbade parallel paths, and demanded a stated shape. Every diff
was verified independently before committing — twice an agent's own summary was
right but incomplete, and once one found a real bug the brief had not asked
about.

An's correction earlier in the day is the one to carry: *a question is a
question*. "What do you think?" and "where does X come from?" ask for an answer,
not an implementation. The session went badly until that was understood.
