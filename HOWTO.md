# Wild n Loyal Radio — where everything is and how to run it

For a person at the machine. If you are an agent driving the station over HTTP,
read `AI-DJ.md` instead — this is about the boxes, that one is about the API.

Every path here was read off the running station, not remembered.

---

## The one-minute version

```
start-radio.cmd            bring up anything that is down          (double-click)
start-radio.cmd -Status    say what is up, change nothing          (no admin prompt)
status-radio.cmd           the same, plus watchers and narrator detail
restart-radio.cmd          STOP and start — drops every listener
```

`start-radio` never stops anything, so double-clicking it when unsure is safe.
`restart-radio` is the one that interrupts a broadcast.

---

## The machine

Everything runs on **Dolly**. Reach it with `ssh an@dolly` (also on port 2222).
Nothing runs on any other machine; a clone elsewhere is for editing only.

| variable | value | what reads it |
|---|---|---|
| `RADIO_HOME` | `C:\Users\an\src\radio` | Caddy, liquidsoap, the bridge, the watchers |
| `RADIO_LIQ` | `D:\Liquidsoap` | the script cache and the liquidsoap logs |

Both are **machine** environment variables. A service started by Windows gets
them; a process you start by hand in a shell that predates them will not.

---

## What is running, and what starts it

| part | binary | started by | port |
|---|---|---|---|
| **icecast** | `C:\Program Files\Icecast\bin\icecast.exe -c C:\Users\an\src\radio\icecast.xml` | service `IcecastServer` (Automatic) | 8000 |
| **liquidsoap** | `D:\Liquidsoap\liquidsoap-2.5.0-79ff0f7-win64\liquidsoap.exe … radio.liq` | service `LiquidsoapRadio` (Automatic) | 8005 |
| **caddy** | `C:\Program Files\Caddy\caddy.exe run --config C:\Users\an\src\radio\Caddyfile` | service `CaddyServer` (Automatic) | 80, 443, 1111, 2019 |
| **live bridge** | `C:\Program Files\nodejs\node.exe C:\Users\an\src\radio\live-bridge.js` | task `RadioLiveBridge` (Boot) | 8007 |
| **narrator watcher** | `narrator-watcher.ps1` | task `RadioNarratorWatcher` | — |
| **admin watcher** | `admin-watcher.ps1` | task `RadioAdminWatcher` | — |
| **whisper** | `C:\Users\an\bin\whisper.cpp\Release\whisper-server.exe` | **nothing** — started by hand | 8089 |

**All of it comes back after a reboot except whisper.** Three Automatic services
and three tasks, two of which have Boot triggers.

`IcecastServer` and `CaddyServer` run under **nssm** —
`C:\Program Files\Jellyfin\Server\nssm.exe` — so their service `PathName` is
nssm's, not their own. Anything that looks for a service by binary name will
miss them. The real command is under
`HKLM:\SYSTEM\CurrentControlSet\Services\<name>\Parameters`.

Everything except whisper runs as **`.\svc-radio`** (the bridge runs as SYSTEM).
Nobody has svc-radio's password — it exists only as an LSA secret. **Never
delete or recreate those services and never change their `ObjectName`:** that is
one-way. Changing `ImagePath` or the environment is safe.

---

## The repo — `C:\Users\an\src\radio`

The station IS the repo. There is no build step and no application server.

### The station itself

| path | what it is |
|---|---|
| `radio.liq` | the whole station: autoDJ, queue, the harbor a live source connects to, ducking, the narrator, every `/control/*` endpoint. 147 KB. **Needs a liquidsoap restart to take effect.** |
| `Caddyfile` | routing and every credential gate. **Needs `caddy reload`** — not a restart. |
| `icecast.xml` | icecast's own config |
| `live-bridge.js` | turns a browser's `webcast` WebSocket into an icecast source connection, writes recordings, remuxes them on stop |

### The pages

| path | served at | what it is |
|---|---|---|
| `index.html` | `/` | the listener page — player, chat, what is on |
| `host/index.html` | `/host/` | the console. Record a note, go on air, the desk, presets |
| `next/index.html` | `/next/` | the listener page's next version |
| `shows/index.html` | `/shows/` | the archive of posted cards |
| `narrator/index.html` | `/narrator/` | narrator settings; also shown inside the console in an iframe |
| `admin/index.html` | `/admin*` | admin |

Each page is one self-contained file — open it and read it end to end. Themes
live in each page's own `<style>`; the choice is one `localStorage` key,
`wnl.theme`, shared across all of them because they are one origin.

### Credentials

| path | what it is |
|---|---|
| `speakers.caddy` | bcrypt hashes for every host. **Gitignored.** |
| `admins.caddy`, `relays.caddy` | the same for admin and the WhatsApp relay |
| `mint-speaker.ps1` | `.\mint-speaker.ps1 -Name dj` adds one and prints a password |

### Running it

| path | what it does |
|---|---|
| `start-radio.cmd` / `.ps1` | starts what is down, touches what is up. Reads `radio-parts.json` |
| `radio-parts.json` | the parts list — **edit this to run on another machine**, not the script |
| `restart-radio.cmd` / `.ps1` | stops and starts. `-What caddy` for one part. Clears the liquidsoap script cache first |
| `status-radio.cmd` | status only, never prompts for admin |
| `install-live-bridge.ps1` | registers the `RadioLiveBridge` task |

### Data — none of it in git

| path | what it holds |
|---|---|
| `recordings/` | every broadcast as `.webm`, plus `.marks.yaml` per broadcast and a `.yaml` sidecar per *named* recording. **2.4 GB.** |
| `posts/` | the cards hosts post, by show |
| `chat/` | the listener chat |
| `messages/voice/<speaker>/` | one folder per host: `settings.json`, `presets.json`, `playlists.json`, `shows.json`, and voice notes dropped in to air |
| `messages/admin`, `messages/restart`, `messages/private` | queues the watchers read |
| `config/` | `desk.json`, `narrator.json`, `history.json` — live station state, changes hourly |
| `cache/` | liquidsoap's compiled script cache. 34 MB. `restart-radio` clears it |
| `live/` | the live source's working files |

**A voice note dropped into `messages/voice/<speaker>/` airs in about two
seconds.** That is the simplest way to get audio onto the station.

---

## Doing things

### Change the station's behaviour

Edit `radio.liq`, then **restart liquidsoap** — `restart-radio.cmd -What
liquidsoap`. It clears the script cache first, which matters: liquidsoap caches
the compiled program, and without clearing it you get the old one running while
the file on disk says otherwise.

### Change routing or a credential gate

Edit `Caddyfile`, then **reload** — not restart:

```
caddy reload --config C:\Users\an\src\radio\Caddyfile
```

A reload keeps the process and the listeners. **It does drop a live source**, so
if somebody is on air, wait. Check first:

```
curl http://127.0.0.1:8005/likes/now      → show.live
```

Validate before reloading. A bad config is refused and the old one stays, but
knowing beforehand is cheaper:

```
caddy validate --config C:\Users\an\src\radio\Caddyfile --adapter caddyfile
```

### Change a page

Edit the file. **No reload of anything** — Caddy serves it from disk and the
`/host*` route sends `Cache-Control: no-cache`, so a refresh gets it.

### Add a host

```
.\mint-speaker.ps1 -Name djgaja
```

It prints a password once. They log in at `/host/` and get their own folder
under `messages/voice/`.

### Get a voice onto the beat

Three steps, in order, and the overshoot is deliberate:

1. **Mixing desk → Music held for the air.** Set it *past* what you need — a
   second or two. This is the **only desk control that is not live**; it needs a
   liquidsoap restart.
2. **Go on air and talk over a beat.** You should land **early**.
3. **Monitor → sync.** Raise it until you sit on the beat. Headphones only.

`sync` can only *add* delay, so a host who lands late has nothing to spend and
must go back to step 1 — which costs a restart. Overshoot the first time.

### Listen without being on air

Console → **Your monitor** → Listen. It works off air; the bed comes from
liquidsoap directly.

---

## When something is wrong

**Start here.** It changes nothing and does not prompt:

```
start-radio.cmd -Status
```

| symptom | look at |
|---|---|
| site unreachable, station fine | `CaddyServer`. `curl http://127.0.0.1/` should answer 308 |
| no audio anywhere | `IcecastServer` then `LiquidsoapRadio`, in that order — liquidsoap connects *to* icecast |
| **Go on air** does nothing | the live bridge. `curl http://127.0.0.1:8007/host/onair` |
| announcements silent | `RadioNarratorWatcher`, and `status-radio.cmd` lists what piper failed to render |
| a recording will not seek | it has no duration. `ffmpeg -i in.webm -c copy out.webm` — this now runs automatically on stop |

`dolly` not resolving *and* the site timing out usually means the machine is
asleep or off, not that anything is broken.

---

## Things worth knowing before they bite

**The Caddyfile is LF, the pages are LF, `.cmd` files are CRLF.** Enforced by
`.gitattributes`. Patching a file by exact string match with the wrong ending
computes offsets against the wrong line length; that once cut 33 KB out of the
Caddyfile.

**`max_size` in Caddy truncates, it does not refuse.** Over the cap you write
half a file and nothing tells you. That is why the caps are generous.

**Caddy sorts `handle` blocks itself.** A specific route can lose to a broader
one and there is no warning — `/host/ai/*` once lost to `/host*` and 404'd for a
day. If a route is not being reached, `caddy adapt` and read the order.

**`fetch` only rejects on network failure.** A 404 or 429 resolves happily. Every
write in the console checks the status; anything new must too.

**Recordings are one file per broadcast**, never one per track. A webm header
exists only in the first blob, so a stream cut at a track boundary is bytes no
decoder opens. Cut by time with ffmpeg afterwards; never cut the stream.

---

## Elsewhere on the machine

| path | what it is |
|---|---|
| `C:\Users\an\bin\whisper.cpp\` | whisper-server and its `ggml-large-v3` model. Running, **nothing calls it** |
| `C:\Users\an\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe` | ffmpeg. Under a *user's* AppData, so SYSTEM does not see it on PATH — `live-bridge.js` searches for it |
| `C:\Program Files\Jellyfin\Server\nssm.exe` | the service wrapper icecast and caddy run under |
| `.egpt\rooms\radio\identity.d\AI-DJ.md` | a **copy** of the repo's `AI-DJ.md`, loaded as an agent's identity. The repo one is canonical |
