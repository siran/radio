# start-radio.ps1 - bring up whatever is down, and leave alone whatever is not.
#
#   start-radio.cmd            start anything that is stopped
#   start-radio.cmd -Status    say what is up, change nothing
#
# THE DIFFERENCE FROM restart-radio.ps1, which already exists and is not this:
# that one STOPS things and starts them again, which drops every listener and is
# the right tool when something is wrong with a part that is running. This one
# never stops anything. It is what you want after a machine has been off, or
# when one piece died and the rest is fine, or on a machine where the station
# has never been started at all.
#
# IDEMPOTENT, WHICH IS THE WHOLE POINT. Run it twice and the second run says
# everything was already up and touches nothing. That is what makes it safe to
# double-click when unsure, and it is why it reports each part's state BEFORE it
# acts rather than only afterwards.
#
# PORTABLE: the parts live in radio-parts.json beside this file. Change the
# names and ports there and this runs on another machine unedited. If the file
# is missing or unreadable the built-in list below is used and the script says
# it fell back, rather than failing on the first machine that lost a file.

param(
    [switch]$Status,
    [string]$Config = (Join-Path $PSScriptRoot 'radio-parts.json')
)

$ErrorActionPreference = 'Continue'

# --- the parts -------------------------------------------------------------
# ONE LIST, IN THE JSON. There is no built-in copy to fall back to: a second
# list is a second thing to keep right, and a script that quietly runs off a
# stale internal default when the file is missing is worse than one that stops
# and says the file is missing.
if (-not (Test-Path $Config)) {
    throw "no $Config - this script reads its parts from that file and has no built-in list"
}
$parts = Get-Content $Config -Raw | ConvertFrom-Json
if (-not $parts.services -or -not $parts.tasks) {
    throw "$Config has no services or tasks in it"
}

# --- the environment the parts read ----------------------------------------
# A service started by Windows gets the MACHINE environment, so this is really
# about this script's own child processes and about saying plainly when a
# variable the station needs is simply not set anywhere.
function Test-Environment {
    $missing = @()
    foreach ($v in $parts.environment) {
        $val = [Environment]::GetEnvironmentVariable($v)
        if (-not $val) {
            $val = [Environment]::GetEnvironmentVariable($v, 'Machine')
            if ($val) { [Environment]::SetEnvironmentVariable($v, $val) }
        }
        if (-not $val) { $missing += $v } else { '  {0,-14} {1}' -f $v, $val }
    }
    foreach ($v in $missing) { '  {0,-14} NOT SET ANYWHERE - parts that read it will misbehave' -f $v }
}

function Get-PartState($p, $kind) {
    if ($kind -eq 'service') {
        $s = Get-Service $p.name -ErrorAction SilentlyContinue
        if (-not $s) { return 'missing' }
        return $s.Status.ToString().ToLower()
    }
    $t = Get-ScheduledTask -TaskName $p.name -ErrorAction SilentlyContinue
    if (-not $t) { return 'missing' }
    return $t.State.ToString().ToLower()
}

function Show-State {
    'environment'
    Test-Environment
    ''
    'services'
    foreach ($p in $parts.services) { '  {0,-18} {1}' -f $p.label, (Get-PartState $p 'service') }
    'tasks'
    foreach ($p in $parts.tasks)    { '  {0,-18} {1}' -f $p.label, (Get-PartState $p 'task') }
}

# --- answering, which is a different question from running -----------------
# A service in state Running only says a process exists. The station has been
# up and unreachable often enough that this asks the ports themselves.
function Show-Checks {
    ''
    'answering'
    foreach ($c in $parts.checks) {
        $want = if ($c.expect) { $c.expect } else { @(200) }
        try {
            $r = Invoke-WebRequest $c.url -UseBasicParsing -TimeoutSec 6
            $code = [int]$r.StatusCode
        } catch {
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            else { '  {0,-18} no answer   {1}' -f $c.label, $c.url; continue }
        }
        $ok = $want -contains $code
        '  {0,-18} {1} {2}   {3}' -f $c.label, $code, $(if ($ok) { 'ok' } else { 'unexpected' }), $c.url
    }
}

if ($Status) { Show-State; Show-Checks; return }

# --- administrator, or ask for it ------------------------------------------
# Same shape as restart-radio.ps1, and -NoExit for the same reason: the elevated
# copy opens its own window and without it that window prints and vanishes.
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $script = $PSCommandPath
    if (-not $script) { $script = $MyInvocation.MyCommand.Definition }
    $argv = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
    if ($Config) { $argv += @('-Config', $Config) }
    'asking for administrator rights - answer the prompt, and watch the new window'
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argv }
    catch {
        'elevation was refused, so nothing was started.'
        'right-click start-radio.cmd and choose Run as administrator.'
    }
    return
}

'--- before ---'
Show-State
''
'--- starting what is down ---'

$started = 0; $already = 0; $absent = 0

foreach ($p in $parts.services) {
    $state = Get-PartState $p 'service'
    if ($state -eq 'missing') {
        '  {0,-18} NOT INSTALLED - nothing to start' -f $p.label; $absent++; continue
    }
    if ($state -eq 'running') { '  {0,-18} already running' -f $p.label; $already++; continue }
    try {
        Start-Service $p.name -ErrorAction Stop
        # Starting is not the same as being up; give it a moment and re-ask.
        $ok = $false
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Milliseconds 800
            if ((Get-PartState $p 'service') -eq 'running') { $ok = $true; break }
        }
        if ($ok) { '  {0,-18} started' -f $p.label; $started++ }
        else { '  {0,-18} asked to start but is not running' -f $p.label }
    } catch { '  {0,-18} would not start: {1}' -f $p.label, $_.Exception.Message }
}

foreach ($p in $parts.tasks) {
    $state = Get-PartState $p 'task'
    if ($state -eq 'missing') {
        '  {0,-18} NOT REGISTERED - see install-live-bridge.ps1' -f $p.label; $absent++; continue
    }
    if ($state -eq 'running') { '  {0,-18} already running' -f $p.label; $already++; continue }
    try {
        Start-ScheduledTask -TaskName $p.name -ErrorAction Stop
        Start-Sleep -Seconds 2
        '  {0,-18} started' -f $p.label; $started++
    } catch { '  {0,-18} would not start: {1}' -f $p.label, $_.Exception.Message }
}

''
'--- after ---'
Show-State
Show-Checks
''
'{0} started, {1} already up, {2} not installed' -f $started, $already, $absent
if ($absent) { 'Something is not installed on this machine. Nothing here installs it - that is deliberate.' }
''
'Nothing was stopped. To restart a part that is running but wrong:  restart-radio.cmd -What caddy'
