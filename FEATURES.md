# Wild n Loyal Radio — what it does

A web radio that can be run by a person, by several people at once, or by an AI,
and that can put **anything playing in a browser tab** on the air.

Three ideas hold it together:

1. **A station an AI can run.** Everything a host can do is an HTTP call behind a
   credential — choose music, queue it, name the show, write cards, speak. No
   separate AI mode, no special API: an AI is just another speaker.
2. **Many ways onto the air, running at once.** A browser console, a phone
   microphone, a WhatsApp voice note, a file dropped in a folder, an icecast
   source client. None is a workaround; the concurrency is the point.
3. **Bucket-DJing.** A host shares a browser tab and whatever plays in it goes
   out over the station, with the library ducking underneath and a watcher
   reading the tab for track changes.

Last verified against the live station on **2026-08-24**, running liquidsoap
2.5.0. Verification status is at the foot of each section: **[measured]** was
exercised against the running station today, **[read]** is from source, and
**[needs a person]** cannot be checked without audio or a gesture.

---

## 1. The listener page

The public face, at `/`. One page, no build step, no framework.

- **Now playing** — artist and title, from tags where they exist and from the
  filename where they don't (about one track in seven of this library has no
  usable tags).
- **The record.** A vinyl disc that spins while audio plays, carries a pause
  symbol when stopped, and physically travels off and on the spindle when the
  track changes. The sound starts *after* the record seats, not before — cause
  before effect — and the lead is absorbed in the buffer animation rather than
  delaying the music.
- **Play / pause**, and pausing genuinely stops pulling the stream rather than
  muting a running download.
- **Volume**, with the speaker icon as a mute toggle that returns to the previous
  level, slider following.
- **Earlier** — the last 60 things that happened: tracks, and the moments a live
  show started and was named, marked as different kinds of event.
- **Like**, **tug of war** (listeners voting a track along or keeping it), and
  **find this song** with a copyable link.
- **Chat**, and a **guestbook** for leaving a message.
- **Cards** — see §5.
- **ON AIR** indicator. Worth knowing precisely what it means: it reads whether a
  source is on the icecast mount, which is true whenever the station is up. It is
  not a claim that sound is coming out.

`[measured]` page serves (281 KB of DOM after JS), now-playing rendered live and
matching the station, earlier list populated, chat / guestbook / posts / like /
tug / find-row all present, ON AIR reading correctly, uptime shown.
`[needs a person]` the record spinning and its pause symbol, volume and mute,
and that pause stops the bandwidth — all need audio playing or a gesture.

---

## 2. Ways onto the air

The distinctive part. All of these work at the same time.

| Route | What it is | Who uses it |
|---|---|---|
| **The console** | Browser page, microphone and/or a shared tab, over a websocket | A host at a computer |
| **Bucket-DJ** | A shared browser tab; whatever plays in it goes out | §3 |
| **Voice notes** | Audio dropped in a folder, aired within seconds | Anyone with the folder |
| **WhatsApp relay** | A voice note in a chat, relayed into a speaker's folder | Listeners, remote hosts |
| **icecast source** | butt, CoolMic, any standard source client | A phone, another machine |
| **The AI** | HTTP calls with a speaker credential | §7 |

**Voice notes** are first-class. A file appearing under `messages/voice/<speaker>/`
is picked up within a quarter of a second, played once over ducked music, and
binned after five minutes. It accepts what real devices actually send —
ogg/opus from WhatsApp, `.oga` from Telegram, `.m4a` from iOS, `.webm` from a
browser.

**The WhatsApp relay** has an identity inversion worth understanding: the relay
holds **one** credential, and the speaker is taken from the URL path rather than
from who authenticated. That is the opposite of the upload route, and deliberate.
Because one credential posts for everyone, revoking a password cannot take one
person off air — a marker file in the folder does that instead.

`[read]` all six routes. `[measured]` the voice pickup loop is running (four
times a second) and the speaker folders exist: andres, announcer, dj, djgaja,
egpt, roger.

---

## 3. Bucket-DJing

The novel one. A host shares a browser tab; the tab's audio is captured, mixed,
and sent to the station. The library ducks underneath automatically. The host can
talk over it.

What makes it more than screen-sharing:

- **Tab audio is independent of system audio.** The host can mute their own
  speakers and the broadcast is unaffected.
- **Change the shared tab without leaving the air.**
- **A watcher reads the tab.** Every 1.2 s it takes a low-resolution frame and
  compares each cell against its own running average. A cell is interesting when
  it changes *far more than it usually does* — so a still label changing gives an
  enormous ratio, a video playing normally sits near 1, and that same video pane
  at a cut spikes to 3 or 4 and fires. A busy region is not noise; it is a
  channel with a high noise floor.
- When it fires it offers the frame to the host, who can put it in a post.

**The trap that costs an evening:** a browser launched with `--mute-audio`
captures **silence** — encoder running, mount held, bytes flowing, nothing in
them. Measured: RMS 0.0000 with the flag, 0.2485 without.

`[read]` the whole chain. `[needs a person]` the watcher against a real tab —
its numbers come from a synthetic harness and are a floor.

**Not possible:** bucket-DJing from Android. `getDisplayMedia()` is not
implemented in Chrome or Brave on Android; tab and screen capture are desktop
only. A phone can put its *microphone* on air via an icecast source client, but
not what it is playing.

---

## 4. The host console

At `/host`, behind the speaker credential.

- **Go on air** — microphone, a shared tab, or both.
- **Talk over it** — open the mic while a tab plays; the music ducks to the voice.
- **Change tab** without dropping.
- **Monitor** — the music bed without the host in it, straight from the station
  rather than through icecast, so it carries none of icecast's four-second burst.
- **Headphone taps** for the tab and the mic, each independently.
- **A mixing desk** — mic gain, voice gain, high-pass, compressor threshold /
  ratio / gain, duck depth, hold, glide, air delay.
- **The show record** — name, subtitle, artist, title. Three boxes that never
  lock, because a host names a show after going on air, not before.
- **Library control** — search, queue, add, remove, reorder, clear, skip,
  previous, repeat, pause, music on/off.
- **Voice notes** — record and send one without going on air.
- **Recording** — see §6.
- **The AI noticeboard** — see §7.

`[measured]` served and correctly challenged for credentials; its inline script
parses clean; all the station endpoints it drives are working (§8).
`[needs a person]` the audio path itself.

---

## 5. Cards

A host pastes from anywhere — the workflow is "copy from a web AI, tidy it, post
it" — and it appears on the radio as a card. Files land on disk and stay.

- **The sanitiser is the feature.** An allow-list walk with three outcomes per
  tag: kept, *unwrapped* (children survive, the box doesn't — this is what makes
  a paste out of a rich editor readable), and dropped-with-subtree only where the
  content *is* the danger. Parsed with `DOMParser`, so the dangerous string is
  never live in the page even for an instant.
- **Images paste straight from the clipboard** and upload with the card.
- **Edit and repost** — cards carry a revision.
- **Copy buttons** on the listener side.
- **Signed by whoever wrote the file**, not by whatever a prompt claims. Content
  by prompt, attribution by construction.

**Where they live and when they vanish:** during a show, `posts/<show>/<when>/`.
Off air, cards attach to the *song* — `posts/songs/<track>/` — and leave the page
when the track changes. **The files are never deleted.** 49 song folders on disk
today. That split — "now" lives in the station, "then" lives on disk — means
posts vanish because the station stopped mentioning them, with no expiry job and
no cache to invalidate.

`[measured]` `posts/songs/` holds 49 folders; the song-settle logic that clears
them on track change is present and running.

---

## 6. Recording

**Going live is not "recording".** Two different things:

- **A backup** — automatic, one file per broadcast, named after the clock and the
  speaker. Insurance; no decision required, cannot be turned off.
- **A recording** — deliberate and named, started by a host button or by an HTTP
  call, so the tab watcher or an AI can trigger it. Written as a *second file
  teed live*, not cut out afterwards, so it is finished and playable the moment
  it stops. A sidecar records which broadcast it came from and at what offset.

One file per broadcast rather than one per track is forced, not chosen:
MediaRecorder puts the entire webm header in its first blob and never again, so a
stream cut at a track boundary is bytes no decoder opens. Boundaries are written
*beside* the audio in a `.jsonl` of marks instead.

`[measured]` on disk now: two full broadcasts (276 MB and 225 MB), plus a named
recording with its sidecar. `tests/named-recording.test.mjs` covers the named
path end to end without broadcasting anything.

---

## 7. The AI surface

There is no AI integration. There is a **credential**, and everything else
follows.

The station never calls out. An AI is a speaker that calls *in*, with the same
routes a human console uses:

```
GET  /control/now  /control/knobs  /control/search  /control/queue  /earlier  /likes/now
POST /control/skip /previous /again /repeat /music /pause /talking
POST /control/enqueue  /control/queue/add|remove|move|clear
GET/POST /control/show
PUT  /host/post/<show>/<file>          cards, and their images
POST /host/onair/rec/start|stop        named recordings
```

Plus a **noticeboard**: one file the console writes and the AI reads, holding a
prompt and an auto/vet switch, so a host can drive or supervise it.

Because a card is signed with whoever wrote the file, an AI posting under its own
speaker name is signed with that name and cannot be talked out of it by a prompt.

`AI-DJ.md` is the self-contained runbook for an outside agent.

`[measured]` every endpoint above (§8).

---

## 8. Verification, 2026-08-24

All 23 station endpoints exercised against the live 2.5.0 build, with
state-changing calls paired with their inverse:

```
GET   /control/now  /control/knobs  /control/show  /earlier  /likes/now
      /control/search  /control/queue                                    all pass
POST  /control/pause  /music  /repeat        set and restored, all pass
POST  /control/talking  /again  /skip  /previous                         all pass
POST  /control/enqueue  /queue/add  /queue/remove  /queue/move  /queue/clear
POST  /likes/add  /tug/keep  /tug/skip                                   all pass
POST  /control/show                          set and restored, pass
```

Pages: `/` and `/shows/` and `/next/` serve; `/host`, `/admin`, `/whoami`,
`/adminapi/*` correctly return 401 with their own realms.

Services: `LiquidsoapRadio`, `CaddyServer`, `IcecastServer` running;
`RadioAdminWatcher`, `RadioLiveBridge`, `RadioNarratorWatcher` running.

**Memory, after the 2.5.0 migration:** 24 minutes, ranging 159.9–162.5 MB and
ending where it started. Net +0.1 MB. The previous build leaked 3.31 MB/min at
idle and reached 16 GB in 75 hours.

---

## 9. Admin

At `/admin`, behind a second credential separate from the host one.

- **Create a speaker** — mints a credential for a new host.
- **Restart the radio.**
- Requests go through a file-based request/response queue that a watcher picks
  up, so the web page never holds privileges of its own.

`[measured]` served and challenged; `mint-speaker.ps1` and `admin-watcher.ps1`
present; the watcher handles disable and restart.
`[read]` the create flow. Deleting a host is done by disabling rather than by an
explicit delete.

---

## 10. Under it

```
liquidsoap 2.5.0    the station: library, mixing, ducking, harbor, HTTP surface
icecast 2.4.4       fan-out to listeners
caddy               TLS, credentials, static files, webdav, rate limits
live-bridge.js      the console's websocket -> the station's source protocol
three watchers      admin requests, the narrator, and the live bridge
```

The station holds the mount continuously and never goes silent — "music off" is
a gain of zero and "pause" is a switch to silence, because a missing source drops
the mount and disconnects everyone.

---

## Known gaps

- **The shows archive lists cards, not audio.** The recordings are on disk and
  the page does not know about them yet. They also end unfinalised — playable,
  but a browser cannot seek or show length until they are remuxed.
- **No offline mode in the console.** A note recorded without a connection is
  lost; queueing needs IndexedDB.
- **No screen wake lock**, so an Android host's screen sleeps mid-broadcast.
- **Bucket-DJing from Android is not possible** (§3).
- **The tab watcher is unproven against a real tab.**
- **The clipboard copy fallback on plain http** is untested.
- **No transcription.** There is no Whisper on the machine.
