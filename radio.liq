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
  unit = "x", min = 0.0, max = 4.0, step = 0.1, 3.5)

voice_gain = interactive.float("voice_gain",
  description = "Volume of uploaded voice notes. Phone recordings arrive quiet, so this sits high.",
  unit = "x", min = 0.0, max = 12.0, step = 0.25, 12.0)

hp_freq    = interactive.float("hp_freq",
  description = "Cuts rumble below this. Handling noise and desk bumps live down here.",
  unit = "Hz", min = 40.0, max = 300.0, step = 5.0, 295.0)

comp_thr   = interactive.float("comp_thr",
  description = "Compressor: the level above which your voice starts being held back. Lower = more evening out.",
  unit = "dB", min = -40.0, max = 0.0, step = 1.0, -29.0)

comp_ratio = interactive.float("comp_ratio",
  description = "Compressor: how hard it holds back. 1 = off, 4 = normal speech, 10+ = squashed.",
  unit = ":1", min = 1.0, max = 20.0, step = 0.5, 3.5)

comp_gain  = interactive.float("comp_gain",
  description = "Make-up volume, added AFTER the compressor. This is the one to raise if you are still too quiet.",
  unit = "dB", min = 0.0, max = 24.0, step = 0.5, 17.5)

# ducking
duck_to    = interactive.float("duck_to",
  description = "How loud the music stays while someone talks. 1.0 = untouched, 0.0 = silent.",
  unit = "x", min = 0.0, max = 1.0, step = 0.05, 0.45)

hold       = interactive.float("hold",
  description = "Seconds of quiet before the music comes back up. Covers pauses and gaps between clips.",
  unit = "s", min = 0.0, max = 30.0, step = 0.5, 28.0)

glide      = interactive.float("glide",
  description = "How fast the music fader moves. Smaller is slower and smoother.",
  unit = "", min = 0.01, max = 0.5, step = 0.01, 0.01)


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

# Whether a live source is connected. Asking the source itself is not
# reliable - a dropped one goes on looking alive for a while - so track the
# connect and disconnect callbacks, and duck the music off that.
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

# Four lanes, mixed together. A speaker always lands in the same lane, so
# their own slices stay in order; different speakers get different lanes, so
# they overlap instead of queueing behind each other. Best effort, not a
# reconstruction of who spoke exactly when - but with a name in the filename
# it costs almost nothing.
# How many people can be talking at once. Liquidsoap fixes its source graph at
# startup, so this has to be a number rather than "however many turn up" - but
# an idle queue costs essentially nothing, so it can be generous. Past this,
# speakers share a lane and serialise behind each other; nothing is lost.
lane_count = 8
queues = list.init(lane_count, fun (i) -> request.queue(id = "voice#{i}"))

# Each speaker plays at their own volume. A lane only ever plays one note at a
# time, so wrapping the lane - rather than the mix - makes the gain per note:
# `override` reads liq_amplify off whatever that lane is playing right now.
# A note with no settings carries no annotation, and falls back to voice_gain.
lanes = list.map(fun (q) -> amplify(override = "liq_amplify", voice_gain, q), queues)

voice = add(id = "voices", normalize = false, lanes)

# who has which lane, assigned on first appearance
lane_of   = ref([])
next_lane = ref(0)
seen      = ref([])

# Files are named  speaker--timestamp-seq-rand.ext
# Anything without a speaker prefix is treated as "guest".
def speaker_of(fpath) =
  # The speaker is the folder the file sits in, and caddy creates that folder
  # from whoever logged in - so it cannot be spoofed by naming a file cleverly.
  # file.ls hands back MIXED separators: forward slashes for the directory it
  # was given, backslashes for whatever it walked into. The path.* functions
  # only understand "/", so split on either. The separator is a REGEX, hence a
  # character class rather than a bare backslash.
  parts = string.split(separator = "[\\\\/]", fpath)
  n     = list.length(parts)
  d     = if n >= 2 then list.nth(default = "voice", parts, n - 2) else "voice" end
  if d == "voice" then "guest" else d end
end
def lane_for(name) =
  known = list.assoc(default = -1, name, lane_of())
  if known >= 0 then
    known
  else
    l = next_lane()
    next_lane := (l + 1) mod lane_count
    lane_of := list.add((name, l), lane_of())
    log.important(label = "voice", "#{name} is on lane #{l}")
    l
  end
end

# Each speaker's settings are one json file in their own folder, written by
# the talk page over webdav:
#
#   { "gain": 2.5, "duck": true }
#
# Both values ride with the note as annotations, so they apply to that note
# alone: the lane reads liq_amplify, the ducking further down reads liq_duck.
#
# json.parse throws on anything that is not exactly that shape - no file, an
# empty file, one caught half-written by a poll running four times a second,
# one saved with a BOM - and every one of those means "no settings", so catch
# the lot and queue the bare path, which falls back to voice_gain and no
# ducking. It has to be a function of its own: `x = try ... end` does not
# parse, a try is only allowed where a statement is.
def note_uri(who, f) =
  try
    let json.parse ( cfg : { gain : float, duck : bool } ) =
      file.contents("#{voice_dir}/#{who}/settings.json")
    "annotate:liq_amplify=\"#{cfg.gain}\",liq_duck=\"#{cfg.duck}\":#{f}"
  catch _ do
    f
  end
end

def pickup() =
  # file.ls with recursive=true ignores `pattern` entirely - patterns do not
  # cross a directory separator - and it returns directories alongside files.
  # So list everything one level down and filter on the extension ourselves.
  # whatsapp sends ogg/opus, telegram .oga, ios .m4a, the browser .webm
  # there is no path.extension, but remove_extension exists: a file ends in
  # .ogg exactly when stem ^ ".ogg" is the name again.
  exts = ["webm", "ogg", "oga", "opus", "mp3", "m4a", "wav",
          "WEBM", "OGG", "OGA", "OPUS", "MP3", "M4A", "WAV"]
  def is_audio(f) =
    stem = path.remove_extension(f)
    list.exists(fun (e) -> stem ^ ".#{e}" == f, exts)
  end
  files =
    list.filter(is_audio,
      file.ls(voice_dir, absolute = true, sorted = true, recursive = true))

  list.iter(
    fun (f) ->
      if not list.mem(f, seen()) then
        seen := list.add(f, seen())
        who  = speaker_of(f)
        l    = lane_for(who)
        q    = list.nth(queues, l)
        uri  = note_uri(who, f)
        q.push.uri(uri)
        log.important(label = "voice", "queued #{who} -> lane #{l}: #{uri}")
      end,
    files)

  # These are disposable. Anything older than five minutes has certainly been
  # played, so bin it rather than accumulating someone's voice on disk.
  #
  # A note the service account cannot read is also one it cannot delete, and a
  # path dropped from `seen` looks new again on the very next poll - so
  # forgetting a file we did not actually get rid of re-queues it four times a
  # second, forever. Only forget a path once the file is really gone; a note
  # left on disk is much the cheaper problem. The second `seen` entry earns its
  # keep by holding the warning to one line instead of one per poll.
  list.iter(
    fun (f) ->
      if file.mtime(f) < time() - 300.0 then
        file.remove(f)
        if not file.exists(f) then
          seen := list.filter(fun (s) -> s != f, seen())
        elsif not list.mem("undeletable:#{f}", seen()) then
          seen := list.add("undeletable:#{f}", seen())
          log.important(label = "voice",
            "cannot delete #{f} - leaving it on disk, will not queue it again")
        end
      end,
    files)
end

thread.run(every = 0.25, pickup)

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
#    the two can overlap rather than interrupt. The notes arrive already at
#    their own speaker's gain, applied back in the lanes.
talk = add(id = "talk", normalize = false, [live, voice])

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

# 5. limiter. Eight lanes summing with normalize=false means eight people
#    talking at once can overshoot badly, and the make-up gain makes that
#    worse. This is the guard rail: inaudible when one person speaks, and it
#    keeps a crowd from turning into distortion.
talk = limit(threshold = -2.0, talk)

# --- ducking ---------------------------------------------------------------
# The music dips for the live mic, and for a voice note whose speaker asked
# for it in their settings.json. Two of them can be on air at once with
# different answers, so it is enough that ANY lane playing right now carries
# liq_duck: the one who wanted the dip gets it, and the other simply talks
# over music that happens to be down.
music_gain = ref(1.0)
talking    = ref(false)
quiet_for  = ref(0.0)

def duck_gain() =
  # A lane keeps its last metadata after the note has finished, so is_ready is
  # what says a note is still on air; the annotation only says what that
  # speaker wanted.
  ducking =
    connected()
    or list.exists(
         fun (q) ->
           if q.is_ready() then
             m = q.last_metadata() ?? []
             m["liq_duck"] == "true"
           else
             false
           end,
         queues)

  if ducking then
    if not talking() then
      talking := true
      log.important(label = "duck", "music down")
    end
    quiet_for := 0.0
  elsif talking() then
    # Slices arrive about 1.5s apart, so hold is what keeps the music from
    # pumping back up in the gap between one clip and the next.
    quiet_for := quiet_for() + 0.04
    if quiet_for() >= hold() then
      talking := false
      log.important(label = "duck", "music back up")
    end
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
