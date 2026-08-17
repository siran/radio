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
# Where things live. Machine environment variables, so the station can move
# without editing code - the same mechanism RADIO_HARBOR_PASSWORD already uses
# further down, and the only one liquidsoap, caddy and powershell all speak.
# Empty means the variable is not set for the account this runs as; the three
# roots are printed to the log below so that is visible rather than mysterious.
radio_home = environment.get("RADIO_HOME")
music_dir  = environment.get("RADIO_MUSIC")
liq_home   = environment.get("RADIO_LIQ")

settings.log.file.path    := "#{liq_home}/log/radio.log"
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
# build and is NOT used here, because all of these are ALSO tunable
# while the station is on the air - hold is a dial on the mixing desk page and
# the two announce switches are switches there. A watcher pushing the file back
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
narrator_config = "#{radio_home}/config/narrator.json"

def narrator_cfg() =
  try
    let json.parse ( c : {
      announce_every : float?,
      announce_intro : bool?,
      announce_outro : bool?,
      hold           : float?,
      ident          : string?
    } ) = file.contents(narrator_config)
    c
  catch _ do
    { announce_every = null, announce_intro = null, announce_outro = null,
      hold = null, ident = null }
  end
end

ncfg = narrator_cfg()

# The mixing desk, saved. Every knob below is live - moving it changes the air
# at once - but until now that was ALL it was, so a restart threw the lot back
# to whatever numbers were typed here months ago. An afternoon of listening was
# lost that way twice in one day before this existed.
#
# Same shape as narrator.json above and for the same reason: every field
# optional, the whole thing wrapped, and a file that is missing or malformed
# falls through to the built-in numbers rather than taking the station with it.
# The page writes this file; nothing here writes it back, so what is on disk is
# always what somebody chose.
desk_config = "#{radio_home}/config/desk.json"

def desk_cfg() =
  try
    let json.parse ( c : {
      mic_gain   : float?,
      voice_gain : float?,
      hp_freq    : float?,
      comp_thr   : float?,
      comp_ratio : float?,
      comp_gain  : float?,
      duck_to    : float?,
      hold       : float?,
      glide      : float?,
      air_delay  : float?,
      record_min : float?
    } ) = file.contents(desk_config)
    c
  catch _ do
    { mic_gain = null, voice_gain = null, hp_freq = null, comp_thr = null,
      comp_ratio = null, comp_gain = null, duck_to = null, hold = null,
      glide = null, air_delay = null, record_min = null }
  end
end

dcfg = desk_cfg()

# --- knobs -----------------------------------------------------------------
# Every one of these can be changed WHILE THE STATION IS RUNNING, from the
# mixing desk page. No restart, no gap in the audio.

# voice chain
mic_gain   = interactive.float("mic_gain",
  description = "Live microphone volume. Raise if the mic sounds far away.",
  unit = "x", min = 0.0, max = 4.0, step = 0.1, (dcfg.mic_gain ?? 3.0))

voice_gain = interactive.float("voice_gain",
  description = "Volume of uploaded voice notes. Phone recordings arrive quiet, so this sits high.",
  unit = "x", min = 0.0, max = 12.0, step = 0.25, (dcfg.voice_gain ?? 1.0))

hp_freq    = interactive.float("hp_freq",
  description = "Cuts rumble below this. Handling noise and desk bumps live down here.",
  unit = "Hz", min = 40.0, max = 300.0, step = 5.0, (dcfg.hp_freq ?? 80.0))

comp_thr   = interactive.float("comp_thr",
  description = "Compressor: the level above which your voice starts being held back. Lower = more evening out.",
  unit = "dB", min = -40.0, max = 0.0, step = 1.0, (dcfg.comp_thr ?? -26.0))

comp_ratio = interactive.float("comp_ratio",
  description = "Compressor: how hard it holds back. 1 = off, 4 = normal speech, 10+ = squashed.",
  unit = ":1", min = 1.0, max = 20.0, step = 0.5, (dcfg.comp_ratio ?? 6.0))

comp_gain  = interactive.float("comp_gain",
  description = "Make-up volume, added AFTER the compressor. This is the one to raise if you are still too quiet.",
  unit = "dB", min = 0.0, max = 24.0, step = 0.5, (dcfg.comp_gain ?? 12.0))

# ducking
duck_to    = interactive.float("duck_to",
  description = "How loud the music stays while someone talks. 1.0 = untouched, 0.0 = silent.",
  unit = "x", min = 0.0, max = 1.0, step = 0.05, (dcfg.duck_to ?? 0.6))

# Starting value from narrator.json; the dial is live, the file is what comes
# back after a restart.
# These are REAL seconds. They used to be about half that: the release counted
# frames at an assumed 0.04s each against a frame that is actually 0.02s, so a
# dial reading 28 released after roughly 14. It measures wall-clock now, so the
# number on the dial is the number of seconds - which means every value tuned
# by ear before 2026-08-03 meant half what it said.
hold       = interactive.float("hold",
  description = "Seconds of quiet before the music comes back up. Covers pauses and gaps between clips.",
  unit = "s", min = 0.0, max = 30.0, step = 0.5, (dcfg.hold ?? (ncfg.hold ?? 3.0)))

glide      = interactive.float("glide",
  description = "How fast the music fader moves. Smaller is slower and smoother.",
  unit = "", min = 0.01, max = 0.5, step = 0.01, (dcfg.glide ?? 0.01))

# --- changing a record ------------------------------------------------------
# The shortest a change of record is allowed to take on the listener page.
#
# That animation is timed by the LISTENER, from their own buffering - the page
# measures how long its browser takes to have audio and spends exactly that on
# sliding the record in, so the record lands about when the music starts. On a
# fast line that number gets small, and a record change that completes in two
# hundred milliseconds is not a record being changed, it is a flicker.
#
# So the page takes whichever is longer, this or its own measurement. It is a
# floor and never a target: it cannot make a change SHORTER than the wait, only
# stop a short wait looking like nothing happened.
#
# It defaults to NOUGHT, and did not always. The page has a mechanical floor of
# its own - 660ms, one travel across the window plus the drop onto the pin, and
# nothing can be drawn in less than what drawing it costs - so the flicker this
# was added to prevent is already impossible. At the 1.2s it sat at, all it did
# was stretch every natural change 540ms past the length of the move: the same
# record carried at 147px/s instead of the 267 the page has on record as the
# speed a record is carried at. A slower move for no reason anybody chose.
#
# It stays on the desk, at nought, because it is still the right lever if the
# station ever wants a longer minimum ON PURPOSE: it is a matter of taste about
# how the station presents itself, it applies to every listener at once, and
# the operator asked for it there.
record_min = interactive.float("record_min",
  description = "Shortest a record change may take on the listener page. A floor under their own buffering time, so a fast connection still sees a record change rather than a flicker.",
  unit = "s", min = 0.0, max = 6.0, step = 0.1, (dcfg.record_min ?? 0.0))

# --- talking in time with the music ----------------------------------------
# How far the music is held back before it goes to air, so that a host talking
# over it lands where they meant to.
#
# A host hears the bed through their monitor a little late, and their voice
# takes a little longer again to travel back - browser capture, a 300ms
# recorder slice, the socket, this harbor's own input buffer. Both of those
# are behind them by the time they speak, so a word aimed at a beat lands
# after it. Neither trip can be made shorter. Holding the MUSIC back by the
# same total puts the word back on its beat.
#
# What a host is really setting is one sum:
#
#     how late a word lands = monitor lag + voice trip - this
#
# Zero is aligned. Two of those three are theirs and one is here, and this is
# the ONLY one that can cure a late voice - the console can add to the monitor
# lag but never subtract from it, so from the browser late is uncorrectable.
#
# THIS DIAL IS NOT LIVE, and that was measured rather than assumed.
# delay_line takes a getter, so it looks live, and the value on the dial does
# change - but the audio does not follow it. On a throwaway instance: started
# at 0.0 and pushed to 1.2, the delay stayed put; started at 1.2, it was
# 1.202s. It reads its getter once, when the graph is built. So this is the
# value at the NEXT RESTART, like every other line in desk.json, and the
# by-ear tuning lives in the console, which holds the monitor back instead -
# same sum, and a browser CAN change that live.
#
# Set it generously rather than exactly, and that is not sloppiness: the
# console can only make the sum BIGGER. Overshoot here so the host lands
# EARLY, and let them trim back live with the sync slider. Around 1.75 suits a
# browser on the LAN, where the two trips come to roughly 1.1.
#
# 0.0 is the default and is exactly the old behaviour - it costs every listener
# whatever it is set to, and a station nobody talks on has nothing to align.
air_delay  = interactive.float("air_delay",
  description = "Holds the music back so a host's voice lands on the beat they heard. Takes effect at the next restart; tune by ear with the console's sync slider.",
  unit = "s", min = 0.0, max = 8.0, step = 0.05, (dcfg.air_delay ?? 0.0))

# the announcer
# Two switches, not a count. There are exactly two moments a host can speak at
# - over the start of a track, and as one ends - so this is a choice of which
# of them are on, and a 0-20 dial was a number pretending to be a choice. Off
# is both off; "both" is both on.
#
# Seeded from narrator.json, one key per switch, because they are two
# independent choices and one number could not carry both: with only
# announce_every, picking "at the end" on the dashboard came back as "both"
# after a restart.
#
# Precedence, per switch: its own key if the file names it, otherwise the old
# announce_every - above zero means the operator wanted the announcer, zero
# means off - and otherwise on. So a file still holding only announce_every
# behaves exactly as it did: 20 brings both switches up, 0 leaves both down.
# A field that is absent, null or not a bool goes null on its own rather than
# throwing the parse away, so the old key is what catches it.
#
# As with every knob here, the file is the value at startup and /interactive is
# the value right now.
announce_on    = (ncfg.announce_every ?? 1.0) > 0.0

announce_intro = interactive.bool("announce_intro",
  description = "Say what is starting, over the top of the track.",
  ncfg.announce_intro ?? announce_on)

announce_outro = interactive.bool("announce_outro",
  description = "Say what just played, as the track ends.",
  ncfg.announce_outro ?? announce_on)


# The mixing desk: liquidsoap's own page for the knobs above, at
# /interactive on the harbor port. Must NOT use the default port - that is
# 8000, which icecast owns, and the collision takes the station off air.
interactive.harbor(port = 8005)

# The library. randomize + watch so new files appear without a restart.
#
# That watch is also what tells the search index further down to rebuild -
# the index is a list of our own and liquidsoap knows nothing about it, so
# without this it would go stale the moment anything was added. Only the
# DEADLINE is set here; the rebuild is defined with the rest of the index,
# which is far below because it needs track_name.
#
# A deadline rather than a rescan on the spot, because copying an album in
# fires this once per file: each one pushes the moment back, so a folder of
# twenty tracks costs one rebuild ten seconds after the last of them lands
# rather than twenty rebuilds while they arrive.
rescan_at = ref(0.0)

music = playlist(
  id          = "library",
  mode        = "randomize",
  reload_mode = "watch",
  on_reload   = fun (_) -> rescan_at := time() + 10.0,
  music_dir
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

# Whether the live source is actually SAYING anything, as opposed to merely
# holding the mount. They used to be one question and are not: a host can now
# go on air with the microphone shut - so the room can see a show has started
# while the autoDJ plays on - and open it when they have something to say.
# The ducking further down reads `connected`, so without this a host who went
# on air and stayed quiet would have the music dipped under them for the whole
# broadcast while they said nothing.
#
# Declared here rather than beside `connected`, which is where it belongs by
# meaning: this file is read top to bottom, the endpoint that writes it is
# registered hundreds of lines above that, and a ref declared after its own
# endpoint does not typecheck. Measured, not guessed - it was written there
# first and liquidsoap said "Undefined variable live_open".
#
# TRUE by default, and that is the important half. Nothing but the console
# sets it: butt, CoolMic and anything else speaking the icecast source
# protocol have no way to say "I am muted now", and for them holding the
# mount IS talking, exactly as it always was. A default of false would have
# made every one of them silently stop ducking the music.
live_open = ref(true)

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

# Title and artist as they should be SHOWN. On screen only, never spoken - the
# narrator's own words are built from tags alone, further down.
#
# Tags first - but about
# one track in seven of this library has none, and for those the FILENAME is
# the only description there is. Measured on a file the operator complained
# about: seven metadata keys, not one of them title or artist, while its name
# read "Bob Marley Vs. Lee Scratch Perry - The Best Of The Upsetter Years -
# Try Me". Saying "live" over that is throwing away what we already know.
#
# The rule: strip the directory and the extension, then split on " - " - space
# hyphen space. Two or more fields means the FIRST is the artist and the LAST
# is the title. That is this library's "Artist - Album - Title", and it reads
# the four-field ones right too ("Foreign Beggars - The Harder They Fall - EP
# - Still Getting It"). Anything else is one title and no artist, which is
# what "07. I Want To Be The President" deserves.
#
# The separator is the spaced hyphen and not a bare one, because a bare hyphen
# is part of a name at least as often as it is a separator: El-P, B-Sides,
# Class X-. string.split takes a REGEX, and " - " happens to be its own regex -
# no metacharacter in it.
#
# Measured rather than assumed: path.basename cuts at a BACKSLASH as well as a
# slash, which matters because these paths arrive mixed - the live station
# reports "D:/Music\shuffled\Miles Davis - Bitches Brew - Bitches Brew.m4a".
# The one thing it gets wrong is the empty path, where basename("") is "." -
# hence the guard, which is also what leaves untagged_title below its job as
# the last resort.
def track_name(title, artist, fpath) =
  t = string.trim(title)
  if t != "" then
    { title = t, artist = string.trim(artist) }
  elsif fpath == "" then
    { title = "", artist = "" }
  else
    stem  = path.basename(path.remove_extension(fpath))
    parts = string.split(separator = " - ", stem)
    n     = list.length(parts)
    if n >= 2 then
      { title  = list.nth(default = stem, parts, n - 1),
        artist = list.nth(default = "", parts, 0) }
    else
      { title = stem, artist = "" }
    end
  end
end

def now_playing() =
  m = library.last_metadata() ?? []
  p = current_file()
  n = track_name(m["title"], m["artist"], p)
  {
    path   = p,
    title  = n.title,
    artist = n.artist,
    music  = music_on(),
    paused = paused(),
    repeat = repeating()
  }
end

# --- the playlist queue ----------------------------------------------------
# A list of tracks the operator builds up, which plays through to the end
# before the shuffle comes back. It is not a source of its own. It lives
# inside the playlist's OWN queue - the same queue again() and previous() just
# below have always written to - so a queued track is a library track in every
# way that matters: skip, previous, repeat, the likes button, the intro and the
# outro all hang off `library`, and every one of them keeps working without
# knowing this exists. The obvious alternative, a request.queue of its own put
# in front of the shuffle with a fallback, was rejected for exactly that. It
# would have put a second source on the air that library.current(),
# library.skip() and the two library.on_position hooks cannot see, so /control/
# now, /likes/now, the skip button, the previous button and the outro would
# each have needed to ask which of the two sources is playing, and this build
# offers no way to ask a fallback that.
#
# Every request put in that queue on the operator's behalf carries an
# annotation, and that is what tells his list apart from the ONE request the
# playlist keeps prefetched in the same queue. Measured on this build:
# prefetch is 1, that prefetched request really is in queue(), and the playlist
# tops the queue back up only once the last of ours has left it - so the list
# plays through in the order it was built, and the shuffle resumes behind it
# with nothing spliced in and with no gap, because it is the same source that
# was playing all along.
#
# The annotation rides in the URI and never in the filename. Measured rather
# than assumed: a request made from "annotate:queued=...:D:/Music/x.mp3"
# reports the plain path as its filename, so history, the likes digest,
# track_name and the announcer all see exactly what they saw before.
queue_mark = "annotate:queued=\"1\":"

def queued_uri(p) =
  queue_mark ^ p
end

def is_queued(r) =
  string.index(substring = queue_mark, request.uri(r)) == 0
end

# The list as it stands, read back out of the queue rather than held beside it.
# There is nothing here that can drift: the playlist takes an entry out of the
# queue at the moment it starts playing it, so what is left IS what is still to
# come.
def pending_paths() =
  list.map(request.filename, list.filter(is_queued, library.queue()))
end

# Replace the playlist's queue. It cannot be edited in place, and that was
# measured rather than assumed: set_queue re-resolves every request it is
# handed, a request that is already in that queue fails to re-resolve, and one
# that fails is dropped without a word - three appends in a row, each one
# handing back the requests already there, left one entry and not three. So
# every entry has to be made fresh from its path each time the list changes,
# which is why this takes uris rather than requests. Everything that was in the
# queue is orphaned by that and is destroyed here, and that is also the leak
# the three callers below have always had: each hands set_queue the playlist's
# own prefetched request, which has been silently dropped and never destroyed
# ever since.
#
# The resolving happens HERE, before set_queue, and that is the difference
# between this being safe on the air and not. set_queue empties the queue
# before it fills it and it resolves as it fills, so a track ending inside that
# window finds the playlist with nothing ready and mksafe covers the hole with
# silence. Measured on this build, rewriting a five-deep queue every 0.4s for
# ninety seconds across thirty track boundaries: three switches to safe_blank
# when set_queue does the resolving, and not one when it is done first, because
# by then set_queue has nothing left to do but swap a list. An entry that fails
# to resolve is dropped by set_queue and so simply is not in the list that
# comes back, which is why the only caller that can add an unheard-of path
# checks it first.
#
# The queue is read for destroying AFTER the resolving and not before, which
# looks like a detail and is not. Resolving lets go of the runtime lock, so a
# track can end while it runs; a request read before that and destroyed after
# could by then be the one on the air, and a destroyed request is one
# current_file() reports as "" - the operator would watch "now playing" go
# blank for the rest of a song that is audibly still playing. Read this late,
# the only gap left is the set_queue call itself, which by now has nothing to
# do but swap a list.
def requeue(uris) =
  fresh = list.map(request.create, uris)
  list.iter(fun (r) -> ignore(request.resolve(content_type = library, r)), fresh)
  old = library.queue()
  library.set_queue(fresh)
  list.iter(request.destroy, old)
end

# Play the current track once more: a fresh request for the same file, put at
# the FRONT of the playlist's queue. `library.add` is the obvious call and it
# is the wrong one - it appends BEHIND whatever the playlist has already
# prefetched, so the repeat would land a track late.
#
# The pending list is rebuilt behind it rather than left alone, because
# set_queue would otherwise drop the lot: repeat re-queues once per track, so
# without this a queue the operator had built would be gone within one song of
# the repeat button going on. The repeated file is NOT annotated, so it plays
# before the list without appearing in it - it is not something he put there.
def again() =
  f = current_file()
  if f != "" then
    requeue(list.add(f, list.map(queued_uri, pending_paths())))
    log.important(label = "control", "playing again: #{f}")
  end
end

# What has already finished, most recent first, so there is something to go
# back TO. Nothing else in this file remembers it: now_playing reads
# library.current and library.last_metadata, and both of those only ever
# describe the request that is playing right now.
#
# Bounded on purpose. This is a radio - nobody is walking back an hour, and an
# unbounded ref in a process that runs for weeks is a slow leak.
history     = ref([])
history_max = 10

# Set while a previous() is landing. previous() skips, and a skip is a track
# boundary like any other, so without this the track it just cut short gets
# recorded as having finished - and pressing previous twice hands back the song
# you were already on instead of the one before it. Measured: A skip B skip C,
# then previous gave B correctly and previous again gave C.
rewinding = ref(false)

# The file playing at this moment, held so that the next boundary knows what
# just ENDED. The metadata a boundary hands us belongs to the track that is
# starting, so without this there is no way to name the one that finished.
now_file = ref("")

def remember(f) =
  if f != "" then
    history := list.prefix(history_max, list.add(f, history()))
  end
end

# Play what finished last, immediately. Same front-of-queue trick as again()
# above - and the same reason for it: library.add appends BEHIND whatever the
# playlist has already prefetched, so the track would arrive one late. The skip
# is what makes it now rather than after the current song. It rebuilds the
# pending list behind itself for the reason recorded at again(), and like
# again() the file it puts in front is not annotated, so walking backwards does
# not write itself into the operator's list.
#
# The entry is consumed, so pressing previous repeatedly walks backwards
# instead of bouncing between two tracks. A replayed track goes back on the
# history when it finishes, which is right: by then it really is the previous
# track again.
def previous() =
  h = history()
  if list.length(h) > 0 then
    f = list.hd(default = "", h)
    history := list.tl(h)
    if f != "" then
      rewinding := true
      requeue(list.add(f, list.map(queued_uri, pending_paths())))
      library.skip()
      log.important(label = "control", "previous: #{f}")
    end
  else
    log.important(label = "control", "previous: nothing behind us yet")
  end
end

# Repeat re-queues the track shortly before it ends rather than when it starts.
# Deciding late is what makes switching repeat off take effect immediately: do
# it at the start of a track and there is always one more copy already
# committed to the queue that nobody asked for.
library.on_position(position = 2.0, remaining = true, synchronous = false,
  fun (_, _) -> if repeating() then again() end)

# --- searching the library -------------------------------------------------
# What is actually in D:/Music, so the console can ask for a track by name.
#
# The playlist cannot answer that, and its methods were checked rather than
# assumed: `remaining_files` is only what is LEFT of the current round -
# measured on this build, 1 of 3 files at startup and 4 of 5 just after a
# reload - so it shrinks as the station plays and is never the library.
# `length()` is the only whole-library number it has, and a count is not a
# search. Hence an index of our own.
#
# In memory, and deliberately no database and no cache file: 1175 files, whose
# paths, titles and artists together are a fraction of a megabyte.
#
# Every track is keyed by a digest of its path, exactly as /likes/now further
# down is. The path NEVER leaves this process. A client that could name a file
# could ask for any file on the disk that liquidsoap can read, and the speaker
# credential is not meant to be that. It is the same digest /likes/now uses,
# so a page holding both can tell that what is now playing is the track it
# just queued.
search_max = 50

music_exts = ["mp3", "m4a", "aac", "mp4", "flac", "ogg", "oga", "opus",
              "wav", "wma", "aiff"]

# file.ls with recursive = true ignores `pattern` entirely and hands back
# directories alongside files - the same trap the voice pickup documents - so
# the extension filter is what keeps both out. It also yields MIXED
# separators, forward slashes for the directory it was given and backslashes
# below it, which costs nothing here because a path is matched as one
# lowercased string and never split. There is no path.extension;
# remove_extension is what exists, so a file ends in .mp3 exactly when
# stem ^ ".mp3" is the name again. Lowercasing first is what makes one entry
# per extension also cover .MP3 and .Mp3.
def scan_paths() =
  def is_music(f) =
    fl   = string.case(lower = true, f)
    stem = path.remove_extension(fl)
    list.exists(fun (e) -> stem ^ ".#{e}" == fl, music_exts)
  end
  list.filter(is_music,
    file.ls(music_dir, absolute = true, sorted = true, recursive = true))
end

# Tags, and "" for a file that has none or cannot be read. file.metadata goes
# out to ffmpeg and a damaged file throws - this library has several that do -
# and one throw would cost the whole index. It has to be a function of its
# own: `x = try ... end` does not parse, a try is only allowed where a
# statement is.
def read_tags(p) =
  try
    m = file.metadata(p)
    (string.trim(m["title"]), string.trim(m["artist"]))
  catch _ do
    ("", "")
  end
end

# One track. Its title and artist come from the tags when there are any and
# from the FILENAME when there are not, which is the decision track_name above
# already makes - so it is called here rather than repeated.
#
# That fallback carries more than it looks. Measured over the whole library:
# 216 of 1175 files have no title, 216 have no artist, and 216 have neither -
# the same files all three times, so tags here are all or nothing. For those
# 216, better than one track in six, the path is the only description there
# is.
#
# The lowercased copies are what search matches on. Held rather than computed
# per query because a search runs on a harbor thread, and that thread holds
# the same runtime lock the streaming thread needs; lowercasing three fields
# of 1175 entries on every keystroke would be work done inside that lock for
# nothing.
#
# `hay` is those same three fields joined, so that deciding whether a track
# matches at all is ONE search of one string instead of three. Measured, and
# the reason it is worth a field of its own: a pass over the library costs
# 0.075 s per string searched, so three fields is 0.22 s of held lock per
# query and one field is 0.075 s. Which of the three actually matched is then
# worked out only for the fifty rows that are returned, where three searches
# apiece is a few milliseconds.
#
# The newline between them is what stops a match running from the end of one
# field into the start of the next.
def entry(p, tagged) =
  let (t, a) = if tagged then read_tags(p) else ("", "") end
  n  = track_name(t, a, p)
  lt = string.case(lower = true, n.title)
  la = string.case(lower = true, n.artist)
  lp = string.case(lower = true, p)
  { id     = string.digest(p),
    path   = p,
    title  = n.title,
    artist = n.artist,
    lt     = lt,
    la     = la,
    lp     = lp,
    hay    = "#{lt}\n#{la}\n#{lp}" }
end

library_index = ref([])

# Building the index costs a walk of D:/Music and a tag read per file, and
# those two are not the same kind of expensive. Measured on this build against
# a station streaming to an output, as the worst gap between two consecutive
# frames on the streaming thread:
#
#   idle                        0.13 s
#   reading tags for all 1175   0.13 s  - no effect whatever, nothing logged
#   five walks back to back     0.74 s  - one "we must catchup" per walk
#
# So it is file.ls that stalls the stream and NOT the tags, which is the
# opposite of what the clock times suggest: the walk is 1.1 s and the tag pass
# is 15 s on a cold cache, 1.2 s warm. Reading tags goes out to ffmpeg, which
# lets go of the runtime lock while it waits on the disk; the recursive walk
# holds that lock the whole way down. `fast = false` does not help - measured
# at 0.74 s either way - because it moves a task between scheduler queues and
# the lock is not a queue.
#
# That measurement, and not the clock, is what puts each half where it is:
#
#   the walk  runs HERE, at the top level, which is before any output exists
#             and so before there is a stream to disturb. It costs about a
#             second between a restart and the station coming back on air.
#   the tags  run on a background thread just below, because they provably
#             cost the stream nothing - so the station does not wait fifteen
#             seconds for them, and search works from the first moment on
#             filename and path, which is all the untagged 216 ever had.
def index_paths() =
  library_index := list.map(fun (p) -> entry(p, false), scan_paths())
end

def index_tags() =
  library_index := list.map(fun (e) -> entry(e.path, true), library_index())
end

index_paths()
log.important(label = "search",
  "#{list.length(library_index())} tracks indexed by path")

# Everything after this is driven by the playlist's own watch. `reload_mode =
# "watch"` up at the top already notices a file appearing and its on_reload
# sets rescan_at, so nothing here polls the disk: an idle library costs one
# float comparison every five seconds, and a walk happens only when the
# library really changed - which is exactly when the operator wants the new
# track findable.
#
# on_reload takes no `synchronous` argument, unlike on_metadata and
# on_position, so there is no way to ask liquidsoap to move it off whatever
# thread reloads the playlist. Hence it does nothing but store a float, and
# the work happens here instead, on a thread of our own. `fast = false` puts
# this below request resolution, and on_error keeps a throw from killing the
# thread in silence - a dead thread here is an index that quietly stops
# updating with nothing on air to say so.
#
# A rescan rebuilds the whole index rather than diffing for what is new. The
# walk has to happen either way and it is the only part that costs the stream
# anything; working out which of 1175 paths are new would be upwards of a
# million string comparisons held inside the very lock the walk is already the
# problem for, to save tag reads that were measured to cost the stream
# nothing. The cheap-looking option is the expensive one here.
thread.run(every = 5.0, fast = false,
  on_error = fun (_) -> log.important(label = "search", "rescan failed"),
  fun () ->
    if rescan_at() > 0.0 and time() >= rescan_at() then
      rescan_at := 0.0
      index_paths()
      index_tags()
      log.important(label = "search",
        "rescanned: #{list.length(library_index())} tracks")
    end)

# The first tag pass. Runs once, after startup, off the streaming thread.
thread.run(fast = false,
  on_error = fun (_) -> log.important(label = "search", "tag pass failed"),
  fun () -> begin
    t0 = time()
    index_tags()
    log.important(label = "search",
      "tags read for #{list.length(library_index())} tracks in #{time() - t0}s")
  end)

# Case-insensitive substring, against the title, the artist AND the path - the
# whole path and not just the filename, because the folders carry the artist
# and the album for the untagged sixth of the library. "soda stereo" finds the
# track whether that is a tag, a folder name or part of a filename.
#
# Which of the three matched rides back with every hit, because otherwise the
# operator cannot tell why a row is there: a query can match a folder name and
# nothing that is visible in the row itself. Title first, then artist, then
# path, so the answer names the most specific field that matched.
#
# Capped at 50 - a console mid-broadcast cannot show hundreds - and `total`
# says how many there really were, so a query that is too broad reads as "50
# of 213" rather than as the whole library arriving. An empty query matches
# nothing rather than everything, which is what makes an empty search box
# harmless.
#
# string.index and NOT string.contains, which is the obvious call and was
# what this was first written with. Measured on this build over the 1175
# entries: string.contains costs 1.21 s a pass, string.index 0.075 s -
# sixteen times less for the same answer. That is not a micro-optimisation. A
# search runs on a harbor thread, and that thread holds the runtime lock the
# streaming thread needs, so with string.contains over three fields ONE query
# stalled the stream for 2.8 s. It is 0.13 s now, flat, whether the query
# matches 0 tracks or all 1175 - the cost is walking the list, not the hits.
#
# 0.13 s is a budget, not a free lunch, and it is the one thing a page calling
# this has to respect: SEARCH ON A PAUSE IN TYPING, NEVER ON EVERY KEYSTROKE.
# Measured: one search does not put the clock behind at all, eight back to
# back log a single 0.37 s catchup, and forty leave it 4.3 s behind.
#
# A plain substring and deliberately not a regexp, which was the other way to
# make it fast: the query is whatever the operator typed, and every bracket
# and apostrophe in this library would have to be escaped before it could be
# a pattern. There is nothing to escape for string.index.
def has(needle, s) =
  string.index(substring = needle, s) >= 0
end

def search(q) =
  needle = string.case(lower = true, string.trim(q))
  found =
    if needle == "" then
      []
    else
      list.filter(fun (e) -> has(needle, e.hay), library_index())
    end
  # Only ever asked about a row that already matched, so falling through to
  # "path" is the answer and not a guess.
  def matched_field(e) =
    if has(needle, e.lt) then
      "title"
    elsif has(needle, e.la) then
      "artist"
    else
      "path"
    end
  end
  { query   = string.trim(q),
    total   = list.length(found),
    limit   = search_max,
    results =
      list.map(
        fun (e) -> { id = e.id, title = e.title, artist = e.artist,
                     match = matched_field(e) },
        list.prefix(search_max, found)) }
end

# An id back to the path it stands for, and "" for anything else. This is the
# only place an id becomes a filename, and it can only ever produce a file
# that is already in the index.
def path_of_id(tid) =
  list.fold(
    fun (found, e) -> if found == "" and e.id == tid then e.path else found end,
    "", library_index())
end

# Put a track at the FRONT of the playlist's queue, by id. This is exactly
# what again() above does, for the reason recorded there: library.add is the
# obvious call and the wrong one, because it appends BEHIND whatever the
# playlist has already prefetched and the track would land one late.
#
# ONE endpoint with a flag rather than two. Queueing a track next and jumping
# to it now are the same act - this request, in front of the queue - differing
# only in whether the current track is also cut short, which is the single
# line that already separates again() from previous(). Two endpoints would
# mean resolving the id and repeating the not-found case twice over.
#
# An id that is not in the index is not an error. It is a console that
# searched before a rescan dropped the file, and answering 500 to that would
# take a page down over nothing: it does nothing at all and reports the state
# as it stands.
#
# This is the same list /control/queue below hands back, entered at the front
# rather than at the end, and that is on purpose: "play this next" and "put
# this at the end of the list" are two positions in one queue, not two queues.
# The track is annotated like any other entry, so a console that slips one in
# next sees it appear at the head of the pending list rather than watching a
# track it cannot account for arrive out of nowhere.
def enqueue(tid, jump) =
  p = path_of_id(tid)
  if p != "" then
    requeue(list.map(queued_uri, list.add(p, pending_paths())))
    if jump then library.skip() end
    how = if jump then "playing now" else "queued next" end
    log.important(label = "control", "#{how}: #{p}")
  end
end

# One pending entry as a console shows it. Exactly the shape a /control/search
# row has, minus the `match` that only a query gives meaning to, so a page can
# draw a search hit and a queue entry with the same code. The path does not go
# out, for the reason recorded at the index above; `id` is the same digest
# search and /likes/now already use, so a page can tell that the third thing in
# the queue is the track it just added.
def queue_row(r) =
  p = request.filename(r)
  m = request.metadata(r)
  n = track_name(m["title"], m["artist"], p)
  { id = string.digest(p), title = n.title, artist = n.artist }
end

# What all five of these answer with, so a page can act and redraw from one
# response - the same idea as endpoint() and like_endpoint() above. `error` is
# empty on success and is the whole reason this is not endpoint(): a queue is a
# list the operator is building and reading back, so an entry that silently
# fails to appear is a list that is quietly wrong, and it says so in the body
# as well as in the status code.
def queue_state(err) =
  q = list.filter(is_queued, library.queue())
  { error = err, total = list.length(q), queue = list.map(queue_row, q) }
end

# Append by id, and NOT by path: a client that could name a file could ask for
# any file on the disk liquidsoap can read, which is the reason recorded at the
# index above that the path never leaves this process. The id comes from
# /control/search, which is where a list gets built in the first place.
#
# request.resolve is what makes "cannot play" a fact rather than a guess, and
# it only tells the truth when it is given a content_type. Measured on this
# build against a file the account cannot open: plain request.resolve returns
# TRUE for it, because all it asks is whether the uri names a local file, and
# the entry then vanishes when set_queue comes to decode it - a 200 and an
# empty slot, which is exactly the silent nothing this must not do. With
# content_type = library it returns false, the same false it returns for a path
# the rescan has not caught up with, and the library logs which of the two it
# was. It costs one content check, on a harbor thread, and reads of that kind
# were measured further up to cost the streaming thread nothing because ffmpeg
# lets go of the runtime lock while it waits on the disk. It is only a probe:
# the entry it proves is then made again by requeue, because the list is held
# as paths and rebuilt whole every time it changes.
def queue_add(tid) =
  p = path_of_id(tid)
  if p == "" then
    "no track with id #{tid}"
  else
    r = request.create(queued_uri(p))
    ok = request.resolve(content_type = library, r)
    request.destroy(r)
    if ok then
      requeue(list.map(queued_uri, list.append(pending_paths(), [p])))
      log.important(label = "control", "queued last: #{p}")
      ""
    else
      log.important(label = "control", "cannot queue: #{p}")
      "cannot play the track behind #{tid}"
    end
  end
end

# The first entry with that id, because the same track queued twice is two
# entries the operator cannot tell apart anyway and either one leaves him with
# the one copy he asked for. Keyed by id and not by position, so a track
# starting between drawing the list and clicking on it cannot silently shift
# the click onto its neighbour: the entry is either still there or the answer
# says it is not.
def queue_remove(tid) =
  ps = pending_paths()
  i  = list.index(fun (p) -> string.digest(p) == tid, ps)
  if i >= list.length(ps) then
    "nothing in the queue with id #{tid}"
  else
    requeue(list.map(queued_uri,
      list.append(list.slice(length = i, ps), list.slice(offset = i + 1, ps))))
    log.important(label = "control", "unqueued: #{list.nth(ps, i)}")
    ""
  end
end

def queue_clear() =
  requeue([])
  log.important(label = "control", "queue cleared")
  ""
end

# Reordering, which costs almost nothing once the list is held as paths: every
# other call here already rebuilds the whole queue from them, so moving one is
# the same rebuild in a different order. `pos` is the position it should end up
# at, counted from zero within the pending list itself and not within the
# playlist's queue, which also holds the one prefetched shuffle track and
# whatever the repeat button has just put in front. It is not called `to`,
# which reads better and does not parse - that word is taken by the range in a
# for loop.
def queue_move(tid, pos) =
  ps = pending_paths()
  n  = list.length(ps)
  i  = list.index(fun (p) -> string.digest(p) == tid, ps)
  if i >= n then
    "nothing in the queue with id #{tid}"
  elsif pos < 0 or pos >= n then
    "#{pos} is not a position in a queue of #{n}"
  else
    rest = list.append(list.slice(length = i, ps), list.slice(offset = i + 1, ps))
    requeue(list.map(queued_uri, list.insert(pos, list.nth(ps, i), rest)))
    log.important(label = "control", "moved to #{pos}: #{list.nth(ps, i)}")
    ""
  end
end

def queue_endpoint(act) =
  fun (req, response) -> begin
    err = act(req)
    if err != "" then
      response.status_code(400)
      log.important(label = "control", "queue: #{err}")
    end
    response.json(queue_state(err))
  end
end

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
# Every knob worth a host's attention, and its current value, so the console can
# draw its own sliders instead of embedding liquidsoap's page in an iframe.
#
# Named explicitly rather than enumerated. liquidsoap's own page lists EVERY
# interactive variable, which is the wrong set for a person mid-broadcast: it
# mixes the two or three you actually reach for with several that will make you
# sound worse. Naming them here is also what lets the console give each one a
# sane range and a plain-language label.
#
# Setting is not here on purpose. The mixing desk's own POST /interactive with
# a body of name=value already does it, it is already proxied behind the
# speaker credential, and a second way to write the same variable is a second
# thing that can disagree.
def knobs() =
  [
    ("mic_gain",       mic_gain()),
    ("voice_gain",     voice_gain()),
    ("hp_freq",        hp_freq()),
    ("comp_thr",       comp_thr()),
    ("comp_ratio",     comp_ratio()),
    ("comp_gain",      comp_gain()),
    ("duck_to",        duck_to()),
    ("hold",           hold()),
    ("glide",          glide()),
    ("air_delay",      air_delay()),
    ("record_min",     record_min()),
    # The two switches ride in the same (string * float) shape as everything
    # else - 1.0 for on, 0.0 for off - rather than giving this endpoint a
    # second response type for two values. The console renders a checkbox for
    # them because it knows their names, and POST /interactive is unaffected:
    # that takes name=value as text and parses "true"/"false" for a bool.
    ("announce_intro", if announce_intro() then 1.0 else 0.0 end),
    ("announce_outro", if announce_outro() then 1.0 else 0.0 end)
  ]
end

harbor.http.register(port = 8005, method = "GET", "/control/knobs",
  fun (_, response) -> response.json(knobs()))

harbor.http.register(port = 8005, method = "POST", "/control/previous",
  endpoint(fun (_) -> previous()))
harbor.http.register(port = 8005, method = "POST", "/control/again",
  endpoint(fun (_) -> again()))
harbor.http.register(port = 8005, method = "POST", "/control/repeat",
  endpoint(fun (r) -> repeating := on_flag(r)))
harbor.http.register(port = 8005, method = "POST", "/control/music",
  endpoint(fun (r) -> music_on := on_flag(r)))
harbor.http.register(port = 8005, method = "POST", "/control/pause",
  endpoint(fun (r) -> paused := on_flag(r)))
# Said by a console whose host has opened or shut their microphone. This is NOT
# a mute: the audio is already gone, cut at the browser where it costs nothing
# and cannot be heard on the way. It tells the ducking whether there is a voice
# to make room for.
harbor.http.register(port = 8005, method = "POST", "/control/talking",
  endpoint(fun (r) -> live_open := on_flag(r)))

# Find a track, then queue it. The only two endpoints here that do not answer
# with the state object: a search is a question about the library rather than
# about what is on the air, so it has an answer of its own. Enqueue does
# answer with the state, like everything else, so the console can act and
# redraw from the one response.
#
# `now` rather than on_flag's `on`, and that is the one place this file has
# two ways to read a flag. on_flag exists for switches, where the name of the
# thing and its state are the whole meaning - music?on=false. Nothing here is
# being switched on: `now` says WHEN the track lands, and enqueue?on=true
# would say nothing a reader could follow.
harbor.http.register(port = 8005, method = "GET", "/control/search",
  fun (req, response) -> response.json(search(req.query["q"])))
harbor.http.register(port = 8005, method = "POST", "/control/enqueue",
  endpoint(fun (r) -> enqueue(r.query["id"], r.query["now"] == "true")))

harbor.http.register(port = 8005, method = "GET", "/control/queue",
  queue_endpoint(fun (_) -> ""))
harbor.http.register(port = 8005, method = "POST", "/control/queue/add",
  queue_endpoint(fun (r) -> queue_add(r.query["id"])))
harbor.http.register(port = 8005, method = "POST", "/control/queue/remove",
  queue_endpoint(fun (r) -> queue_remove(r.query["id"])))
harbor.http.register(port = 8005, method = "POST", "/control/queue/clear",
  queue_endpoint(fun (_) -> queue_clear()))
harbor.http.register(port = 8005, method = "POST", "/control/queue/move",
  queue_endpoint(fun (r) ->
    queue_move(r.query["id"], int_of_string(default = -1, r.query["to"]))))

# --- the station speaking in the chat --------------------------------------
# One line in the room's own chat, written the same way a listener's browser
# writes one: a small .md per line in RADIO_HOME/chat, with the timestamp and
# the name in front matter. No new endpoint, no new store, nothing for a page
# to learn - whatever is already reading the chat reads this too.
#
# svc-radio can write there. It holds Modify on that one folder, which was
# checked rather than assumed, and the source tree is read-only to it
# otherwise. A failed write is caught: a line in the chat is not worth taking
# the station off the air for, exactly as with the likes ledger.
#
# LF and not CRLF, deliberately. The page parses the front matter with
# /^---\n([\s\S]*?)\n---/ - literal \n - so a CRLF file would not match and
# the whole line would fall back to "anonymous" with the front matter left
# sitting in the message body.
#
# The filename carries the timestamp because the page sorts by it before it
# has read a single file, and shows the last sixty. Same shape the browser
# uses, so the station's lines and the listeners' interleave correctly.
def pad2(n) =
  if n < 10 then "0#{n}" else "#{n}" end
end

def chat_say(name, text) =
  t    = time.utc()
  ymd  = "#{t.year}-#{pad2(t.month)}-#{pad2(t.day)}"
  hms  = "#{pad2(t.hour)}#{pad2(t.min)}#{pad2(t.sec)}"
  iso  = "#{ymd}T#{pad2(t.hour)}:#{pad2(t.min)}:#{pad2(t.sec)}.000Z"
  # Four hex characters off a digest of the clock, which is what the browser's
  # four random characters are for: two lines written inside one second want
  # two different names.
  seed = "#{time()}#{name}"
  tag  = string.sub(string.digest(seed), start = 0, length = 4)
  try
    file.write(
      data = "---\nat: #{iso}\nname: #{name}\n---\n\n#{text}\n",
      "#{radio_home}/chat/#{ymd}T#{hms}000Z-#{tag}.md")
  catch _ do
    log.important(label = "chat", "could not write a line")
  end
end

# --- what happened earlier -------------------------------------------------
# The station's own record of its evening: what played, what the room voted
# off, and when somebody went live.
#
# Kept HERE rather than in each page, and that is the whole point. A list a
# browser remembers starts empty for everybody who arrives, so a listener who
# tunes in now is told the station has played nothing - the opposite of what
# "earlier" means. Kept here it is the same for the room, and somebody who has
# just arrived can see the hour they missed.
#
# In live/, the one folder svc-radio may write, and append-only for the two
# reasons the likes ledger is: one small write per event however long the
# station has been up, and nothing a crash can half-rewrite.
#
# ONE SHAPE for every event, with a `kind` to tell them apart and empty strings
# where a field does not apply. Not tidiness - a liquidsoap list is uniform, so
# three record types could not share one list or one response at all. `kind` is
# what lets a page draw a vote-off differently from a track without inspecting
# which fields happen to be filled in.
earlier_file = "#{radio_home}/live/earlier.jsonl"

# What is served. The file grows for as long as the station runs; a page asking
# what happened earlier wants the last hour, not the last month, and a phone
# should not be handed a megabyte to draw forty lines from.
earlier_max = 60
earlier = ref([])

def earlier_blank() =
  { kind = "", at = "", title = "", artist = "", name = "" }
end

# Newest LAST, the order the file is written in and the order a log reads in.
# A page wanting newest-first can reverse forty items; a station storing them
# backwards has to think about it on every append.
def earlier_add(e) =
  kept = list.append(earlier(), [e])
  n = list.length(kept)
  earlier := if n > earlier_max then list.tl(kept) else kept end
  try
    file.write(append = true,
      data = json.stringify(compact = true, e) ^ "\n", earlier_file)
  catch _ do
    # The same rule as the likes ledger: an evening of history is not worth
    # taking the station off the air for, and the copy above is already
    # updated - so a failed write costs the restart, not the broadcast.
    log.important(label = "earlier", "could not write the log")
  end
end

# The clock, in the format the chat lines already use.
def earlier_now() =
  t = time.utc()
  "#{t.year}-#{pad2(t.month)}-#{pad2(t.day)}T#{pad2(t.hour)}:#{pad2(t.min)}:#{pad2(t.sec)}.000Z"
end

# One line -> one event, or nothing. Parsed per line so a half-written tail
# costs that line and not the evening, which is what the likes ledger learned.
def earlier_parse(line) =
  try
    let json.parse ( e : {
      kind : string, at : string, title : string, artist : string, name : string
    } ) = line
    [e]
  catch _ do
    []
  end
end

# Read back at startup so a restart does not erase the evening.
def earlier_load() =
  raw =
    try
      string.split(separator = "\n", file.contents(earlier_file))
    catch _ do
      []
    end
  all = list.flatten(list.map(earlier_parse, raw))
  n = list.length(all)
  # Only the tail. Dropping from the front one at a time rather than reaching
  # for a slice: the list is at most a few thousand long once a day, this runs
  # once at startup, and it needs no function this build may not have.
  def rec drop_to(l) =
    if list.length(l) > earlier_max then drop_to(list.tl(l)) else l end
  end
  earlier := if n > earlier_max then drop_to(all) else all end
end
earlier_load()
log.important(label = "earlier", "#{list.length(earlier())} events loaded")

# Public, like the likes and the tug, and for the same reason: there is nobody
# to log in as, and what played is not a secret. The file PATH never goes out -
# only a title and an artist, which is what a page shows anyway.
harbor.http.register(port = 8005, method = "GET", "/earlier",
  fun (_, response) -> response.json(earlier()))

# --- crowd skips -----------------------------------------------------------
# How many times the room has taken this track off. The other half of the
# sentence the heart starts: a station can already say a track is loved, and
# this says one keeps being voted off.
#
# Kept exactly as the likes are, and deliberately so - same shape, same
# lifetime, same failure behaviour - because they are the same kind of fact
# about the same thing, and two facts kept two different ways is how they end
# up disagreeing. Per file path, for all time, one appended line each, counted
# in memory and rebuilt from the file at startup.
#
# Keyed by PATH and not by title for the reason the likes are: about one track
# in seven of this library is untagged and comes back with an empty title, so
# every untagged track would share one pile.
skips_file = "#{radio_home}/live/skips.jsonl"
skips = ref([])

def skip_count(p) =
  list.assoc(default = 0, p, skips())
end

def bump_skip(p) =
  n = skip_count(p) + 1
  skips := list.add((p, n), list.filter(fun (kv) -> fst(kv) != p, skips()))
end

def record_skip(p) =
  try
    file.write(append = true,
      data = json.stringify(compact = true, { path = p }) ^ "\n", skips_file)
  catch _ do
    log.important(label = "skips", "could not write the ledger")
  end
end

# One line -> the path it names, or "" for a line that is not one: the empty
# tail after the last newline, or half a line left by a crash. Parsed per line
# so one bad line costs itself and not the ledger.
def skip_path(line) =
  try
    let json.parse ( e : { path : string } ) = line
    e.path
  catch _ do
    ""
  end
end

list.iter(
  fun (line) -> begin
    p = skip_path(line)
    if p != "" then bump_skip(p) end
  end,
  string.split(separator = "\n",
    try file.contents(skips_file) catch _ do "" end))
log.important(label = "skips", "#{list.length(skips())} skipped tracks loaded")

# --- the skip tug of war ---------------------------------------------------
# Public, like the likes below and for the same reason: there is nobody to log
# in as here, and there was never meant to be. The difference between the two
# is the one that matters, and it is why this has its own block in the
# caddyfile as well: a like cannot change what is on the air and a pull can.
#
# ONE counter per track, an integer from 0 to 12. Not a tally per listener, not
# two opposing totals - one number that everybody in the room pushes and pulls.
# A skip click adds one, a keep click takes one away, and at 12 the track goes.
#
# The range is deliberately ASYMMETRIC. Only the top of it does anything: 0 is
# the floor and nothing more, and a keep click at 0 is simply a click that does
# nothing. There is no state at the bottom, no "this track has been saved", and
# that absence is the design rather than an omission.
#
# What that buys is the whole point of the thing, and it is easy to design away
# by accident, so it is written down here: KEEPING A SONG IS NOT A VETO, IT IS
# EFFORT. Somebody who does not want the skip has to keep clicking the counter
# back down while the others push it up. They cannot object once and be done,
# and they cannot hold a block that lasts the rest of the song. So the loudest
# brief opinion does not win, and nobody owns the track.
#
# Everything a threshold would have given us is absent for the same reason.
# There is no percentage, no quorum and no unanimity anywhere in this, and that
# is what makes it work on a station with two listeners, where "sixty percent
# of the audience" is one person with a casting vote. Twelve is not a majority
# of anything; it is friction. You have to want it, and anybody at all can pull
# it back.
#
# There is no per-person budget either, and that is the reading this was built
# to: a determined listener who is alone CAN click twelve times and skip. That
# has to be true or "a single person not wanting the skip must keep the counter
# down" describes nothing. What stops a held key or a script running it to 12
# in a second is metering - caddy's rate limit on /tug/*, and a minimum gap
# between clicks in the page - and metering is not a vote budget: it bounds the
# rate, never the total.
#
# Nothing here is written to disk. The likes ledger exists because a like is
# meant to outlive the song; the counter is the opposite - it is per play, and
# the right thing for it to lose in a restart is all of it.
tug_span = 12

# How long after a track starts the counter refuses every click.
#
# It is here because of something the operator noticed on air: "sometimes the
# title changes and the old sound is not yet gone". There is no crossfade in
# this file - tracks cut - so that overlap is not the mix. It is DISTANCE. The
# page reads current_file() live at the station while the audio reaching a
# listener is several seconds behind, through icecast's burst and then their
# own player's jitter buffer. The page is ahead of the ear.
#
# The consequence is the thing that matters, and it is not cosmetic: for the
# first seconds of a new track anybody clicking is voting on a song THEY HAVE
# NOT HEARD YET. Usually against the one they are still hearing. So the window
# is closed rather than the display delayed - the title arriving early is a
# feature, and a vote arriving early is not a vote.
#
# It applies to every track change and not only the ones the counter caused: a
# natural boundary carries exactly the same lag. It applies to keep as well as
# skip, which costs nothing - keep is already a no-op at 0 - and makes this one
# rule instead of two, the same economy as the clamp below.
#
# FIVE SECONDS IS A GUESS AND NOT A MEASUREMENT. It is the operator's number,
# chosen against the overlap he could hear, and the true figure is per listener
# and unknowable from here - burst-size is measured elsewhere in this repo at
# 484ms to first audio, but a phone on a train buffers what it likes on top of
# that. Anybody who measures a real distribution should change this number.
#
# air_delay is ADDED to it rather than left out, because it is the same
# distance by a different name: whatever the music is held back before the mix
# is time the page has already moved on and the ear has not. Written as a sum
# so that tuning air_delay cannot silently leave this behind - which it did
# for one evening, and the symptom was the old song still sounding after a
# skip that the counter said had happened.
tug_cool = 5.0 + air_delay()

# There is deliberately NO gap here, and there was one for about an hour.
#
# A jukebox pause before the change was tried - stop, move, start - on the
# theory that the moving is what makes a change read as a decision rather than
# a glitch. On the air it is a fake: the station is not moving anything, and
# 0.8s of manufactured silence is 0.8s less music. The operator's verdict was
# "no pause, no fake 0.8s".
#
# What sells the change belongs on the LISTENER PAGE, where a record can
# visibly be swapped while the next one buffers and it costs nobody any audio.
# Here the only correct behaviour is to leave the old track as fast as the
# encoder allows, which was measured at 20ms from the twelfth click.

# The counter, and the song it belongs to. `tug_track` is held as the path,
# which is what /likes/now already keys on - it hands the page a digest of this
# same string, so the page needs no second notion of what is playing.
#
# Resetting is done by COMPARING that key on the way in rather than by a hook
# at the track boundary, and that is worth the sentence it costs. A boundary
# hook does exist and is tempting: forward_meta at the foot of this file
# already runs once per track. It would reset the counter against
# `m["filename"]`, while every read and write here asks current_file() - a
# different question of a different object - so a click arriving in the window
# between the two would land on a song that has already gone. Compared here
# there is no window at all: the call that decides which track this is, is the
# same call that decides whether the counter belongs to it. It also adds
# nothing whatever to the audio path, which in this file is a rule and not a
# preference: a gate() added there typechecked, started, played for an hour and
# then killed the audio clock with a stack overflow.
tug_track = ref("")
tug_pull  = ref(0)

def tug_sync(p) =
  if p != tug_track() then
    tug_track := p
    tug_pull  := 0
  end
end

# How much of the cool-off is left, in seconds, and 0.0 once it is over.
#
# Taken from how far into the track we are, NOT from a timestamp written when
# the change was noticed. A timestamp was the obvious way and it is worse here
# for one reason: tug_sync only runs when somebody asks, so on a station nobody
# is polling the clock would start whenever the next request happened to
# arrive, and the first click after a quiet spell would be refused for five
# seconds no matter how long the song had been playing. source.elapsed is the
# quantity actually wanted - "this track has been on for less than five
# seconds" - it is already read one line below for the page's own clock, it
# resets itself at a boundary with nothing to arm and nothing to drift, and it
# holds no state at all. Nothing is added to the audio path either way; this
# just adds less.
#
# A negative elapsed is a source saying it does not know, and it opens the
# window rather than closing it forever. The same rule the duration comment
# below states: a negative is not a small number, it is an absence, and an
# absence must not be able to lock the counter for the rest of a track.
def tug_cool_left(e) =
  if e >= 0.0 and e < tug_cool then tug_cool - e else 0.0 end
end

# One click, +1 for skip and -1 for keep, clamped into 0..tug_span, and refused
# outright inside the cool-off.
#
# Refused, and NOT held to be applied when the window lifts. That distinction is
# the whole safety of it: a queue of clicks cast in the first five seconds is a
# queue of votes about the PREVIOUS song, and releasing them the moment the
# window opened would chain-skip the new one on the strength of them. A click
# during the cool-off is not deferred, it is not counted, it does not exist. The
# counter is 0 when the window opens because it was 0 all the way through.
#
# The skip fires on the click that ARRIVES at 12 and only on that one, because
# a click that does not move the counter does nothing at all - which is the
# same line that makes a keep click at 0 a no-op, rather than two rules. That
# matters for more than tidiness: it is what stops an overrun skipping a second
# track, and the clamp is doing real work there rather than covering a case
# that cannot happen. Measured, fifteen clicks fired at one track in a single
# burst: they came back 1..12, then 12, 12, then 1. The thirteenth and
# fourteenth arrived while current_file() still named the outgoing track and
# were held at 12 by the clamp; only by the fifteenth had library.skip() moved
# the station on, and that one started the new track's counter honestly at 1.
# Without the clamp the thirteenth would have read 13, cleared the threshold a
# second time, and cut off a song nobody had voted on. The log for that burst
# has exactly one "reached 12" in it.
#
# The operator's own skip, POST /control/skip behind the speaker credential, is
# deliberately untouched by all of this. The counter is what the room can do;
# it was never meant to take the console away from whoever is hosting.
#
# library.skip() is the same call /control/skip has always made, from the same
# harbor thread - no new source, no new operator, nothing new in the audio
# path. Skipping was already possible here; this only gives the room a way to
# ask for it.
def tug(dir) =
  p = current_file()
  tug_sync(p)
  left = tug_cool_left(source.elapsed(library))
  v = tug_pull() + dir
  n = if v < 0 then 0 elsif v > tug_span then tug_span else v end
  if left > 0.0 then
    log.important(label = "tug", "too early: #{left} s of the cool-off left")
  elsif p != "" and n != tug_pull() then
    tug_pull := n
    log.important(label = "tug", "#{n}/#{tug_span} on #{p}")
    if n >= tug_span then
      log.important(label = "tug", "the counter reached #{tug_span}: skipping")
      # Said BEFORE the skip, because after it the metadata belongs to the
      # next track and the line would name the wrong song.
      # Literal UTF-8 rather than \u escapes: liquidsoap strings are bytes, and
      # a surrogate pair is a javascript convention this parser owes nobody.
      # These are the only non-ascii characters in this file.
      # NOTHING IS SAID IN THE CHAT, and something used to be: a line signed
      # with a recycle glyph, naming the track the room had just taken off.
      #
      # `earlier` records that same event now, as a fact about the track rather
      # than as a line in a conversation - which is where it belongs. The chat is
      # people talking to each other and the station is not one of them. Two
      # records of one event also drift, and the one in the chat could never be
      # corrected or taken back once written.
      #
      # The operator, on seeing a run of them: "there shouldn't be a message on
      # chat, not even 'sysadmin' since we have earlier".
      np = now_playing()
      # Its own kind. The track event records what STARTED; this records what
      # the room did to the one before it, so a page can mark that entry
      # without working out which of two adjacent tracks was voted off.
      earlier_add(earlier_blank().{
        kind = "voted", at = earlier_now(), title = np.title, artist = np.artist })
      # And on the track itself, for all time, the way a like is. `p` is the
      # path this counter is keyed by and is already in hand from the top of
      # tug() - current_file() is asked once there for exactly this reason.
      if p != "" then
        bump_skip(p)
        record_skip(p)
      end
      library.skip()
    end
  end
end

# --- the show --------------------------------------------------------------
# What a broadcast is, in the host's own words: a name for it, what is going
# out, and anything they want said beside the two. None of the three can be
# derived here, and the middle one is the reason this exists at all - a bucket
# set is playing inside somebody else's browser tab and reaches this station
# as audio and nothing else, so the only way the room can be told what it is
# hearing is for the host to type it.
#
# Held in memory and written nowhere. A show is one broadcast, and the right
# thing for it to lose in a restart is all of it - the same call the tug
# counter makes, and the opposite of the likes ledger, which is about the
# library rather than about this afternoon.
#
# `connected` moved up here out of input.harbor below, because it is now read
# by two things rather than one: the ducking, which is what it was written
# for, and the public state, which has to give the same answer. It is still
# set from nothing but the harbor's own two callbacks - asking the source
# itself is not reliable, a dropped one goes on looking alive for a while -
# and a second flag beside it would be a second answer to "is anybody live"
# that could be caught disagreeing with the first at exactly the boundary
# where it matters.
connected = ref(false)

show_name  = ref("")
show_title = ref("")
# Held apart from the title rather than typed into it. One box said
# "title / artist" and the slash was doing a schema's work: two facts in one
# string, with nothing downstream able to say which half was which. A page
# can join them and cannot split them - a title may contain " - " of its own,
# which is the same reason the earlier log joins rather than splits.
#
# The same 120 as the title because it is the same kind of thing and a second
# number would be a second thing to keep in step with a maxlength.
show_artist = ref("")
show_note  = ref("")

# The folder this broadcast writes its posts into, minted on connect and
# cleared on disconnect - so it is the same thing a show IS, and no console
# can choose it. A console that picked its own would disagree with a second
# console, and with itself after a reload, about where the evening was going.
show_id    = ref("")

# What has been written into that folder: "n:rev" pairs, comma separated, in
# the order they were posted. A list and not an index FILE, because the show
# record is already polled by every listener every five seconds - so this
# costs no fetch, has no second write to fall out of step with the first, and
# is cleared by the one thing that ends a show. The .md files stay on disk;
# the cards leave the page because the station stopped mentioning them.
#
# The rev is what makes an edit visible. A listener caches a post by folder,
# number and rev, so a repost of the same number under a new rev is a fetch
# and everything else is not.
show_posts = ref("")

# When this broadcast started, frozen at connect. A folder name a person can
# read in a directory listing, which is what the archive will be browsing later.
# UTC like every other stamp the station writes, and no punctuation a path
# would have to escape.
show_began = ref("")
def show_stamp() =
  t = time.utc()
  "#{t.year}#{pad2(t.month)}#{pad2(t.day)}-#{pad2(t.hour)}#{pad2(t.min)}#{pad2(t.sec)}"
end

# The console offers a slug and this decides whether to take it. It is offered
# rather than computed here because a browser folds accents in one line and
# this language does not: "oir esto" out of "oír esto" is worth having, and a
# regex over bytes would give "o-r-esto".
#
# Offered is not granted. What comes back becomes a PATH, so it is checked
# against a shape rather than cleaned into one - lowercase, digits, hyphens,
# and a first character that is not a hyphen so no folder can be mistaken for
# a flag. Anything else falls back to the crude version below, which cannot
# produce a bad path because it can only produce those same characters.
def show_slug(offer, name) =
  if string.match(pattern = "^[a-z0-9][a-z0-9-]{0,47}$", offer) then
    offer
  else
    t = string.case(lower = true, name)
    t = string.replace(pattern = "[^a-z0-9]+", fun (_) -> "-", t)
    t = string.replace(pattern = "^-+", fun (_) -> "", t)
    t = string.replace(pattern = "-+$", fun (_) -> "", t)
    t = if string.length(t) > 48 then string.sub(t, start = 0, length = 48) else t end
    t = string.replace(pattern = "-+$", fun (_) -> "", t)
    if t == "" then "untitled" else t end
  end
end

# Shows and songs are both folders directly under posts/, so one name has to be
# kept apart: a show actually called "songs" would put broadcast folders inside
# the folder song notes live in. Cheap insurance against something that will
# probably never happen and would be baffling if it did.
def show_folder(offer, name) =
  t = show_slug(offer, name)
  if t == "songs" then "songs-show" else t end
end

# A directory and then its parent, each only if it is EMPTY, and that check is
# not tidiness - file.rmdir removes a directory AND ITS CONTENT, so emptiness
# is the entire safety of calling it. Nothing that holds anything is removed,
# at either level, ever.
#
# Both levels because the show folder above the stamp is left behind too: an
# "untitled" holding nothing is the same litter one directory up.
def show_sweep(dir) =
  try
    if file.exists(dir) and list.length(file.ls(dir)) == 0 then
      file.rmdir(dir)
      parent = path.dirname(dir)
      if file.exists(parent) and list.length(file.ls(parent)) == 0 then
        file.rmdir(parent)
      end
    end
  catch _ do
    ()
  end
end

# OFF THE AIR, THE FOLDER IS THE SONG. A host should not have to open a
# microphone to say something, and between shows what they say is about whatever
# is playing - so a post is filed under the track it was written under, and it
# leaves the page when that track does.
#
# The list is emptied, not the folder. posts/songs/<track>/ keeps every note
# ever written about that track, which is an archive worth having and costs
# nothing; what the page shows is only ever the notes for the song in the room
# right now, because show_posts is what the page reads and this clears it.
#
# Called from forward_meta, which hangs off the DELAYED source - so the folder
# turns over when a listener hears the change rather than when the library
# handed the file across, and a note written in the last second of a track
# belongs to the track the writer was hearing.
def song_settle() =
  if not connected() then
    n = now_playing()
    was = show_id()
    # Named locals rather than one expression: interpolation does not nest, and
    # a #{} inside a string inside a #{} makes the parser report an unterminated
    # string on line 1 of the file.
    label = "#{n.artist} #{n.title}"
    show_id := "songs/" ^ show_slug("", label)
    show_posts := ""
    dir = "#{radio_home}/posts/#{show_id()}"
    try
      file.mkdir(parents = true, dir)
    catch _ do
      ()
    end
    if not file.exists(dir) then
      log.important(label = "posts", "CANNOT MAKE #{dir}")
    end
    # The folder of the song just gone, if nobody wrote anything in it. Same
    # sweep the shows use and the same reason: an archive somebody browses
    # should not be mostly empty folders for tracks nobody had a thought about.
    if was != "" and was != show_id() then
      show_sweep("#{radio_home}/posts/#{was}")
    end
  end
end

# Settled at connect and re-settled on every show_set FOR AS LONG AS THE FOLDER
# IS EMPTY. A host presses Go on air and names the show afterwards, so the
# first answer is usually "untitled" and the second one is right; once a post
# has been written the folder can no longer move, because moving it would
# orphan what is already in it. show_posts being "" is exactly "nothing has
# been written yet", so the rule needs no flag of its own.
#
# The directory is made HERE. A PUT does not create a missing parent - webdav
# answers 409 - and the alternative was allowing MKCOL through a write route
# that is deliberately four extensions wide. A failure is logged and not
# raised: the console will hear about it from its own PUT, which is the place
# a host can act on it.
def show_settle(offer) =
  if connected() and show_posts() == "" then
    # What it was, if it was anything. A show settles at connect under whatever
    # name exists - usually none - and again when the host types one, and the
    # first folder has to go or every broadcast leaves an empty "untitled"
    # behind it in an archive somebody is going to browse.
    was = show_id()
    show_id := "#{show_folder(offer, show_name())}/#{show_began()}"
    dir = "#{radio_home}/posts/#{show_id()}"
    try
      file.mkdir(parents = true, dir)
    catch _ do
      ()
    end
    # ASKED, NOT ASSUMED. The first version of this trusted the catch, and when
    # the station turned out to have no write access to posts/ the catch never
    # fired: there was no log line anywhere, the folder was simply absent, and
    # the only symptom was a bare "HTTP 409" on the console an hour later.
    # Whatever file.mkdir does on a permission error is not what `try` was
    # waiting for, so this asks the filesystem the question it actually cares
    # about - is the directory there - which no unforeseen error type can
    # answer wrongly.
    if not file.exists(dir) then
      log.important(label = "posts",
        "CANNOT MAKE #{dir} - posts/ must be writable by the account this "
        ^ "service runs as, the way live/ already is. Every post will answer 409 "
        ^ "until it is.")
    end
    if was != "" and was != show_id() then
      show_sweep("#{radio_home}/posts/#{was}")
    end
  end
end

# Characters, not bytes, and which of the two has to be said out loud because
# they differ for every host who names a show in Spanish. Measured on this
# build: ten e-acutes are 10 characters and 20 bytes, and cutting at 8
# characters gives 16 bytes with no character cut in half.
#
# The catch is not decoration. A byte sequence that is not UTF-8 at all -
# which no browser sends and curl will - makes string.length throw, and a
# throw inside a harbor handler answers 500. Measured: ten raw 0xFF bytes land
# in the catch and come back empty, while one 0xFF inside otherwise valid text
# never reaches it and leaves the json encoder as U+FFFD.
def show_clip(n, s) =
  try
    if string.length(encoding = "utf8", s) > n then
      string.sub(encoding = "utf8", s, start = 0, length = n)
    else
      s
    end
  catch _ do
    ""
  end
end

# `live` is connected() rather than a fourth ref, for the reason given above
# it. The three strings are answered as they were typed: the json encoder
# escapes them, and the page that receives them builds its DOM with
# textContent, which is what makes it safe for a listener to be shown words
# somebody else wrote.
def show_state() =
  { live   = connected(),
    name   = show_name(),
    title  = show_title(),
    artist = show_artist(),
    note   = show_note(),
    id     = show_id(),
    posts  = show_posts() }
end

# One call carries the whole show, and a parameter left out means an empty
# one. Deliberately not a partial update: three fields that may each be
# present or absent is eight meanings for one endpoint where "this is the
# show" is one, and the console has all three of them in front of it every
# time it asks. Clearing is then a POST with no parameters at all, which the
# harbor answers - a bare trailing `?` with nothing after it is the one shape
# it does not, and comes back 404.
# Remembers the last name recorded in the log, so a host editing their note
# five times does not put five entries in it. Reset on disconnect with the
# rest of the show, so the same name next week is a new show and says so.
show_logged = ref("")

def show_set(req) =
  show_name   := show_clip(60,  req.query["name"])
  show_title  := show_clip(120, req.query["title"])
  show_artist := show_clip(120, req.query["artist"])
  show_note   := show_clip(240, req.query["note"])
  # Digits, colons and commas or nothing at all. This string is handed to
  # every listener and each of them builds a URL out of it, so it is checked
  # HERE as well as there: one bad character at this end would be a path
  # somebody else's browser goes and asks for. Refused whole rather than
  # filtered, because a list that has had characters quietly removed from it
  # is a list whose numbers may have changed.
  posts = show_clip(600, req.query["posts"])
  show_posts :=
    if string.match(pattern = "^[0-9:,]*$", posts) then posts else "" end
  # The folder, which may still move while it is empty - a host names the show
  # after going on air far more often than before it.
  show_settle(show_clip(48, req.query["slug"]))
  # Into the log the first time a live show is given a name. Not on every
  # keystroke - the console saves as you type - and not when nobody is live,
  # which is a host filling the boxes in before they go on.
  if connected() and show_name() != "" and show_name() != show_logged() then
    show_logged := show_name()
    earlier_add(earlier_blank().{
      kind = "show", at = earlier_now(),
      name = show_name(), title = show_title(),
      artist = show_artist() })
  end
  log.important(label = "show",
    if show_name() == "" and show_title() == "" and show_artist() == ""
       and show_note() == "" then
      "cleared"
    else
      "#{show_name()} | #{show_artist()} - #{show_title()} | #{show_note()}"
    end)
end

# Behind the speaker credential because /control/ is: caddy's `handle
# /control/*` imports speakers, and this path falls inside that block with
# nothing to add. A listener must never be able to name somebody else's show,
# and /likes/*, the block that has no credential on purpose, stays a read.
#
# The GET is what a console reloaded mid-broadcast reads back, so a host who
# refreshes does not find three empty boxes and retype what is already on the
# air. Both answer with show_state, the same object the public gets, for the
# reason endpoint() and queue_endpoint() already give: act and redraw from one
# response.
#
# Registered here rather than up with the rest of /control/ because they
# answer with this state and have to come after it - the same call /tug/ makes
# by sitting beside the likes it answers with.
harbor.http.register(port = 8005, method = "GET", "/control/show",
  fun (_, response) -> response.json(show_state()))
harbor.http.register(port = 8005, method = "POST", "/control/show",
  fun (req, response) -> begin
    show_set(req)
    response.json(show_state())
  end)

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
likes_file = "#{radio_home}/live/likes.jsonl"

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

log.important(label = "config",
  "home #{radio_home} | music #{music_dir} | liquidsoap #{liq_home}")
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
#
# `total` is every like the station has ever been given, for the public page to
# show beside the listener count. Summed from the same in-memory map the count
# comes from - never a second read of the ledger, which is the whole reason
# that map exists - so it costs one pass over the DISTINCT liked paths, not
# over the likes. Derived rather than kept in a counter of its own on purpose:
# a running total is one more thing that can drift out of step with the map,
# and there is nothing to gain, since bump() already walks the same list.
# `elapsed` and `duration` ride along here because this is the one endpoint the
# public page is allowed to ask. Everything under /control/ sits behind the
# speaker password, and the listener page has no credential at all - so without
# this it could only guess the position, by timing from when it happened to
# notice the title change. That guess is right for someone who was already
# listening and too small for everyone who arrived mid-song, which is the half
# of the audience most likely to wonder.
#
# Cheap: both read the position of the frame being played, not the file. They
# are estimates by their own documentation and by their nature - a variable
# bitrate file does not know its own length precisely - so the page should say
# roughly and not to the second.
#
# Negative means unknown, which is what a source with no length answers, and it
# is passed through as it comes rather than turned into a zero. A zero would be
# a duration this station was confident about and wrong, where a negative is
# the source saying it does not know.
#
# `pull` and `rope` ride along here for the same reason `elapsed` and
# `duration` do, and it is the stronger argument of the two. A /tug/now of its
# own was the obvious shape and is the wrong one: the page would then be
# holding two answers, fetched a moment apart, about which song is on - and at
# a track boundary they would disagree for as long as a poll takes, so the page
# would draw one song's counter beside another song's likes and have no way to
# know it. One response is what every other endpoint in this file already
# answers with, for this reason. `rope` is the top of the range rather than
# something the page hardcodes, so twelve lives in exactly one place.
#
# `cool` goes out as the LENGTH of the window and not as what is left of it -
# the same shape as `rope`, a constant the page is told rather than one it
# hardcodes. What is left is then `cool` minus `elapsed`, and `elapsed` is in
# this same answer, so the page works it out from the same two numbers this file
# does and the two cannot drift apart by arithmetic.
#
# The show rides along for that same argument, made once more and at its
# strongest. A /show/now of its own would be a second poll, and at the one
# moment it matters - a host leaving the air - the two answers a page held
# would disagree, one still naming a show and the other already back to the
# music, for as long as a poll takes and with nothing in either to say which
# was written first. It also has to be here rather than anywhere: this is the
# only endpoint a page with no credential may ask, and the listener page is
# exactly that page.
#
# Sending the remainder was the first shape and it was measurably not enough.
# Measured in a headless browser against the live station: the page went dim
# 3672 ms after the click that caused the skip and cleared 1052 ms later. It had
# been told "0 seconds left" in the answer to that very click - correctly, since
# library.skip() had not moved current_file() yet - and then believed it until
# its next poll. Four of the five seconds were spent looking live while every
# click was being refused, which is the void this window exists to prevent.
#
# Handing over the length instead lets the page arm the window itself the
# instant it has proof one has started, without waiting to be told: the answer
# that says the counter reached `rope` IS that proof, because nothing else can
# take it there. A boolean could have done neither of these things.
#
# The sync is a write on the way out of a READ, which is unusual enough to say
# out loud: it is the lazy reset described up at the counter, and this is one
# of its two doors. Doing it here is also what makes a page that is merely
# watching see the counter go back to nought the instant the song changes.
def likes_state() =
  p = current_file()
  tug_sync(p)
  e = source.elapsed(library)
  { id       = if p == "" then "" else string.digest(p) end,
    likes    = like_count(p),
    # The other half of the same sentence, and served in the same breath so a
    # page can never draw one against a stale copy of the other.
    skips    = skip_count(p),
    total    = list.fold(fun (n, kv) -> n + snd(kv), 0, likes()),
    pull     = tug_pull(),
    rope     = tug_span,
    cool     = tug_cool,
    elapsed  = e,
    duration = source.duration(library),
    # Whether the playlist is being pulled at all. The public page showed the
    # frozen track under the words NOW PLAYING for as long as a bucket set
    # lasted, because everything it had said a track and said a position and
    # nothing said whether either was moving. `elapsed` cannot stand in for
    # this: a paused source is never asked for a frame, so its position simply
    # stops changing, and a page cannot tell that apart from a poll it has not
    # had yet.
    #
    # `paused` and not `music_on`, and they are not the same question. Music
    # off is a gain of zero over a record that keeps turning; paused stops
    # pulling the playlist. Only the second one means the track on the panel is
    # standing still, which is what the panel is now claiming.
    paused   = paused(),
    # Both of these are for the listener page's change of record, and both are
    # here rather than being worked out from something else.
    #
    # air_delay especially. /control/ is behind the speaker credential and this
    # endpoint is the only one a listener may ask, so the page had been reading
    # it as `cool - 5.0` - correct today, and correct only because tug_cool
    # happens to be written as 5.0 + air_delay(). Change that sum and the page
    # would have gone on subtracting five from it and timing its animation
    # against a number that meant nothing, silently. A value a page needs is a
    # value to publish, not one to reverse-engineer.
    air_delay  = air_delay(),
    record_min = record_min(),
    show     = show_state() }
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

# The two directions, registered down here rather than beside the counter
# itself because they answer with likes_state - the one object a page with no
# password may ask for, and the one it redraws all of this from. Two endpoints
# rather than one with a direction in the query: this file already has two
# ways to read a flag and does not need a third, and /control/ makes the same
# call for the same reason - skip and previous are two endpoints, not
# move?dir=. like_endpoint is reused rather than copied; it is not about likes,
# it is "do the thing, then answer with the public state".
harbor.http.register(port = 8005, method = "POST", "/tug/skip",
  like_endpoint(fun () -> tug(1)))
harbor.http.register(port = 8005, method = "POST", "/tug/keep",
  like_endpoint(fun () -> tug(-1)))

live = input.harbor(
  id            = "live",
  "live",
  port          = 8005,
  password      = environment.get("RADIO_HARBOR_PASSWORD"),
  # A fifth of a second, not a whole one. This is jitter absorption on the way
  # IN, added to every word a host says before it reaches the mix - half of why
  # a host talking over the music lands late against what they were hearing.
  # The other half is their monitor, which is what output.harbor below is for.
  #
  # Generous on a LAN, adequate from a phone on wifi. A source on a bad mobile
  # link will glitch sooner than it used to; `max` still allows ten seconds of
  # slack when a burst arrives.
  buffer        = 0.2,
  max           = 10.0,
  # Five, not twenty. This is how long the harbor keeps the mount after audio
  # stops, and it costs twice over: it is silence before the music comes back,
  # and it is a reconnect inside that window being refused with 403. Measured
  # on the first real broadcast - stop, try again, "cannot connect", wait,
  # works. That was never a fault, it was this number.
  #
  # The trade is real: a phone that loses signal for longer than this is
  # dropped rather than ridden through. Five is chosen for a host who starts
  # and stops often, which is what the first session actually looked like.
  timeout       = 5.0,
  on_connect    = fun (_) -> begin
    connected := true
    # The folder for this broadcast, and it is empty until something is posted
    # into it. Minted before the earlier entry below so that anything reading
    # the show record on the strength of that entry already has somewhere to
    # write.
    show_began := show_stamp()
    show_posts := ""
    # With whatever name is already typed, which is usually none - so this is
    # normally "untitled/..." until the console says otherwise, and the folder
    # moves under it while it is still empty.
    show_settle("")
    # The show metadata is almost always empty at this instant - a host presses
    # Go on air first and names the show afterwards, if at all - so this says
    # somebody went live and show_set records what they called it. Two events,
    # because they are two things that happened, and a host who never types a
    # name still appears here.
    earlier_add(earlier_blank().{
      kind = "live", at = earlier_now(), name = show_name() })
  end,
  # The show goes with the source, and this is the only place that can end
  # it. Nothing a host types carries a time, so a name left standing after
  # the socket went is a listener being told a show is on while the room is
  # already back to the music - and a host who left the air by closing the
  # tab, or by losing signal, is not going to come back and clear it.
  on_disconnect = fun () -> begin
    connected  := false
    # Reset rather than trusted to be tidied up: a console whose laptop lid
    # closed mid-mute would otherwise leave the next source, of any kind,
    # unable to duck the music.
    live_open  := true
    show_logged := ""
    # The cards go off the listener page here, and only here. Nothing is
    # deleted: the folder and every .md in it stay exactly where they were,
    # which is what makes an archive possible later.
    show_id     := ""
    show_began  := ""
    show_posts  := ""
    show_name   := ""
    show_title  := ""
    show_artist := ""
    show_note   := ""
  end
)

# --- voice notes -----------------------------------------------------------
# A folder that anything can drop audio into - the browser over webdav, a
# script, eGPT. Whatever appears is played once, over the ducked music. No
# streaming protocol involved: each file arrives as an ordinary upload with a
# content length, which is the part that has proven reliable.

voice_dir = "#{radio_home}/messages/voice"

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

# Nothing has ever stopped this loop finding a file that is still being written.
# The scan runs four times a second, and caddy's webdav writes an upload
# straight into the speaker's folder under its final name - there is no staging
# name and no rename, because over HTTP the body lands where it lands. So a note
# that takes any time at all to arrive is visible, and incomplete, for as long as
# it is arriving. /host/upload/ has had this exposure from the start and has got
# away with it only because a browser upload is small and finishes fast; the
# relay route hands the same folders to whatever a phone recorded over whatever
# signal it had. A writer cannot fix this from its end, so it is fixed here,
# once, for everything that writes into these folders.
#
# Measured on this build rather than assumed, because the whole idea rests on
# it: while a file is being written the mtime on disk keeps up with the writes,
# reading a quarter of a second old after a quarter-second pause and never
# staler, so it really is a signal of "still arriving" and not merely the moment
# of creation. file.mtime keeps the fraction as well - 1786208424.89 rather than
# a whole second - so a window shorter than a second is meaningful here.
#
# Half a second, against a poll every 0.25s. It has to be longer than one poll
# interval or a file written between two polls could already be settled the
# first time it is seen, which is the case being guarded against; two intervals
# means every file is looked at at least twice before it can queue. It costs a
# note at most 0.75s - the half second, plus the poll that notices it has
# passed - which is nothing beside the couple of seconds a note already takes to
# reach the air, and it is a long way short of the five minutes the cleanup
# below allows, so nothing can be binned while it waits.
settle = 0.5

def settled(f) =
  try
    time() - file.mtime(f) >= settle
  catch _ do
    # Cannot tell, so do not invent a reason to hold the file back: fall through
    # to is_new, which already treats an mtime it could not get as "not new" and
    # lets the note go the same way as one written before the station started.
    # A file that is simply gone reads 0.0 here, which is older than any settle
    # window and so passes straight through to that same decision.
    true
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
      # `settled` is asked BEFORE `seen` is written, and that order is the whole
      # of the guard. `seen` means "do not queue this path" and is never
      # revisited while the file is on disk, so a note marked seen while it was
      # still arriving would be dropped for good rather than played a moment
      # late - which is silently losing someone's note, the worst outcome here.
      # Leaving a file that is still changing out of `seen` altogether is what
      # gets it reconsidered on the very next poll, and every poll after, until
      # it stops changing. `and` is lazy on this build - measured - so a file
      # already in `seen` still costs no stat at all.
      if not list.mem(f, seen()) and settled(f) then
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
music_gain  = ref(1.0)
talking     = ref(false)
# When the air last went quiet, or 0.0 while someone is still on it. Wall clock
# rather than a count of calls: this runs once per frame, so counting calls
# means hardcoding the frame duration, and that duration is a hint liquidsoap
# is free to round. That is exactly how hold came to be worth half its face
# value for weeks without anyone noticing.
quiet_since = ref(0.0)

def duck_gain() =
  # A lane keeps its last metadata after the note has finished, so is_ready is
  # what says a note is still on air; the annotation only says what that
  # speaker wanted.
  ducking =
    (connected() and live_open())
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
    quiet_since := 0.0
  elsif talking() then
    # Slices arrive about 1.5s apart, so hold is what keeps the music from
    # pumping back up in the gap between one clip and the next.
    if quiet_since() == 0.0 then quiet_since := time() end
    if time() - quiet_since() >= hold() then
      talking := false
      log.important(label = "duck", "music back up")
    end
  end

  target = if talking() then duck_to() else 1.0 end
  music_gain := music_gain() + (target - music_gain()) * glide()
  music_gain()
end

# The bed a host monitors on: the music as it is RIGHT NOW, before the delay
# below holds it back for the air. That is the whole point of the delay - the
# host hears the present, talks to it, and the station waits for the words.
#
# It reads music_gain rather than calling duck_gain, and that distinction is
# load-bearing: duck_gain is not a reading, it MUTATES - it advances the fader
# one glide step, and logs. Called from two amplifies it would run twice per
# frame, so the fade would move at double speed and every "music down" would
# be logged twice. duck_gain is called in exactly one place, on the air path
# below, and this reads the value it left behind.
monitor_bed = amplify(fun () -> music_gain(), music)

# Delay FIRST, then duck. The other order is wrong in a way that is easy to
# miss: ducking before the delay bakes the dip into the audio at the moment it
# was decided, and then holds it back too, so a voice note would start and the
# music would dip a second and a half later. Ducking after the delay applies
# the dip to whatever is leaving for the air right now, which is what a
# listener hears alongside the voice.
music = amplify(duck_gain, delay_line(air_delay, music))

# Music first, so the track title still shows while you are talking over it.
# normalize=false so levels do not jump when the live source connects.
radio = add(id = "mix", normalize = false, [music, talk])

# --- the host's monitor ------------------------------------------------------
# A MIX-MINUS: everything except the person listening to it.
#
# The bed on /stream reaches a host about four seconds late, because icecast
# hands every new listener a 64KB burst on connect and at 128kbps that IS four
# seconds. No player setting gets underneath it. This is the same music without
# the burst, straight out of liquidsoap.
#
# Fed `music` and not `radio`, which is the entire point rather than an economy.
# `radio` carries the host's own voice back to them about a second after they
# said it, and delayed speech in your ears while you are speaking does not
# merely annoy - it breaks the sentence you are in. A host monitors their own
# voice locally at zero delay; the station sends them everything else.
#
# Tapped BEFORE the air delay and after the ducking, so the bed dips in the
# headphones exactly as it dips on air, while staying ahead of what listeners
# hear by whatever the air_delay dial is set to. That gap is the point: it is
# the room a host's voice needs to travel back and still land on the beat.
#
# MP3, and this was measured rather than chosen. Ogg/Opus was built first and
# had lower coder delay - but a client joining a live ogg stream mid-flight
# gets no OpusHead, and without those headers a browser cannot start the
# decoder at all: 15 OggS pages in, first one 4706 bytes deep, no OpusHead
# anywhere. MP3 is self-synchronising and any client can begin at any frame,
# which is why it is still what live streams use. The codec was never the
# bottleneck anyway - a browser buffers to its own taste and that dwarfs the
# difference between coders.
#
# ONE extra consumer, not two. A build with an mp3 and an opus monitor side by
# side typechecked cleanly, started, and died at once with "no more sources to
# process, global stop". A clean --check does not prove a graph will run; this
# file has learned that before, from a gate(). The delayed air path and this
# undelayed bed are the two branches off the music, and that pair was run on a
# throwaway instance on its own ports before it was run here.
#
# Port 8005, the harbor already up, with a mount of its own - no new port, no
# firewall rule, no layer4 branch. Caddy puts it behind the speaker credential:
# not because the audio is secret, it is the same music, but because this
# fan-out happens on the process that runs the audio clock and it is meant for
# a host or two rather than a crowd.
output.harbor(
  %ffmpeg(format = "mp3", %audio(codec = "libmp3lame", b = "128k", ar = 44100, ac = 2)),
  id    = "monitor",
  port  = 8005,
  mount = "monitor",
  # 8192 bytes - half a second at 128kbps. Not the 65534 DEFAULT, which is
  # 4.1 seconds and is exactly the delay this output exists to avoid: icecast
  # was taken out of the path and liquidsoap supplied the same figure from its
  # own default, so the monitor came out level with the public stream.
  #
  # And not zero, which was the first correction and overshot. With no burst
  # the browser starts holding nothing and every scrap of jitter becomes an
  # underrun; it sounded, in the operator's words, very bad. A burst is a
  # cushion. A listener needs a big one, a host needs a small one, and nobody
  # needs none.
  burst = 8192,
  monitor_bed
)

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
narrator_file = "#{radio_home}/live/narrator.json"

# What to say when the station has no idea what it is playing. About one track
# in seven of this library is untagged, and saying nothing sounds like
# something broke rather than like a radio.
# `ident` in narrator.json. Read FRESH each time it is needed rather than once
# at startup, so saving it on the narrator page changes what the next untagged
# track is called instead of waiting for a restart. It is the only narrator
# setting with no dial of its own, so a restart was the only way to apply it.
#
# Cheap enough to do this way: it reads one small file, and only on a track
# whose title is empty - about one in seven - rather than on every frame. And
# safe enough: narrator_cfg() is already wrapped, so a missing or half-written
# file falls through to the sentence below rather than throwing. That matters
# more here than it looks, because this is reached from a metadata callback,
# and a throw inside one of those kills it silently and titles stop reaching
# icecast while the music plays on.
def mystery() =
  narrator_cfg().ident ?? "this mystery song is yet to be tagged... we hope you enjoyed..."
end

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

# The sentence waiting to be said as the current track ends.
#
# It is built at the BOUNDARY and held, not read from the
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
pending_outro = ref("")

# TAGS ONLY, deliberately - no track_name, and so no filename. A filename is
# something to look at, not something to read out: this library holds
# "Piano Sonata No. 14 In C Sharp Minor (_Moonlight_), Op. 272", underscores
# and all, and names truncated mid-word. Spoken, a guess that is wrong out loud
# is worse than the station admitting it does not know - so an untagged track
# gets `mystery`, the line the operator writes on the narrator dashboard. That
# is what that setting was for.
#
# The display path is untouched: now_playing() and forward_meta below still go
# through track_name, because on screen the filename really is the best thing
# there is.
# What the narrator calls a track with no title: the `ident` from
# narrator.json, standing in as the NAME rather than as the whole sentence.
#
# That distinction is the difference between "You're listening to Please Tag Me
# Song" and "You're listening to. this mystery song is yet to be tagged... we
# hope you enjoyed...". A whole sentence can only ever fit one of the two
# moments; a name fits both, which is what makes one setting enough.
def spoken_name(m) =
  t = string.trim(m["title"])
  if t == "" then mystery() else t end
end

def intro_words(m) =
  n = spoken_name(m)
  a = string.trim(m["artist"])
  if a == "" then
    "You're listening to #{n}."
  else
    "You're listening to #{n}, by #{a}."
  end
end

def outro_words(m) =
  n = spoken_name(m)
  a = string.trim(m["artist"])
  if a == "" then
    "That was #{n}."
  else
    "That was #{n}, by #{a}."
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

# One new request is one track boundary: speak over the start if that switch
# is on, and leave the outro ready if that one is. Each switch is read at the
# boundary, so turning one off mid-track still cancels the line it was going
# to say about that track.
def announce(m) =
  req = string.concat(separator = "|", [m["rid"], m["filename"]])
  if req != last_track() then
    last_track    := req
    pending_outro := if announce_outro() then outro_words(m) else "" end
    if announce_intro() then
      w = intro_words(m)
      if w != "" then say(w) end
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
  n = track_name(m["title"], m["artist"], m["filename"])
  log.important(label = "meta", "forwarding #{n.title}")
  # An untagged file gets its own filename rather than the real metadata, so
  # the last good title cannot linger on the site as if it were this one - and
  # the station line only when even the filename came back empty.
  if string.trim(m["title"]) == "" then
    radio.insert_metadata(new_track = true, [
      ("title",  if n.title == "" then untagged_title else n.title end),
      ("artist", n.artist)])
  else
    radio.insert_metadata(new_track = true, m)
  end
  # The track that was playing has just ended, so it becomes the one to go
  # back to; then the new one takes its place. Order matters - swap these two
  # lines and previous() would hand back the song you are already hearing.
  # A track cut short by previous() is not remembered: it did not finish, it
  # was interrupted, and recording it would break walking backwards.
  if rewinding() then
    rewinding := false
  else
    remember(now_file())
  end
  now_file := m["filename"]
  # Recorded off the DELAYED source, because forward_meta hangs off it - so the
  # timestamp is when a listener hears the track begin rather than when the
  # library handed it over, and those are air_delay apart.
  earlier_add(earlier_blank().{
    kind = "track", at = earlier_now(), title = n.title, artist = n.artist })
  # And the folder a post would go into turns over with it. Does nothing while
  # somebody is live: a show owns its own folder for the whole broadcast, however
  # many records go past underneath it.
  song_settle()
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
