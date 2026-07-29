# Wild n Loyal Radio

A self-hosted internet radio station and its website. Music plays from a local
library, you can talk over it live, and listeners hear it in a browser on a
page that anyone can edit.

Nothing here is a platform or a framework. It's a handful of small parts, each
doing one thing, wired together.

## The pieces

```
  music files ──→ Mixxx ──┐
                          ├──→ Icecast ──┐
    microphone ───────────┘              │
                                         ├──→ Caddy ──→ listeners
                     index.html ─────────┤
                                         │
                     guestbook (node) ───┘
```

**Mixxx** is the studio. Two decks, a crossfader, and a microphone channel.
It plays tracks from a folder of music files and encodes the result into a
stream. It also has an **Auto DJ** that plays a crate continuously, so the
station keeps going when nobody is at the controls.

**Voice over the radio** is Mixxx's *talkover*: hold the mic button and the
music ducks automatically underneath your voice, then comes back up when you
stop. That's the whole DJ mechanism — no separate mixer, no audio routing
between applications, because Mixxx owns both the decks and the microphone.

**Icecast** is the transmitter. It receives one stream from Mixxx and fans it
out to however many listeners connect. It knows nothing about the music; it
just relays bytes and the title of whatever is currently playing.

**Caddy** is the only thing listening on the public internet. It terminates
TLS and puts everything on one address:

| Path | Caddy does |
|---|---|
| `/` | serves `index.html` from this folder — plain static file |
| `/stream` | proxies to Icecast |
| `/status-json.xsl` | proxies to Icecast |
| `/api/*` | proxies to the guestbook |

So the website is **not** served by an application. It's a file on disk that
Caddy hands out. Nothing renders it, nothing builds it, and if the guestbook
process is dead the site still loads and the radio still plays — you just
can't post a message.

## The website

`index.html` is a single file with no build step, no framework, and no
dependencies. The proxy serves this folder directly, so **editing the file and
refreshing the browser is the entire deploy.**

It reads everything it displays live from Icecast — station name, description,
current track, listener count, uptime, bitrate. Nothing is hardcoded, so
changing the station name in Mixxx changes the website.

It also registers media metadata, so on a phone the lock screen shows the
station and the current track with working play controls.

## The file database

The guestbook has no database. Messages are **plain text files**, one per day,
one JSON object per line:

```
messages/2026-07-29.jsonl
```
```json
{"at":"2026-07-29T18:53:14Z","name":"Claude","text":"hello","playing":"Art Farmer - The Very Thought Of You"}
```

Every message records **what was playing when it was written** — the station
is the timestamp. You can read the files in any editor, grep them, edit them,
delete a line, or sort them with ordinary tools. They're committed to this
repository, so the guestbook is versioned along with the site.

That's the whole storage layer. It survives having no server running, needs no
migrations, and you can understand all of it by looking at it.

### API

```
POST /api/message   {name, text}   → appends a line to today's file
GET  /api/messages                 → recent entries
```

`message-server.js` is dependency-free Node. It binds to loopback only and
sits behind the proxy. Rate limited per address (one message per 20 seconds,
twelve per hour), length capped, honeypot field for bots, **no IP addresses
stored**, and messages are rendered with `textContent` so nothing a visitor
writes can inject markup.

## Files

| File | What |
|---|---|
| `index.html` | the whole website |
| `message-server.js` | guestbook API |
| `messages/*.jsonl` | the messages, one file per day |

## Running it

Three long-running things, none of which serve the website by themselves:

1. **Icecast** — the transmitter. Mixxx connects to it as a source client.
2. **Caddy** — serves this folder as static files, and proxies `/stream`,
   `/status-json.xsl` and `/api/*`. This is what listeners actually talk to.
3. **The guestbook** — `node message-server.js`, listening on loopback:8787.
   Optional; without it the site works and only posting fails.

Caddy config, roughly:

```caddyfile
radio.example.org {
    root * /path/to/this/folder
    handle /stream*          { reverse_proxy 127.0.0.1:8000 { flush_interval -1 } }
    handle /status-json.xsl* { reverse_proxy 127.0.0.1:8000 }
    handle /api/*            { reverse_proxy 127.0.0.1:8787 }
    handle                   { file_server }
}
```

`flush_interval -1` on the audio route matters — without it the proxy buffers
a live stream, and listeners get silence followed by bursts.

## Note

Message files are committed, so anything a visitor writes becomes part of this
repository's history.
