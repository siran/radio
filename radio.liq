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

# --- knobs -----------------------------------------------------------------
# Every one of these can be changed WHILE THE STATION IS RUNNING, from the
# mixing desk page. No restart, no gap in the audio.

# voice chain
mic_gain   = interactive.float("mic_gain",   min = 0.0,   max = 4.0,   step = 0.1, 1.0)
hp_freq    = interactive.float("hp_freq",    min = 40.0,  max = 300.0, step = 5.0, 90.0)
comp_thr   = interactive.float("comp_thr",   min = -40.0, max = 0.0,   step = 1.0, -18.0)
comp_ratio = interactive.float("comp_ratio", min = 1.0,   max = 20.0,  step = 0.5, 4.0)
comp_gain  = interactive.float("comp_gain",  min = 0.0,   max = 24.0,  step = 0.5, 6.0)

# ducking
duck_to    = interactive.float("duck_to",    min = 0.0,  max = 1.0,  step = 0.05, 0.35)
on_thresh  = interactive.float("on_thresh",  min = 0.0,  max = 0.2,  step = 0.005, 0.02)
off_thresh = interactive.float("off_thresh", min = 0.0,  max = 0.2,  step = 0.005, 0.01)
hold       = interactive.float("hold",       min = 0.0,  max = 6.0,  step = 0.25, 1.5)
glide      = interactive.float("glide",      min = 0.01, max = 0.5,  step = 0.01, 0.05)

# Expose all of the above over harbor's http server, so the desk can read and
# set them. Same process, no extra service.
interactive.harbor(port = 8005)

# The library. randomize + watch so new files appear without a restart.
music = playlist(
  id          = "library",
  mode        = "randomize",
  reload_mode = "watch",
  "D:/Music"
)

# Never go silent, whatever happens upstream.
music = mksafe(music)

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

# --- the voice chain -------------------------------------------------------
# This is what makes a phone microphone sound like radio rather than like a
# phone. The compressor matters more than any amount of EQ: it closes the gap
# between leaning into the mic and sitting back from it.

# 1. input gain, in case the source is quiet
live = amplify(mic_gain, live)

# 2. high-pass: handling noise, desk bumps and room rumble live below ~90Hz
#    and only eat headroom.
live = filter(freq = hp_freq, mode = "high", live)

# 3. compressor: even out the level. attack fast enough to catch a shout,
#    release slow enough not to breathe between words.
live = compress(
  threshold = comp_thr,
  ratio     = comp_ratio,
  attack    = 10.0,
  release   = 200.0,
  gain      = comp_gain,
  live
)

# 4. measure AFTER the chain, so the ducking follows what listeners hear
#    rather than the raw input.
live = rms(id = "mic", duration = 0.3, live)

# --- ducking ---------------------------------------------------------------
music_gain = ref(1.0)
talking    = ref(false)
quiet_for  = ref(0.0)

def duck_gain() =
  # is_ready is the honest signal: rms keeps reporting its last value after a
  # source drops, so on its own it would leave the music dipped.
  ready = connected() and live.is_ready()
  level = if ready then live.rms() else 0.0 end

  if talking() then
    if not ready or level < off_thresh() then
      quiet_for := quiet_for() + 0.04
      if quiet_for() >= hold() then
        talking := false
        log.important(label = "duck", "music back up")
      end
    else
      quiet_for := 0.0
    end
  elsif ready and level > on_thresh() then
    talking   := true
    quiet_for := 0.0
    log.important(label = "duck", "music down")
  end

  target = if talking() then duck_to() else 1.0 end
  music_gain := music_gain() + (target - music_gain()) * glide()
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
