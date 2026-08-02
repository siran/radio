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

# The control endpoints further down reach into the playlist itself: `current`,
# `queue`, `set_queue` and `skip` are methods of THIS value. mksafe and amplify
# below hand back plain sources that no longer carry them, and `music` is the
# name that gets reassigned - so hold on to the playlist here, before it is
# wrapped, or the endpoints have nothing to talk to.
library = music

# Never go silent, whatever happens upstream.
music = mksafe(music)

# --- driving the music -----------------------------------------------------
# Music off and paused are both SILENCE, never a missing source. Take the music
# out of the mix and the icecast output loses its source, the mount drops and
# every listener is disconnected - which is exactly what the mksafe above
# exists to prevent. So "off" is a gain of zero and "pause" is a switch to
# blank(); both leave something that is always ready to stream.
#
# They are not two names for one thing. With the music off the record keeps
# turning, so you come back partway into whatever is playing by then. Pause
# stops pulling the playlist at all - liquidsoap sources only advance when
# something asks them for a frame - so it resumes on the note it stopped on.
music_on  = ref(true)
paused    = ref(false)
repeating = ref(false)

music = amplify({if music_on() then 1.0 else 0.0 end}, music)

# replay_metadata = false: on the way back from a pause the switch would
# otherwise re-announce the child's last metadata, and forward_meta at the
# bottom of this file turns every metadata into a NEW TRACK in the mix. The
# stream would report a fresh song starting for one that never restarted.
music = switch(
  track_sensitive = false,
  replay_metadata = false,
  [({not paused()}, music), ({true}, blank())]
)

# What is on the air right now. The path is the point - it is how the operator
# finds the actual file in D:/Music - so it comes from the request rather than
# from metadata, which carries a title and an artist but no reliable filename.
def current_file() =
  r = library.current()
  if null.defined(r) then request.filename(null.get(r)) else "" end
end

def now_playing() =
  m = library.last_metadata() ?? []
  {
    path   = current_file(),
    title  = m["title"],
    artist = m["artist"],
    music  = music_on(),
    paused = paused(),
    repeat = repeating()
  }
end

# Play the current track once more: a fresh request for the same file, put at
# the FRONT of the playlist's queue. `library.add` is the obvious call and it
# is the wrong one - it appends BEHIND whatever the playlist has already
# prefetched, so the repeat would land a track late.
def again() =
  f = current_file()
  if f != "" then
    library.set_queue(list.add(request.create(f), library.queue()))
    log.important(label = "control", "playing again: #{f}")
  end
end

# Repeat re-queues the track shortly before it ends rather than when it starts.
# Deciding late is what makes switching repeat off take effect immediately: do
# it at the start of a track and there is always one more copy already
# committed to the queue that nobody asked for.
library.on_position(position = 2.0, remaining = true, synchronous = false,
  fun (_, _) -> if repeating() then again() end)

# The HTTP surface. It rides on the harbor that is already up on 8005, the one
# the mixing desk uses; caddy puts it behind the speaker credential. NOT 8000:
# that is icecast's, and the collision takes the station off the air while
# liquidsoap logs "Connection setup was successful" either way, which makes it
# look like it worked.
#
# Every endpoint answers with the same state object, so a page can act and
# redraw from one response. `on` always means "this named thing is on":
# music?on=false is silence, pause?on=true is frozen, repeat?on=true loops.
def endpoint(act) =
  fun (req, response) -> begin
    act(req)
    response.json(now_playing())
  end
end

def on_flag(req) =
  req.query["on"] == "true"
end

harbor.http.register(port = 8005, method = "GET", "/control/now",
  endpoint(fun (_) -> ()))
harbor.http.register(port = 8005, method = "POST", "/control/skip",
  endpoint(fun (_) -> library.skip()))
harbor.http.register(port = 8005, method = "POST", "/control/again",
  endpoint(fun (_) -> again()))
harbor.http.register(port = 8005, method = "POST", "/control/repeat",
  endpoint(fun (r) -> repeating := on_flag(r)))
harbor.http.register(port = 8005, method = "POST", "/control/music",
  endpoint(fun (r) -> music_on := on_flag(r)))
harbor.http.register(port = 8005, method = "POST", "/control/pause",
  endpoint(fun (r) -> paused := on_flag(r)))

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

# Each speaker plays at their own volume, through their own three-band EQ. A
# lane only ever plays one note at a time, so wrapping the lane - rather than
# the mix - makes both of them per note: `override` reads liq_amplify off
# whatever that lane is playing right now, and the getters below read the eq
# bands off the same note the same way.
# A note with no settings carries no annotation, and falls back to voice_gain
# and to a flat EQ.

# One band of one lane, in dB, read fresh off whatever that lane is playing.
# The filter has no `override` the way amplify does, so the gain is given as a
# GETTER - {...}, re-evaluated as it runs - which reaches into the queue's own
# last_metadata exactly as the ducking further down does for liq_duck.
# Measured on this build: a peak filter given a getter for `gain` really does
# follow it live, and gain 0.0 is unity to the last digit, so a speaker with no
# eq is passed through untouched rather than merely almost untouched.
# float_of_string with a default is what makes a missing or malformed band mean
# flat instead of throwing inside the streaming loop, where a throw would be
# very expensive and very quiet.
def eq_db(q, band) =
  m = q.last_metadata() ?? []
  float_of_string(default = 0.0, m["liq_eq_#{band}"])
end

# Three bells, not a shelf/peak/shelf. filter.iir.eq.lowshelf and .highshelf
# exist in this build but neither takes a gain, only a `slope`, and measured
# here they are not usable as tone controls: a 100Hz tone through
# lowshelf(frequency=500) comes out 56dB DOWN, slope 1 vs 40 barely moves it,
# and a negative slope returns inf. filter.iir.eq.peak is the one that behaves
# - unity away from its centre, exactly +6.0dB at centre for gain=6.0 - so all
# three bands are peaks. That also buys the property the sliders need most:
# 0 dB everywhere is EXACTLY flat.
#
# Wide bells (q 0.7) on purpose. These are bass/mid/treble on a radio, not
# three surgical notches; they overlap, so a small move sounds like a tone
# control rather than like a hole. Centres chosen for a phone mic outdoors:
#   160 Hz  body and boom. Wide enough to reach down into the handling
#           rumble and wind that a phone held in the hand picks up, and up
#           into the chest of the voice. There is no high-pass on the notes -
#           hp_freq only guards the live mic - so this is the only thing that
#           can take that weight out.
#   1000 Hz the boxy, honky middle a small capsule adds. Cutting here opens
#           the voice up; boosting pushes it forward through the music.
#   4000 Hz consonants and clarity. Not 8k: bluetooth and a 96kbps opus note
#           have very little left up there, so a high shelf that far up would
#           be boosting codec hiss rather than the voice. 4k is also where
#           "carrasposa" lives, so this is the slider that fixes it - in
#           whichever direction it turns out to need.
#
# The three getters are bound BEFORE the amplify, and that order matters:
# amplify's argument is a plain source, so passing the queue to it first pins
# this function's parameter to a plain source and the later q.last_metadata()
# stops typechecking with "this value has no method last_metadata". Reading
# the metadata first is what keeps the queue's own methods in view.
def voice_lane(q) =
  low  = {eq_db(q, "low")}
  mid  = {eq_db(q, "mid")}
  high = {eq_db(q, "high")}
  l = amplify(override = "liq_amplify", voice_gain, q)
  l = filter.iir.eq.peak(frequency =  160.0, q = 0.7, gain = low,  l)
  l = filter.iir.eq.peak(frequency = 1000.0, q = 0.7, gain = mid,  l)
  l = filter.iir.eq.peak(frequency = 4000.0, q = 0.7, gain = high, l)
  l
end

lanes = list.map(voice_lane, queues)

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
#   { "gain": 2.5, "duck": true, "eq": { "low": 0, "mid": 0, "high": 0 } }
#
# All of it rides with the note as annotations, so it applies to that note
# alone: the lane reads liq_amplify and the three liq_eq_* bands, the ducking
# further down reads liq_duck.
#
# `eq` is optional - the trailing `?` on its type - because every speaker's
# file predates it and says only gain and duck. Measured on this build: with
# the `?` an old two-key file parses fine and cfg.eq comes back null, while
# without it the whole parse would throw and that speaker would silently lose
# their volume and their ducking too. Missing means flat, and flat means all
# three bands at 0 dB, which the filters pass through untouched.
#
# json.parse throws on anything that is not that shape - no file, an empty
# file, one caught half-written by a poll running four times a second, one
# saved with a BOM, one truncated by too small a request_body cap in caddy -
# and every one of those means "no settings", so catch the lot and queue the
# bare path, which falls back to voice_gain, no ducking and a flat EQ. It has
# to be a function of its own: `x = try ... end` does not parse, a try is only
# allowed where a statement is.
def note_uri(who, f) =
  try
    let json.parse ( cfg : {
      gain : float,
      duck : bool,
      eq   : { low : float, mid : float, high : float }?
    } ) = file.contents("#{voice_dir}/#{who}/settings.json")
    eq = cfg.eq ?? { low = 0.0, mid = 0.0, high = 0.0 }
    "annotate:liq_amplify=\"#{cfg.gain}\",liq_duck=\"#{cfg.duck}\""
    ^ ",liq_eq_low=\"#{eq.low}\",liq_eq_mid=\"#{eq.mid}\""
    ^ ",liq_eq_high=\"#{eq.high}\":#{f}"
  catch _ do
    f
  end
end

# When this process started. A note whose file was written before this is one
# the station was down for, and playing it late is worse than never playing
# it: a three minute old "hello everyone" landing in the middle of a song.
started = time()

# A throw anywhere inside pickup kills the polling thread silently - the
# station goes deaf and nothing on air says so - and this runs on every file
# four times a second, so the mtime call is wrapped. Measured on this build
# rather than assumed: file.mtime returns 0.0 for a file that is already gone
# and the true mtime for one the account cannot open for reading, throwing in
# neither case. Both of those come out "not new", which is the safe way to be
# wrong - a note is missed, exactly like every other note that arrived while
# we were down, and the cleanup below still bins it. The catch is there for
# the case neither of those covers. It has to be a function of its own:
# `x = try ... end` does not parse, a try is only allowed where a statement is.
def is_new(f) =
  try
    file.mtime(f) >= started
  catch _ do
    false
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
        # Recorded either way, so an old note costs one stat and not four a
        # second. `seen` keeps meaning exactly what it meant - do not queue
        # this path - and the cleanup below still forgets it once the file is
        # really gone, so the list does not grow.
        seen := list.add(f, seen())
        # Only notes that turned up while we were on air get played. `seen`
        # lives in memory and starts empty, so without this every note still
        # on disk looks new again after a restart - and the cleanup only bins
        # them at five minutes, so after a restart there are always some. On
        # 2026-08-02 at 15:42:23 that put 21 of the operator's notes back on
        # the air in one second, the instant the mount connected, while he was
        # listening to it.
        if is_new(f) then
          who  = speaker_of(f)
          l    = lane_for(who)
          q    = list.nth(queues, l)
          uri  = note_uri(who, f)
          q.push.uri(uri)
          log.important(label = "voice", "queued #{who} -> lane #{l}: #{uri}")
        end
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
