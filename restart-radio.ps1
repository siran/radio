# Restart the radio.
#
#   .\restart-radio.ps1              everything, in the order that works
#   .\restart-radio.ps1 -What liquidsoap
#   .\restart-radio.ps1 -Status      look, change nothing
#
# Order matters. Icecast is the transmitter: restart it and liquidsoap's
# connection drops, so liquidsoap goes after it. Caddy is only the front door -
# it can go any time, but restarting it disconnects every listener, so it goes
# last and only when asked for.
#
# Run it from an elevated PowerShell on dolly. Nothing here needs the network.
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
}

if ($Status) { Show-State; return }

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
'usually take it back:   .\restart-radio.ps1 -What liquidsoap'
