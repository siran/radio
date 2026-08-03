# Reads plain text files aloud on the air.
#
# Drop a .txt or .md into any speaker folder under messages\voice and this loop
# speaks it with Piper, leaving a .wav behind in the same folder. The
# voice-note pickup already running inside liquidsoap finds that wav and plays
# it exactly like a phone recording - same lane, same settings.json, same
# ducking. Liquidsoap never learns that text is a thing; the only new idea in
# the station is "a file appears, a watcher acts", which is the shape the admin
# watcher and the voice notes already have.
#
# Runs from a scheduled task at startup. Safe to stop and start at any time.
$ErrorActionPreference = 'Continue'

$voice = 'C:\Users\an\src\radio\messages\voice'

# Piper, out of its own venv. It is a python package rather than an exe, so it
# gets invoked as a module. It writes 22050 Hz mono 16 bit, which the ffmpeg
# inside liquidsoap reads as pcm_s16le and prepares without a murmur, so
# nothing here resamples it or makes it stereo. A 44100/stereo format object
# used to sit at this spot: it was working around an ACL problem that had been
# misdiagnosed as a codec one, and the real fix for that is the write-in-place
# dance further down, which is still here.
#
# Every render is a fresh process that loads the 60 MB model again - measured
# on this machine at about 1.7 seconds for a one-sentence file, nearly all of
# it startup. Announcements arrive one at a time and nothing is blocked waiting
# on the result, so that is not worth a resident server.

# --- the narrator's settings ------------------------------------------------
# Everything about the voice now lives in one json file, shared with radio.liq,
# so the /narrator page can later write both halves in a single PUT. radio.liq
# reads announce_every, hold and ident out of it and ignores the rest; this
# loop reads voice, speed, piper_root and say_as and ignores the rest.
#
# It is re-read on EVERY poll, so a change is on the air at the next
# announcement without stopping the scheduled task.
$cfgFile = 'C:\Users\an\src\radio\config\narrator.json'

# What each field falls back to. These are exactly the values that were
# hardcoded at this spot before the file existed, so a missing or malformed
# config leaves this loop behaving as it always did.
#
# piper_root is configurable because the install does not have to be on D: -
# somebody else running this station will put it somewhere else. Both the
# model and the interpreter hang off it.
$defRoot  = 'D:/services/piper'
$defVoice = 'en_GB-jenny_dioco-medium'

# Above 1.0 piper reads slower. Piper has no pitch control at all, so this is
# the only lever on delivery, and an unhurried read is most of what separates
# a station voice from a newsreader.
$defSpeed = '1.15'

# JSON numbers are written with a dot whatever the machine's locale is, so
# both the parse and the formatting back to a command line argument are
# pinned to the invariant culture. Without this a comma-decimal locale hands
# piper "1,15" and it dies on every announcement.
$inv = [Globalization.CultureInfo]::InvariantCulture

# Reads the file and hands back what to speak with. This NEVER throws: no
# file, a BOM, a truncated write caught mid-flight, a key of the wrong type -
# every one of those falls back field by field, so one bad value does not cost
# the others and the loop never stops speaking.
#
# say_as is a pronunciation table, and respelling is the only lever there is.
# Piper takes no phoneme markup - measured on this machine, [[ l aI v ]] did
# nothing whatsoever - and it has no pitch control either. Spelling does work:
# "liiive" measured 54% longer than "live", and "li-i-ive" 65% longer. So the
# fix for a name piper says wrong is to write it the way it should sound.
# Longest key first, so overlapping names cannot half-match.
function Get-NarratorConfig {
    $cfg = @{
        Python = "$defRoot/venv/Scripts/python.exe"
        Model  = "$defRoot/voices/$defVoice.onnx"
        Speed  = $defSpeed
        SayAs  = @()
    }
    try {
        $j = ConvertFrom-Json ([IO.File]::ReadAllText($cfgFile))

        $root  = if ("$($j.piper_root)".Trim()) { "$($j.piper_root)".Trim() } else { $defRoot }
        $voice = if ("$($j.voice)".Trim())      { "$($j.voice)".Trim() }      else { $defVoice }
        $cfg.Python = "$root/venv/Scripts/python.exe"
        $cfg.Model  = "$root/voices/$voice.onnx"

        if ($null -ne $j.speed) {
            $d = 0.0
            try { $d = [Convert]::ToDouble($j.speed, $inv) } catch { $d = 0.0 }
            if ($d -gt 0.0) { $cfg.Speed = $d.ToString($inv) }
        }

        if ($j.say_as) {
            $pairs = New-Object System.Collections.ArrayList
            foreach ($p in $j.say_as.PSObject.Properties) {
                [void]$pairs.Add([pscustomobject]@{ From = $p.Name; To = "$($p.Value)" })
            }
            $cfg.SayAs = @($pairs | Sort-Object { $_.From.Length } -Descending)
        }
    }
    catch { }
    $cfg
}

# What the text for piper gets written as. No BOM: piper opens its input as
# plain UTF-8, and a byte order mark would survive that as a U+FEFF glued to
# the front of the first line rather than being stripped off.
$utf8 = New-Object System.Text.UTF8Encoding($false)

# size+mtime of every text file as of the previous poll. A file has to look
# identical two polls running before we touch it, because the operator may
# still be typing into it and a script writing one is not atomic either. Three
# seconds of silence is the whole test - crude, but a text announcement is not
# arriving in slices the way an uploaded recording does.
$prev = @{}

while ($true) {
    # Once per poll, not once per file: a config saved while this loop is
    # sleeping is in force by the time the next text file is spoken.
    # Bound to plain names because the piper call below is parsed in argument
    # mode, where a bare $cfg.Model is asking for trouble.
    $cfg    = Get-NarratorConfig
    $python = $cfg.Python
    $model  = $cfg.Model
    $speed  = $cfg.Speed

    $now = @{}
    foreach ($f in Get-ChildItem $voice -Recurse -File -Include '*.txt', '*.md' -ErrorAction SilentlyContinue) {
        $stamp = "$($f.Length):$($f.LastWriteTimeUtc.Ticks)"
        $now[$f.FullName] = $stamp
        if ($prev[$f.FullName] -ne $stamp) { continue }   # still being written

        # ReadAllText sniffs the byte order mark and drops it, and falls back to
        # UTF-8 when there is none - so a file saved by Notepad and one written
        # by [IO.File]::WriteAllText both come out as the same string, with no
        # stray U+FEFF at the front for the synthesiser to trip over.
        $text = [IO.File]::ReadAllText($f.FullName)
        if (-not $text.Trim()) {
            # Nothing to say. Binning it keeps the folder clean and stops the
            # loop looking at it forever.
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        # Respell whatever piper gets wrong. Plain literal replacement, case
        # sensitive - String.Replace is ordinal - and longest key first, so
        # "Hector Lavoe" wins over a "Lavoe" that might also be in the table.
        # This changes only what is SPOKEN: the same words already went to the
        # site as written, so the page still shows the real name.
        foreach ($r in $cfg.SayAs) { $text = $text.Replace($r.From, $r.To) }

        # Two traps, and they have to be solved together.
        #
        # Synthesise IN THIS FOLDER, never in TEMP and then move. A file created
        # inside the folder inherits the folder's ACL; a file moved in from
        # somewhere else carries its own and svc-radio gets a bare "Permission
        # denied" - which liquidsoap reports as a successful queue followed by
        # "Available decoders cannot decode", so it reads like a codec problem
        # and is not one.
        #
        # And the pickup polls four times a second, while speech takes seconds
        # to render, so a file called .wav from the first byte gets grabbed
        # half-written. Write to a .pending name - the pickup filters on the
        # extension and ignores anything that is not an audio one - then rename.
        # A rename inside one directory is atomic and keeps the inherited ACL,
        # so the file is complete and readable the instant it is visible.
        $wav     = Join-Path $f.DirectoryName ("$($f.BaseName)-{0}.wav" -f (Get-Date -Format 'HHmmss'))
        $pending = "$wav.pending"

        # Hand piper the words in a file rather than down a pipe. That is
        # deliberate at both ends. Piper opens an --input-file as UTF-8
        # outright, while its stdin path decodes with the process code page, so
        # a curly apostrophe pasted out of a phone would arrive as mojibake.
        # And PowerShell 5.1 encodes whatever it pipes into a native process
        # using $OutputEncoding, which is ASCII until something changes it,
        # turning that same character into a question mark before python ever
        # sees it. A file written as UTF-8 is exactly what piper assumes.
        #
        # It goes beside the wav rather than in TEMP, for the ACL reason above
        # and so that one place holds everything this render made. The pickup
        # only looks at a whitelist of audio extensions, so a .piper-in in the
        # folder is invisible to it.
        $intext = "$wav.piper-in"
        try {
            [IO.File]::WriteAllText($intext, $text, $utf8)
            & $python -m piper --model $model --length-scale $speed --input-file $intext --output-file $pending

            # Piper is a separate process, so a failure is an exit code and a
            # missing or truncated wav, not an exception. Nothing is thrown and
            # the catch below would sit there and never fire, which would leave
            # the text to come round again every three seconds forever. Raise it
            # by hand. A voice model that cannot be loaded exits 1 before the
            # wav is opened at all; a synthesis that dies partway leaves a wav
            # on disk, and the exit code is the only thing that catches that.
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $pending)) {
                throw "piper exited $LASTEXITCODE"
            }

            Rename-Item $pending (Split-Path $wav -Leaf)
            Remove-Item $f.FullName -Force
        }
        catch {
            # Leave evidence and stop retrying: a text file we cannot speak would
            # otherwise come round again every three seconds forever. ".failed"
            # is not an audio extension, so the pickup ignores it too.
            Remove-Item $pending -Force -ErrorAction SilentlyContinue
            Rename-Item $f.FullName "$($f.Name).failed" -Force -ErrorAction SilentlyContinue
        }
        finally {
            # Both ways out leave the words sitting in an on-air folder, so this
            # runs on both.
            Remove-Item $intext -Force -ErrorAction SilentlyContinue
        }
    }
    $prev = $now

    Start-Sleep -Seconds 3
}
