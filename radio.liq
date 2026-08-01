# Wild n Loyal Radio - the whole station.
#
# Plays the library unattended, and steps aside the moment a live source
# connects to harbor. Passwords come from the service environment so this
# file is safe to keep in the repo.

settings.log.level        := 3
settings.log.file         := true
settings.log.file.path    := "D:/Liquidsoap/log/radio.log"
settings.log.stdout       := true

# Control socket: skip a track, inspect what is playing. Bound to loopback,
# so it is reachable only from Dolly itself (i.e. over ssh).
#   telnet localhost 1234   ->   help / skip / uptime
settings.server.telnet           := true
settings.server.telnet.bind_addr := "127.0.0.1"
settings.server.telnet.port      := 1234

# The library. randomize + watch so new files appear without a restart.
music = playlist(
  id          = "library",
  mode        = "randomize",
  reload_mode = "watch",
  "D:/Music"
)

# Never go silent, whatever happens upstream.
music = mksafe(music)

# Live input. Mixxx, or any icecast source client, from anywhere.
live = input.harbor(
  id       = "live",
  "live",
  port     = 8005,
  password = environment.get("RADIO_HARBOR_PASSWORD"),
  buffer   = 5.0,
  max      = 15.0
)

# Live wins the moment it connects; falls back mid-track when it drops.
radio = fallback(id = "switch", track_sensitive = false, [live, music])

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
