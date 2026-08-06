# Restart the radio.
#
#   restart-radio.cmd              everything, in the order that works
#   restart-radio.cmd -What liquidsoap
#   restart-radio.cmd -Status      look, change nothing
#
# Double-clicking restart-radio.cmd works too. Either way this asks Windows for
# administrator rights itself if it does not already have them, because
# Restart-Service needs them and the failure without them is a wall of red that
# does not say "you are not an administrator".
#
# Order matters. Icecast is the transmitter: restart it and liquidsoap's
# connection drops, so liquidsoap goes after it. Caddy is only the front door -
# it can go any time, but restarting it disconnects every listener, so it is
# never part of -What all and has to be asked for by name.
param(
    [ValidateSet('all', 'icecast', 'liquidsoap', 'caddy', 'watchers')]
    [string]$What = 'all',
    [switch]$Status
)
$ErrorActionPreference = 'Continue'

$services = @{
    icecast    = 'IcecastServer'
    liquidsoap = 'LiquidsoapRadio'
    caddy      = 'CaddyServer'
}
$tasks = @('RadioNarratorWatcher', 'RadioAdminWatcher')

function Show-State {
    'services'
    foreach ($k in 'icecast', 'liquidsoap', 'caddy') {
        $s = Get-Service $services[$k] -ErrorAction SilentlyContinue
        '  {0,-12} {1,-10} {2}' -f $k, $(if ($s) { $s.Status } else { 'MISSING' }), $services[$k]
    }
    'watchers'
    foreach ($t in $tasks) {
        $x = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        '  {0,-24} {1}' -f $t, $(if ($x) { $x.State } else { 'not registered' })
    }
    'on air'
    try {
        $j = (Invoke-WebRequest 'http://127.0.0.1:8000/status-json.xsl' -UseBasicParsing -TimeoutSec 8).Content | ConvertFrom-Json
        $src = $j.icestats.source; if ($src -isnot [array]) { $src = @($src) }
        foreach ($s in $src) { '  [{0}]  listeners {1}' -f $s.title, $s.listeners }
    } catch { '  icecast is not answering' }
    'the console API'
    foreach ($u in '/control/now', '/interactive') {
        try {
            $r = Invoke-WebRequest ('http://127.0.0.1:8005' + $u) -UseBasicParsing -TimeoutSec 8
            '  {0,-16} {1}' -f $u, [int]$r.StatusCode
        } catch [Net.WebException] {
            $c = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'no answer' }
            '  {0,-16} {1}   <- 404 here means the source harbor won port 8005; restart liquidsoap' -f $u, $c
        }
    }
    'narrator'
    $failed = @(Get-ChildItem 'C:\Users\an\src\radio\messages\voice\announcer' -Filter *.failed -ErrorAction SilentlyContinue)
    if ($failed.Count) {
        '  {0} announcements piper could not render. Newest {1}.' -f $failed.Count,
            ($failed | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime
        '  Each .failed file holds the line it could not say; a .err beside it says why.'
    } else {
        '  nothing failed to render'
    }
}

if ($Status) { Show-State; return }

# --- administrator, or ask for it ------------------------------------------
# -NoExit on the elevated copy on purpose: it opens a second window, and
# without it that window prints everything and vanishes before it can be read.
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $script = $PSCommandPath
    if (-not $script) { $script = $MyInvocation.MyCommand.Definition }
    $argv = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
    if ($What)   { $argv += @('-What', $What) }
    Write-Output 'asking for administrator rights - answer the prompt, and watch the new window'
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argv
    } catch {
        Write-Output 'elevation was refused, so nothing was restarted.'
        Write-Output 'right-click restart-radio.cmd and choose Run as administrator.'
    }
    return
}

# Liquidsoap caches the compiled script. If radio.liq was edited and this is not
# cleared, the process comes back running the OLD program while the file on disk
# says otherwise - which has cost hours before now.
if ($What -in 'all', 'liquidsoap') {
    Get-ChildItem 'D:\Liquidsoap\cache' -Recurse -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    'cleared the liquidsoap script cache'
}

$order = switch ($What) {
    'all'        { 'icecast', 'liquidsoap' }   # caddy deliberately not included
    'icecast'    { 'icecast', 'liquidsoap' }   # icecast alone would strand liquidsoap
    'liquidsoap' { , 'liquidsoap' }
    'caddy'      { , 'caddy' }
    'watchers'   { @() }
}

foreach ($k in $order) {
    $n = $services[$k]
    "restarting $n"
    Restart-Service $n -ErrorAction Continue
    Start-Sleep -Seconds $(if ($k -eq 'liquidsoap') { 14 } else { 4 })
    '  {0}' -f (Get-Service $n).Status
}

if ($What -in 'all', 'watchers') {
    foreach ($t in $tasks) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            "restarting $t"
            Stop-ScheduledTask  -TaskName $t -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Start-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        }
    }
}

''
Show-State
''
'If the console API is 404 above, liquidsoap is up but the source harbor took'
'port 8005 instead of the HTTP handlers. Restart liquidsoap alone and it will'
'usually take it back:   restart-radio.cmd -What liquidsoap'
