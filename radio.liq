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

# --- the narrator's settings -----------------------------------------------
# One json file, shared with narrator-watcher.ps1, so the /narrator page can
# later write both halves in a single PUT. This file takes three of its
# fields; voice, speed, piper_root and say_as belong to the watcher and mean
# nothing here - json.parse ignores keys the type does not name, so they ride
# along untouched.
#
# Read ONCE, at startup, and that is deliberate. file.watch exists on this
# build and is NOT used here, because all three of these are ALSO tunable
# while the station is on the air - two of them are interactive.float knobs
# on the mixing desk page. A watcher pushing the file back into those knobs
# would throw away whatever the operator had just dialled in by ear, the
# moment anything else saved the file. So the division is:
#   the file     = the value at startup, and the value that survives a restart
#   /interactive = the value right now
# Change the file while the station is up and nothing moves until the next
# restart; at that restart the file wins and any live tuning is gone.
#
# `hold` here is in DIAL units - the same ones /interactive shows - and those
# are NOT seconds. The accumulator further down adds 0.04 per frame against a
# 0.02s frame, so the number is worth half its face value: 28 is about 14
# seconds on the air. Left exactly as it was, because every value the
# operator tuned by ear assumes it.
#
# Same posture as note_uri further down: json.parse throws on no file, an
# empty file, one caught half-written, or one saved with a BOM, and every one
# of those means "use the defaults" - never a crash. Each field carries the
# trailing `?`, so a file missing one still delivers the others. Measured on
# this build rather than assumed: a json int lands in a float field as a
# float, so a page that writes 1 rather than 1.0 still parses. It has to be a
# function of its own: `x = try ... end` does not parse, a try is only
# allowed where a statement is.
narrator_config = "C:/Users/an/src/radio/config/narrator.json"

def narrator_cfg() =
  try
    let json.parse ( c : {
      announce_every : float?,
      hold           : float?,
      ident          : string?
    } ) = file.contents(narrator_config)
    c
  catch _ do
    { announce_every = null, hold = null, ident = null }
  end
end

ncfg = narrator_cfg()

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

# Starting value from narrator.json; the dial is live, the file is what comes
# back after a restart.
hold       = interactive.float("hold",
  description = "Seconds of quiet before the music comes back up. Covers pauses and gaps between clips.",
  unit = "s", min = 0.0, max = 30.0, step = 0.5, (ncfg.hold ?? 28.0))

glide      = interactive.float("glide",
  description = "How fast the music fader moves. Smaller is slower and smoother.",
  unit = "", min = 0.01, max = 0.5, step = 0.01, 0.01)

# the announcer
# Starting value from narrator.json; the dial is live, the file is what comes
# back after a restart.
announce_every = interactive.float("announce_every",
  description = "Speak on every Nth track: over its intro, and again as it ends. 1 = every one, 0 = never.",
  unit = "tracks", min = 0.0, max = 20.0, step = 1.0, (ncfg.announce_every ?? 1.0))


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

# --- likes -----------------------------------------------------------------
# Public, and deliberately with no notion of who is listening: a like is one
# number against one song, not a row belonging to an account. A host is a
# listener who additionally holds the speaker credential, and this needs no
# credential at all - hence its own caddy block, without `import speakers`.
#
# Keyed by the FILE PATH, never the title. About one track in seven of this
# library is untagged and comes back with an empty title and an empty artist,
# so the title is not an identifier: every untagged track would share one pile
# of likes. The path is the one thing a playing request always has.
#
# On disk it is an append-only ledger, one json line per like, in live/ - the
# single folder svc-radio may write. The source tree is read-only to it on
# purpose, and a file.write anywhere else fails as nothing but a caught
# exception and a page that never updates.
#
# Two properties come out of the append-only shape and both are why it is that
# shape. A click costs ONE append of about eighty bytes however many songs have
# ever been liked - the obvious alternative, rewriting a json map of every
# path, gets slower the more the station is loved. And the counts ARE the tally
# of the lines, so they come back after a restart by reading the file once
# below. Nothing ever rewrites it, so the worst a crash mid-write can cost is
# the last line.
likes_file = "C:/Users/an/src/radio/live/likes.jsonl"

# path -> count. One entry per distinct path, rebuilt from the ledger at
# startup and kept in step on every like, so serving a count is a lookup
# rather than a re-read of the file.
likes = ref([])

def like_count(p) =
  list.assoc(default = 0, p, likes())
end

def bump(p) =
  n = like_count(p) + 1
  likes := list.add((p, n), list.filter(fun (kv) -> fst(kv) != p, likes()))
end

# One ledger line -> the path it names, or "" for a line that is not one: the
# empty tail after the final newline, or half a line left by a crash. json.parse
# throws on those, and one throw would cost the whole ledger, so every line is
# parsed on its own. It has to be a function of its own: `x = try ... end` does
# not parse, a try is only allowed where a statement is.
def like_path(line) =
  try
    let json.parse ( e : { path : string } ) = line
    e.path
  catch _ do
    ""
  end
end

# Measured on this build rather than assumed: file.contents THROWS on a file
# that is not there. On the first ever run it is not there, which is the
# ordinary case and not an error - so no ledger simply means no likes yet.
def ledger() =
  try
    file.contents(likes_file)
  catch _ do
    ""
  end
end

list.iter(
  fun (line) -> begin
    p = like_path(line)
    if p != "" then bump(p) end
  end,
  string.split(separator = "\n", ledger()))

log.important(label = "likes", "#{list.length(likes())} liked tracks loaded")

# A like is not worth taking the station off the air for. A full disk or a
# folder that went away throws, and a throw inside a harbor handler answers
# 500 - so catch it and keep going. The in-memory tally is already updated by
# then, so the click still reads back right; only a restart loses that one.
def record_like(p) =
  try
    file.write(append = true,
      data = json.stringify(compact = true, { path = p }) ^ "\n", likes_file)
  catch _ do
    log.important(label = "likes", "could not write the ledger")
  end
end

# What both endpoints answer with, so a page can act and redraw from one
# response - the same idea as endpoint() above. The path itself does NOT go
# out: `id` is a digest of it, which is all a browser needs to remember what it
# has already liked, and it keeps the layout of D:/Music off the public
# internet. Nothing playing is an empty id and a count of zero.
def likes_state() =
  p = current_file()
  { id = if p == "" then "" else string.digest(p) end, likes = like_count(p) }
end

def like_endpoint(act) =
  fun (_, response) -> begin
    act()
    response.json(likes_state())
  end
end

harbor.http.register(port = 8005, method = "GET", "/likes/now",
  like_endpoint(fun () -> ()))
harbor.http.register(port = 8005, method = "POST", "/likes/add",
  like_endpoint(fun () -> begin
    p = current_file()
    if p != "" then
      bump(p)
      record_like(p)
    end
  end))

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

# Each speaker plays at their own volume, through their own seven-band EQ. A
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

# Seven bells, not a shelf/peak/shelf. filter.iir.eq.lowshelf and .highshelf
# exist in this build but neither takes a gain, only a `slope`, and measured
# here they are not usable as tone controls: a 100Hz tone through
# lowshelf(frequency=500) comes out 56dB DOWN, slope 1 vs 40 barely moves it,
# and a negative slope returns inf. filter.iir.eq.peak is the one that behaves
# - unity away from its centre, exactly +6.0dB at centre for gain=6.0 - so all
# seven bands are peaks. That also buys the property the sliders need most:
# 0 dB everywhere is EXACTLY flat, and that survived being stacked seven deep:
# measured on this build, a tone at each of the seven centres AND at each
# midpoint between them came back 0.00 dB against the same tone unfiltered.
#
# Octave spacing, 100Hz to 6300Hz, which is the whole of the useful range of a
# phone held at arm's length: under 100 there is handling rumble and little
# voice, over 6300 a 96kbps opus note has almost nothing left to lift.
#
# q = 1.4 belongs to that spacing - the usual figure for an octave graphic EQ,
# and measured here the one that makes the sliders behave like separate
# controls without scalloping between them. With one band up 6dB, its
# neighbour an octave away reads +1.15dB; at q 0.7 that is +2.86dB and the
# sliders visibly fight each other, at q 2.0 it is +0.63dB but then all seven
# up 6dB ripples between +7.5dB on the centres and +4.6dB between them, which
# is a comb you can hear. At q 1.4 all seven up 6dB lands between +7.2 and
# +8.9dB - more than 6 because the bells overlap, which is what a graphic EQ
# does, and why the volume above it is the thing to pull back afterwards.
#
#    100 Hz  rumble and boom - wind, a hand shifting on the phone, a knock on
#            the table. There is no high-pass on the notes (hp_freq only
#            guards the live mic) so this is the only thing that can take that
#            weight out.
#    200 Hz  the body of the voice, and where a mic held close goes chesty.
#    400 Hz  the lower boxiness a small capsule picks up in a small room.
#    800 Hz  the honk. Cutting here is what opens a voice up.
#   1600 Hz  presence - where the voice cuts through the music, or gets shouty.
#   3150 Hz  consonants and clarity. This is where "carrasposa" lives, so this
#            is the slider that fixes it, in whichever direction it turns out
#            to need.
#   6300 Hz  air and sibilance. Not 12k: bluetooth and a 96kbps opus note have
#            very little left that far up, so a lift there would be boosting
#            codec hiss rather than the voice.
#
# The seven getters are bound BEFORE the amplify, and that order matters:
# amplify's argument is a plain source, so passing the queue to it first pins
# this function's parameter to a plain source and the later q.last_metadata()
# stops typechecking with "this value has no method last_metadata". Reading
# the metadata first is what keeps the queue's own methods in view.
def voice_lane(q) =
  b100  = {eq_db(q, "f100")}
  b200  = {eq_db(q, "f200")}
  b400  = {eq_db(q, "f400")}
  b800  = {eq_db(q, "f800")}
  b1600 = {eq_db(q, "f1600")}
  b3150 = {eq_db(q, "f3150")}
  b6300 = {eq_db(q, "f6300")}
  l = amplify(override = "liq_amplify", voice_gain, q)
  l = filter.iir.eq.peak(frequency =  100.0, q = 1.4, gain = b100,  l)
  l = filter.iir.eq.peak(frequency =  200.0, q = 1.4, gain = b200,  l)
  l = filter.iir.eq.peak(frequency =  400.0, q = 1.4, gain = b400,  l)
  l = filter.iir.eq.peak(frequency =  800.0, q = 1.4, gain = b800,  l)
  l = filter.iir.eq.peak(frequency = 1600.0, q = 1.4, gain = b1600, l)
  l = filter.iir.eq.peak(frequency = 3150.0, q = 1.4, gain = b3150, l)
  l = filter.iir.eq.peak(frequency = 6300.0, q = 1.4, gain = b6300, l)
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
#   { "gain": 2.5, "duck": true,
#     "eq": { "f100": 0, "f200": 0, "f400": 0, "f800": 0,
#             "f1600": 0, "f3150": 0, "f6300": 0 } }
#
# All of it rides with the note as annotations, so it applies to that note
# alone: the lane reads liq_amplify and the seven liq_eq_* bands, the ducking
# further down reads liq_duck.
#
# `eq` is optional - the trailing `?` on its type - and that `?` carries more
# than it looks. Measured on this build, all of these parse and hand back gain
# and duck intact with cfg.eq null: a file with no `eq` key at all (every
# speaker's file from before the EQ existed), a file whose `eq` is null, and a
# file still holding the OLD three-band { low, mid, high }. A field that does
# not match its type goes null on its own rather than throwing the whole parse
# away. So renaming the bands from low/mid/high to f100..f6300 costs an
# existing speaker the curve they had - they come back flat, seven bands at
# 0 dB, until they touch a slider - but it does not cost them their volume or
# their ducking, which is what a throw here would have taken with it.
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
      eq   : { f100  : float, f200  : float, f400 : float, f800 : float,
               f1600 : float, f3150 : float, f6300 : float }?
    } ) = file.contents("#{voice_dir}/#{who}/settings.json")
    eq = cfg.eq ?? { f100  = 0.0, f200  = 0.0, f400 = 0.0, f800 = 0.0,
                     f1600 = 0.0, f3150 = 0.0, f6300 = 0.0 }
    "annotate:liq_amplify=\"#{cfg.gain}\",liq_duck=\"#{cfg.duck}\""
    ^ ",liq_eq_f100=\"#{eq.f100}\",liq_eq_f200=\"#{eq.f200}\""
    ^ ",liq_eq_f400=\"#{eq.f400}\",liq_eq_f800=\"#{eq.f800}\""
    ^ ",liq_eq_f1600=\"#{eq.f1600}\",liq_eq_f3150=\"#{eq.f3150}\""
    ^ ",liq_eq_f6300=\"#{eq.f6300}\":#{f}"
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

# --- the announcer ---------------------------------------------------------
# The station says what it is playing, and says what it just played, and puts
# the same words on the site under the volume slider.
#
# TWO moments, and deliberately not one. forward_meta below fires at the
# boundary and the metadata it carries belongs to the track that is STARTING,
# so that is where the intro goes - talking over the ramp, which is what an
# announcer does. The outro belongs at the END of the track it is about, so it
# hangs off on_position with remaining = true, the same hook the repeat button
# already uses further up.
#
# The 12 seconds of runway is arithmetic, not taste. Writing a .txt does not
# make a sound: narrator-watcher.ps1 polls every 3 s, will not touch a file
# until it has been unchanged for one further poll, and piper then takes about
# 1.7 s - roughly 8 seconds before the first word is on the air, and the line
# itself runs a few more. Any less and "that was" lands over the next song,
# which is the whole thing this is trying not to do.
#
# There is no new machinery. The sentence goes into the announcer's own folder
# as a plain .txt and this file is done with it - the watcher renders it and
# the pickup above plays the wav like any other voice note, in a lane, over
# ducked music, at the announcer's own gain and EQ.
announcer_dir = "#{voice_dir}/announcer"

# Where the site reads the current line from. A plain static file at the web
# root, because the station page is public: it cannot use the /control
# endpoints, which sit behind the speaker credential. In its own folder and
# not at the repo root: svc-radio has read-only access to the source tree on
# purpose - the station should not be able to rewrite its own program - so it
# gets exactly one writable folder under the web root. Writing to the root
# itself fails with nothing but a caught exception and a page that never
# updates, which is how this was found.
# endpoints, which sit behind the speaker credential. The page ages the line
# out on the timestamp, so a stale "that was" cannot sit under the volume
# slider for the rest of the evening.
narrator_file = "C:/Users/an/src/radio/live/narrator.json"

# What to say when the station has no idea what it is playing. About one track
# in seven of this library is untagged, and saying nothing sounds like
# something broke rather than like a radio.
# `ident` in narrator.json. Read at startup like the two knobs above, but
# unlike them there is no dial for it: this one only changes on a restart.
mystery = ncfg.ident ?? "this mystery song is yet to be tagged... we hope you enjoyed..."

# And what the STREAM says it is playing when the file has no title. Sending
# nothing is not neutral: icecast keeps displaying whatever it was last told,
# so an untagged track silently inherits the previous song's name and the site
# confidently announces Billie Holiday over Bob Marley. Anything true is
# better than something false.
untagged_title = "live"

# The request we last acted on. on_metadata is not promised to fire exactly
# once per track. The rid is the identity of the REQUEST, so it is stable for
# as long as one track plays and different for the next - including a track
# played twice in a row by the repeat button, which is a fresh request and so
# is announced both times, which is right. filename rides along in case a
# chunk ever arrives without a rid.
last_track  = ref("")

# Boundaries counted against announce_every, and the sentence waiting to be
# said as the current track ends.
#
# The outro sentence is built at the BOUNDARY and held, not read from the
# library when the timer fires. Reading it late looks obviously right and is
# wrong: last_metadata is whatever is most recent, so once a boundary has
# passed it already describes the NEXT track, and the station announces "that
# was X" about the song it is currently starting. Measured, on a skip, where
# both lines fired in the same second and named the same track.
#
# Holding it also gets skipping right for free. A skipped track never reaches
# its own timer, so its sentence is overwritten at the next boundary and never
# spoken - which is what you want, because you cut it off on purpose and do
# not need to be told it is over.
since_said    = ref(0)
pending_outro = ref("")

def intro_words(m) =
  title  = string.trim(m["title"])
  artist = string.trim(m["artist"])
  if title == "" then
    ""
  elsif artist == "" then
    "You're listening to #{title}."
  else
    "You're listening to #{title}, by #{artist}."
  end
end

def outro_words(m) =
  title  = string.trim(m["title"])
  artist = string.trim(m["artist"])
  if title == "" then
    mystery
  elsif artist == "" then
    "That was #{title}."
  else
    "That was #{title}, by #{artist}."
  end
end

# UTC. The page compares this against its own clock to decide the line has
# gone stale, so it has to be a real ISO stamp. Measured on this build rather
# than assumed: time.utc really is UTC, and its month is 1-based - localtime
# and a 0-based month are both what the C library underneath would plausibly
# have handed back.
def utc_stamp() =
  def pad(n) = if n < 10 then "0#{n}" else "#{n}" end end
  t   = time.utc()
  day = "#{t.year}-#{pad(t.month)}-#{pad(t.day)}"
  { iso  = "#{day}T#{pad(t.hour)}:#{pad(t.min)}:#{pad(t.sec)}.000Z",
    name = "#{day}T#{pad(t.hour)}#{pad(t.min)}#{pad(t.sec)}000Z" }
end

# The spoken file is words and nothing else - piper reads the .txt literally,
# so a loudspeaker or a "Narrator:" in there would be read out loud. The page
# draws the loudspeaker itself.
#
# json.stringify rather than hand-built json: a track title with a quote or a
# backslash in it would otherwise produce a file the page cannot parse, and
# this library is full of punctuation nobody chose.
#
# Both writes can fail - a full disk, a folder that went away - and a throw
# inside a metadata callback kills the callback silently: the station would
# play on while titles stopped reaching icecast. Hence the catch, and it has
# to be its own function, because `x = try ... end` does not parse; a try is
# only allowed where a statement is.
#
# The .txt is one plain file.write, NOT atomic = true. An atomic write lands
# the file by moving it in from a temp directory, and a file moved into one of
# these folders carries its own ACL instead of inheriting the folder's, which
# is the trap narrator-watcher.ps1 documents at length. A plain write is safe
# twice over here: .txt is not in the audio whitelist the pickup filters on,
# so the four-times-a-second poll never looks at it, and the narrator watcher
# only speaks a text file whose size and mtime were already identical at the
# previous poll three seconds earlier.
def say(words) =
  try
    st   = utc_stamp()
    tail = "#{st.name}-#{string.hex_of_int(pad = 4, random.int(min = 0, max = 65536))}"
    file.write(data = "#{words}\n", "#{announcer_dir}/track-#{tail}.txt")
    file.write(data = json.stringify({ at = st.iso, words = words }), narrator_file)
    log.important(label = "announcer", words)
  catch _ do
    log.important(label = "announcer", "could not write the announcement")
  end
end

# One new request is one track boundary: speak over the intro, and remember
# whether this track is a spoken one so its outro matches.
def announce(m) =
  req = string.concat(separator = "|", [m["rid"], m["filename"]])
  if req != last_track() then
    last_track := req
    every      = int_of_float(announce_every())
    if every <= 0 then
      pending_outro := ""
    else
      since_said := since_said() + 1
      if since_said() >= every then
        since_said    := 0
        pending_outro := outro_words(m)
        w = intro_words(m)
        if w != "" then say(w) end
      else
        pending_outro := ""
      end
    end
  end
end

# The outro, with the runway computed above. The timer only decides WHEN; the
# words were settled at the boundary, for the reason recorded up there.
library.on_position(position = 12.0, remaining = true, synchronous = false,
  fun (_, _) -> begin
    words = pending_outro()
    if words != "" then
      pending_outro := ""
      say(words)
    end
  end)
# `add` drops track marks, and the title rides with them - without this the
# stream plays fine and the song name never reaches icecast.
def forward_meta(m) =
  t = string.trim(m["title"])
  log.important(label = "meta", "forwarding #{t}")
  # An untagged file gets the station line rather than the real metadata, so
  # the last good title cannot linger on the site as if it were this one.
  if t == "" then
    radio.insert_metadata(new_track = true, [("title", untagged_title), ("artist", "")])
  else
    radio.insert_metadata(new_track = true, m)
  end
  # The new title reaches the stream first; the announcement is about
  # the one before it and can wait the millisecond a file write takes.
  announce(m)
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
