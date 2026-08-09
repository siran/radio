# Add a speaker to the radio.
#
#   .\mint-speaker.ps1 -Name maria
#   .\mint-speaker.ps1 -Name maria -Password "theirs"   (they chose one)
#   .\mint-speaker.ps1 -Name maria -Remove
#
# The name becomes their folder under messages/voice, which becomes their lane.
# Caddy puts their uploads there based on who they logged in as, so a speaker
# cannot post as anyone else.
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Password,
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'

# Paths come from the machine environment so this can move without editing
# code. A process only sees that environment as it stood when it STARTED, so a
# shell, an explorer session or a scheduled task older than the variables does
# not have them - read the machine scope directly in that case rather than
# refusing to run. admin-watcher.ps1 already learned this for ACME_EMAIL; it is
# the same lesson and it bit again the first time somebody double-clicked the
# restart wrapper. A recovery script that will not start because your shell is
# old is not a recovery script.
foreach ($v in 'RADIO_HOME', 'RADIO_CADDY') {
    if (-not [Environment]::GetEnvironmentVariable($v)) {
        $m = [Environment]::GetEnvironmentVariable($v, 'Machine')
        if ($m) { [Environment]::SetEnvironmentVariable($v, $m) }
    }
    if (-not [Environment]::GetEnvironmentVariable($v)) { throw "$v is not set" }
}

$snip  = Join-Path $env:RADIO_HOME 'speakers.caddy'
$cf    = Join-Path $env:RADIO_HOME 'Caddyfile'
$caddy = Join-Path $env:RADIO_CADDY 'caddy.exe'
$voice = Join-Path $env:RADIO_HOME 'messages\voice'

$clean = ($Name -replace '[^a-zA-Z0-9]', '').ToLower()
if (-not $clean) { throw 'name must contain letters or digits' }
if ($clean -eq 'voice') { throw 'that name is reserved' }

$lines = Get-Content $snip

if ($Remove) {
    $kept = $lines | Where-Object { $_ -notmatch "^\s*$clean\s+\`$2[aby]\`$" }
    if ($kept.Count -eq $lines.Count) { Write-Output "$clean was not a speaker"; exit }
    Set-Content -Path $snip -Value $kept -Encoding ASCII
    Write-Output "removed $clean"
}
else {
    if ($lines -match "^\s*$clean\s+") { Write-Output "$clean already exists - re-minting" }
    if (-not $Password) {
        $alpha = ('abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789').ToCharArray()
        $b = New-Object byte[] 10
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
        $Password = -join ($b | ForEach-Object { $alpha[$_ % $alpha.Length] })
    }
    $ErrorActionPreference = 'Continue'
    $hash = & $caddy hash-password --plaintext $Password
    $ErrorActionPreference = 'Stop'
    if (-not $hash) { throw 'hashing failed' }

    $kept = $lines | Where-Object { $_ -notmatch "^\s*$clean\s+" }
    $out = @()
    foreach ($l in $kept) {
        if ($l -match '^\s*\}\s*$' -and -not $done) { }
        $out += $l
    }
    # insert before the closing brace of the basic_auth block
    $idx = ($out | Select-String -Pattern '^\s*\}' | Select-Object -First 1).LineNumber - 1
    $out = $out[0..($idx - 1)] + "`t`t$clean $hash" + $out[$idx..($out.Count - 1)]
    Set-Content -Path $snip -Value $out -Encoding ASCII

    New-Item -ItemType Directory -Force -Path (Join-Path $voice $clean) | Out-Null
    & icacls (Join-Path $voice $clean) /grant 'svc-radio:(OI)(CI)M' /Q | Out-Null

    # Land flat: unity gain and every band at zero. A new host configures for
    # their own equipment, so the station has no business guessing a curve for
    # them - but it should not leave them on whatever `voice_gain` happens to
    # be either. That knob is the fallback for a speaker with no file of their
    # own, it is shared, and it has been anywhere from 1.0 to 12.0 in a single
    # day; a host inheriting 12.0 arrives distorted and one inheriting 1.0
    # arrives inaudible, and in both cases they would reasonably conclude the
    # radio is broken rather than that they have a slider to move.
    #
    # Written with WriteAllText and a BOM-less encoder because liquidsoap reads
    # this file raw and a BOM is not JSON, and created IN the folder so it
    # inherits the ACL just granted rather than carrying one in.
    $seed = Join-Path (Join-Path $voice $clean) 'settings.json'
    if (-not (Test-Path $seed)) {
        $flat = '{"gain":1,"duck":true,"eq":{"f100":0,"f200":0,"f400":0,"f800":0,"f1600":0,"f3150":0,"f6300":0}}'
        [IO.File]::WriteAllText($seed, $flat, (New-Object Text.UTF8Encoding($false)))
    }
}

# caddy writes its progress to stderr, which powershell turns into a
# terminating error under ErrorActionPreference=Stop even on success. Drop to
# Continue around the native calls and judge them by their exit code.
$ErrorActionPreference = 'Continue'
& $caddy validate --config $cf | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'validate failed - speakers.caddy is bad, fix it before reloading' }
& $caddy reload --config $cf | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'reload failed' }
$ErrorActionPreference = 'Stop'

Write-Output ''
Write-Output '=== speakers now'
Get-Content $snip | Where-Object { $_ -match '^\s+\S+\s+\$2' } |
    ForEach-Object { Write-Output ('  ' + ($_ -split '\s+')[1]) }

if (-not $Remove) {
    Write-Output ''
    Write-Output '--- send them this ---------------------------------------'
    Write-Output ''
    Write-Output '  https://radio.wildnloyal.org/host/'
    Write-Output ''
    Write-Output ("  user      $clean")
    Write-Output ("  password  $Password")
    Write-Output ''
    Write-Output '  Click once to talk, once again to stop. The browser will'
    Write-Output '  ask for the password the first time and remember it.'
    Write-Output '----------------------------------------------------------'
}
