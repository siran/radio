# Watches for admin requests and carries them out.
#
# Nothing web-facing runs here: the page writes a json file, this loop notices
# it within a few seconds, does the work, and writes a result file back. Same
# shape as the voice notes - a file appears, a watcher acts - which is why
# there is still no application server anywhere in the request path.
#
# Runs from a scheduled task at startup. Safe to stop and start at any time.
$ErrorActionPreference = 'Continue'

$repo  = 'C:\Users\an\src\radio'
$req   = "$repo\messages\admin\req"
$res   = "$repo\messages\admin\res"
$snip  = "$repo\speakers.caddy"
$cf    = "$repo\Caddyfile"
$caddy = 'C:\Program Files\Caddy\caddy.exe'
$voice = "$repo\messages\voice"

function Write-Result($id, $obj) {
    # Set-Content -Encoding UTF8 writes a BOM, and JSON.parse in the browser
    # rejects it. Write the bytes ourselves.
    $json = $obj | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $res "$id.json"), $json,
                            (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Speakers {
    Get-Content $snip -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\s+(\S+)\s+\$2' } |
        ForEach-Object { ($_ -split '\s+', 3)[1] }
}

function Reload-Caddy {
    # The Caddyfile reads the ACME contact from an environment variable, and a
    # process only ever sees the machine environment as it stood when IT
    # started. This loop is launched at boot and can outlive any number of
    # changes, so read the value fresh instead of trusting what we inherited.
    # Without it `caddy validate` fails on an unresolved placeholder and every
    # speaker created here is written to the file and then never loaded - which
    # is exactly what happened: "caddy rejected the new config", and a new host
    # with no password shown.
    if (-not $env:ACME_EMAIL) {
        $env:ACME_EMAIL = [Environment]::GetEnvironmentVariable('ACME_EMAIL', 'Machine')
    }
    & $caddy validate --config $cf *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
    & $caddy reload --config $cf *> $null
    return ($LASTEXITCODE -eq 0)
}

function Add-Speaker($name, $password) {
    $clean = ($name -replace '[^a-zA-Z0-9]', '').ToLower()
    if (-not $clean) { return @{ ok = $false; error = 'name needs letters or digits' } }
    if ($clean -in @('voice', 'admin', 'djadmin')) { return @{ ok = $false; error = 'reserved name' } }

    if (-not $password) {
        $alpha = ('abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789').ToCharArray()
        $b = New-Object byte[] 10
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
        $password = -join ($b | ForEach-Object { $alpha[$_ % $alpha.Length] })
    }
    $hash = & $caddy hash-password --plaintext $password
    if (-not $hash) { return @{ ok = $false; error = 'hashing failed' } }

    $lines = Get-Content $snip | Where-Object { $_ -notmatch "^\s+$clean\s+\`$2" }
    $idx = ($lines | Select-String -Pattern '^\s*\}' | Select-Object -First 1).LineNumber - 1
    $out = $lines[0..($idx - 1)] + "`t`t$clean $hash" + $lines[$idx..($lines.Count - 1)]
    Set-Content -Path $snip -Value $out -Encoding ASCII

    New-Item -ItemType Directory -Force -Path (Join-Path $voice $clean) | Out-Null
    & icacls (Join-Path $voice $clean) /grant 'svc-radio:(OI)(CI)M' /Q *> $null

    if (-not (Reload-Caddy)) { return @{ ok = $false; error = 'caddy rejected the new config' } }
    return @{ ok = $true; name = $clean; password = $password }
}

function Remove-Speaker($name) {
    $clean = ($name -replace '[^a-zA-Z0-9]', '').ToLower()
    $lines = Get-Content $snip
    $kept = $lines | Where-Object { $_ -notmatch "^\s+$clean\s+\`$2" }
    if ($kept.Count -eq $lines.Count) { return @{ ok = $false; error = "$clean is not a speaker" } }
    Set-Content -Path $snip -Value $kept -Encoding ASCII
    Remove-Item (Join-Path $voice $clean) -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Reload-Caddy)) { return @{ ok = $false; error = 'caddy rejected the new config' } }
    return @{ ok = $true; name = $clean }
}

# Restarting the station, asked for from a page.
#
# This is the one thing the console cannot do for itself: the console talks to
# liquidsoap, so when liquidsoap is the thing that is wedged, the button and the
# thing it must act on are the same casualty. This loop is reached through caddy
# instead, which does not depend on liquidsoap at all - so it still works when
# nothing else does, which is the only moment it matters.
#
# Rate limited hard. A stuck page, a double tap or a retry loop must not be able
# to restart the station repeatedly: every restart is ten to fifteen seconds of
# silence for every listener, and a loop of them is an outage rather than a fix.
$restartStamp = "$repo\messages\admin\.last-restart"
# Hosts ask here, and NOWHERE else. Writing into the admin request folder
# would hand every host the actions that folder accepts - minting and
# removing speakers - which is not what a restart button is for. This
# folder takes one action and the body cannot change it.
$rreq = "$repo\messages\restart\req"
$rres = "$repo\messages\restart\res"
# Off by default, and a number rather than a switch so it says what it means.
# config/limits.json: {"restart_min_seconds": 120} to turn it on. Absent,
# unreadable or 0 means no limit at all - which is the default, because this
# is a circle of trust and the button exists for the moment the station is
# already broken. Being told to wait two minutes while it is off the air is
# the wrong answer to the only emergency this button has.
# Read per request, not at startup, so changing it does not need a restart
# of the thing that performs restarts.
$limitsFile = "$repo\config\limits.json"

function Restart-Min-Seconds {
    try {
        if (-not (Test-Path $limitsFile)) { return 0 }
        $raw = Get-Content $limitsFile -Raw
        if (-not $raw -or -not $raw.Trim()) { return 0 }
        $v = (ConvertFrom-Json $raw).restart_min_seconds
        if ($null -eq $v) { return 0 }
        $n = [double]$v
        if ($n -gt 0) { return $n } else { return 0 }
    } catch { return 0 }
}

function Restart-Station($what, $who) {
    $ok = @('liquidsoap', 'icecast', 'all', 'watchers')
    $w  = if ($what -and ($what -in $ok)) { $what } else { 'liquidsoap' }

    $minS = Restart-Min-Seconds
    if ($minS -gt 0 -and (Test-Path $restartStamp)) {
        $since = ((Get-Date) - (Get-Item $restartStamp).LastWriteTime).TotalSeconds
        if ($since -lt $minS) {
            return @{ ok = $false
                      error = ("the station was restarted " + [int]$since +
                               "s ago - wait " + [int]($minS - $since) + "s") }
        }
    }
    [IO.File]::WriteAllText($restartStamp, (Get-Date).ToString('o'))

    # Said out loud in the log, because a station that goes quiet mid-show
    # should not leave anyone guessing why.
    $asked = if ($who) { $who } else { 'unknown' }
    Write-Output ("[{0}] restart '{1}' asked for by {2}" -f (Get-Date).ToString('HH:mm:ss'), $w, $asked)

    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repo\restart-radio.ps1" -What $w *> $null
        return @{ ok = $true; what = $w; by = $asked }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

while ($true) {
    foreach ($f in Get-ChildItem $req -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $id = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        try {
            $body = Get-Content $f.FullName -Raw | ConvertFrom-Json
            switch ($body.action) {
                'add'    { $r = Add-Speaker $body.name $body.password }
                'remove' { $r = Remove-Speaker $body.name }
                'list'    { $r = @{ ok = $true } }
                'restart' { $r = Restart-Station $body.what $body.who }
                default  { $r = @{ ok = $false; error = 'unknown action' } }
            }
        }
        catch { $r = @{ ok = $false; error = 'could not read the request' } }

        $r.speakers = @(Get-Speakers)
        Write-Result $id $r
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    }

    # The host-facing folder. Whatever the body says, the action is restart:
    # the folder decides, not the caller.
    foreach ($f in Get-ChildItem $rreq -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $id = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        try {
            $b = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $r = Restart-Station $b.what $b.who
        }
        catch { $r = @{ ok = $false; error = 'could not read the request' } }
        $json = $r | ConvertTo-Json -Compress
        [IO.File]::WriteAllText((Join-Path $rres "$id.json"), $json,
            (New-Object Text.UTF8Encoding($false)))
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    }

    Get-ChildItem $rres -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # results are short lived - they carry a password
    Get-ChildItem $res -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 3
}
