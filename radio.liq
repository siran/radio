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
mic_gain   = interactive.float("mic_gain",
  description = "Live microphone volume. Raise if the mic sounds far away.",
  unit = "x", min = 0.0, max = 4.0, step = 0.1, 1.0)

voice_gain = interactive.float("voice_gain",
  description = "Volume of uploaded voice notes. Phone recordings arrive quiet, so this sits high.",
  unit = "x", min = 0.0, max = 12.0, step = 0.25, 5.0)

hp_freq    = interactive.float("hp_freq",
  description = "Cuts rumble below this. Handling noise and desk bumps live down here.",
  unit = "Hz", min = 40.0, max = 300.0, step = 5.0, 90.0)

comp_thr   = interactive.float("comp_thr",
  description = "Compressor: the level above which your voice starts being held back. Lower = more evening out.",
  unit = "dB", min = -40.0, max = 0.0, step = 1.0, -18.0)

comp_ratio = interactive.float("comp_ratio",
  description = "Compressor: how hard it holds back. 1 = off, 4 = normal speech, 10+ = squashed.",
  unit = ":1", min = 1.0, max = 20.0, step = 0.5, 4.0)

comp_gain  = interactive.float("comp_gain",
  description = "Make-up volume, added AFTER the compressor. This is the one to raise if you are still too quiet.",
  unit = "dB", min = 0.0, max = 24.0, step = 0.5, 9.0)

# ducking
duck_to    = interactive.float("duck_to",
  description = "How loud the music stays while someone talks. 1.0 = untouched, 0.0 = silent.",
  unit = "x", min = 0.0, max = 1.0, step = 0.05, 0.3)

on_thresh  = interactive.float("on_thresh",
  description = "How loud you must be before the music dips.",
  unit = "rms", min = 0.0, max = 0.2, step = 0.005, 0.02)

off_thresh = interactive.float("off_thresh",
  description = "How quiet counts as having stopped talking.",
  unit = "rms", min = 0.0, max = 0.2, step = 0.005, 0.01)

hold       = interactive.float("hold",
  description = "Seconds of quiet before the music comes back up. Covers pauses and gaps between clips.",
  unit = "s", min = 0.0, max = 30.0, step = 0.5, 1.5)

glide      = interactive.float("glide",
  description = "How fast the music fader moves. Smaller is slower and smoother.",
  unit = "", min = 0.01, max = 0.5, step = 0.01, 0.05)


# The mixing desk: liquidsoap's own page for the knobs above, at
# /interactive on the harbor port. Must NOT use the default port - that is
# 8000, which icecast owns, and the collision takes the station off air.
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
  timeout       = 20.0,
  on_connect    = fun (_) -> connected := true,
  on_disconnect = fun () -> connected := false
)

# --- voice notes -----------------------------------------------------------
# A folder that anything can drop audio into - the browser over webdav, a
# script, eGPT. Whatever appears is played once, over the ducked music. No
# streaming protocol involved: each file arrives as an ordinary upload with a
# content length, which is the part that has proven reliable.

voice_dir = "C:/Users/an/src/radio/messages/voice"
voice     = request.queue(id = "voice")
seen      = ref([])

def pickup() =
  # whatsapp sends ogg/opus, telegram .oga, ios .m4a, the browser .webm
  files =
    list.fold(
      fun (acc, ext) -> list.append(acc,
        file.ls(voice_dir, absolute = true, sorted = true, pattern = "*.#{ext}")),
      [],
      ["webm", "ogg", "oga", "opus", "mp3", "m4a", "wav"])

  list.iter(
    fun (f) ->
      if not list.mem(f, seen()) then
        seen := list.add(f, seen())
        voice.push.uri(f)
        log.important(label = "voice", "queued #{f}")
      end,
    files)
end

thread.run(every = 2.0, pickup)

# --- the voice chain -------------------------------------------------------
# This is what makes a phone microphone sound like radio rather than like a
# phone. The compressor matters more than any amount of EQ: it closes the gap
# between leaning into the mic and sitting back from it.

# 1. input gain, in case the source is quiet
live = amplify(mic_gain, live)

# 2. high-pass: handling noise, desk bumps and room rumble live below ~90Hz
#    and only eat headroom.
live = filter(freq = hp_freq, mode = "high", live)

# 3. the mic and the voice notes are one bus, so either ducks the music and
#    the two can overlap rather than interrupt. Notes get their own gain -
#    a phone recording arrives far quieter than a headset.
talk = add(id = "talk", normalize = false, [live, amplify(voice_gain, voice)])

# 4. compressor on the WHOLE bus, so an uploaded note is levelled exactly like
#    the live mic. Putting it on the mic alone left notes uncompressed and
#    inaudible.
talk = compress(
  threshold = comp_thr,
  ratio     = comp_ratio,
  attack    = 10.0,
  release   = 200.0,
  gain      = comp_gain,
  talk
)

# 5. measure AFTER the chain, so the ducking follows what listeners hear.
talk = rms(id = "mic", duration = 0.3, talk)

# --- ducking ---------------------------------------------------------------
music_gain = ref(1.0)
talking    = ref(false)
quiet_for  = ref(0.0)

def duck_gain() =
  # is_ready is the honest signal: rms keeps reporting its last value after a
  # source drops, so on its own it would leave the music dipped.
  ready = talk.is_ready() and (connected() or not list.is_empty(seen()))
  level = if ready then talk.rms() else 0.0 end

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
radio = add(id = "mix", normalize = false, [music, talk])

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
