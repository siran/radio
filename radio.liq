# Wild n Loyal Radio - the whole station.
#
# Plays the library unattended. A live source connecting to harbor is mixed ON
# TOP of the music, and the music dips under it automatically - so from away you
# send only a microphone and the library stays here on Dolly.
#
# Passwords come from the service environment, which is what makes this file
# safe to keep in the repo.

settings.log.level        := 3
settings.log.file         := true
settings.log.file.path    := "D:/Liquidsoap/log/radio.log"
settings.log.stdout       := true

# Control socket: skip a track, inspect what is playing. Bound to loopback,
# so it is reachable only from Dolly itself (i.e. over ssh).
#   telnet localhost 1234   ->   help / out.skip / out.remaining / uptime
settings.server.telnet           := true
settings.server.telnet.bind_addr := "127.0.0.1"
settings.server.telnet.port      := 1234

# --- tuning, all by ear ---------------------------------------------------
duck_to    = 0.35   # music level while you talk. 1.0 = untouched, 0.0 = silent
on_thresh  = 0.02   # get this loud and the music dips
off_thresh = 0.01   # drop below this to start counting as quiet
hold       = 1.5    # seconds of quiet before the music comes back
glide      = 0.05   # how fast the fader moves. smaller = slower and smoother

# The library. randomize + watch so new files appear without a restart.
music = playlist(
  id          = "library",
  mode        = "randomize",
  reload_mode = "watch",
  "D:/Music"
)

# Never go silent, whatever happens upstream.
music = mksafe(music)

# Live input. butt, a phone app, Mixxx - anything speaking icecast source.
# rms() keeps returning its last value after a source drops, so ducking on
# loudness alone would leave the music dipped forever once you disconnect.
# Track the connection itself and require both.
connected = ref(false)

live = input.harbor(
  id            = "live",
  "live",
  port          = 8005,
  password      = environment.get("RADIO_HARBOR_PASSWORD"),
  buffer        = 1.0,
  max           = 10.0,
  timeout       = 8.0,
  on_connect    = fun (_) -> connected := true,
  on_disconnect = fun () -> connected := false
)

# Measure how loud the live input actually is, over a short window. This is
# what makes the music dip when you speak rather than when you connect.
live = rms(id = "mic", duration = 0.3, live)

# Glide the music gain toward its target instead of stepping to it, so the dip
# sounds like a hand on a fader rather than a click.
music_gain = ref(1.0)
talking    = ref(false)
quiet_for  = ref(0.0)

def duck_gain() =
  # is_ready is the honest signal: rms keeps reporting its last value after a
  # source drops, so on its own it would leave the music dipped.
  ready = connected() and live.is_ready()
  level = if ready then live.rms() else 0.0 end

  if talking() then
    if not ready or level < off_thresh then
      quiet_for := quiet_for() + 0.04
      if quiet_for() >= hold then
        talking := false
        log.important(label = "duck", "music back up")
      end
    else
      quiet_for := 0.0
    end
  elsif ready and level > on_thresh then
    talking   := true
    quiet_for := 0.0
    log.important(label = "duck", "music down")
  end

  target = if talking() then duck_to else 1.0 end
  music_gain := music_gain() + (target - music_gain()) * glide
  music_gain()
end

music = amplify(duck_gain, music)

# Music first, so the track title still shows while you are talking over it.
# normalize=false so levels do not jump when the live source connects.
radio = add(id = "mix", normalize = false, [music, live])

# `add` drops track marks, and the title rides with them - without this the
# stream plays fine and the song name never reaches icecast.
def forward_meta(m) =
  t = m["title"]
  log.important(label = "meta", "forwarding #{t}")
  radio.insert_metadata(new_track = true, m)
end
music.on_metadata(synchronous = false, forward_meta)

output.icecast(
  %ffmpeg(format = "mp3", %audio(codec = "libmp3lame", b = "128k", ar = 44100, ac = 2)),
  id          = "out",
  host        = "127.0.0.1",
  port        = 8000,
  password    = environment.get("RADIO_ICECAST_PASSWORD"),
  mount       = "/stream",
  name        = "Wild n Loyal Radio",
  description = "Live from NYC",
  genre       = "Various",
  url         = "https://radio.wildnloyal.org",
  radio
)
