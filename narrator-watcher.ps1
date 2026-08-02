# Reads plain text files aloud on the air.
#
# Drop a .txt or .md into any speaker folder under messages\voice and this loop
# speaks it with Windows SAPI, leaving a .wav behind in the same folder. The
# voice-note pickup already running inside liquidsoap finds that wav and plays
# it exactly like a phone recording - same lane, same settings.json, same
# ducking. Liquidsoap never learns that text is a thing; the only new idea in
# the station is "a file appears, a watcher acts", which is the shape the admin
# watcher and the voice notes already have.
#
# Runs from a scheduled task at startup. Safe to stop and start at any time.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Speech

$voice = 'C:\Users\an\src\radio\messages\voice'

# 44100 / 16 bit / stereo, which comes out as pcm_s16le. Measured on this
# machine: that is the one SAPI format ffmpeg inside liquidsoap accepts without
# complaint. The default (22kHz mono) is what "Available decoders cannot decode"
# looks like from the other end.
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(
           44100,
           [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
           [System.Speech.AudioFormat.AudioChannel]::Stereo)

# size+mtime of every text file as of the previous poll. A file has to look
# identical two polls running before we touch it, because the operator may
# still be typing into it and a script writing one is not atomic either. Three
# seconds of silence is the whole test - crude, but a text announcement is not
# arriving in slices the way an uploaded recording does.
$prev = @{}

while ($true) {
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
        try {
            $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
            $s.SetOutputToWaveFile($pending, $fmt)
            $s.Speak($text)
            # The RIFF header carries the length, and it is only filled in when
            # the output is released. Skip this and the wav is unplayable.
            $s.SetOutputToNull()
            $s.Dispose()
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
    }
    $prev = $now

    Start-Sleep -Seconds 3
}
