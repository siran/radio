# Registers the live bridge as a scheduled task, so a browser can be a source.
#
#   install-live-bridge.ps1              register (or re-register) and start it
#   install-live-bridge.ps1 -Remove      take it away again
#
# Needs administrator rights, because the task runs as SYSTEM.
#
# Why a task and not a service: the two watchers are already tasks, this is the
# same shape of thing - a long-lived process with no installer of its own - and
# a task can be told to restart itself 999 times without nssm or a wrapper.
# Why SYSTEM: nobody has to be logged in for the console to work.
#
# NODE IS PINNED HERE, at the full path found on THIS machine when this runs.
# A task inherits SYSTEM's environment, not a user's, so anything reached
# through a per-user shim - the way ffmpeg is installed here, under
# AppData\Local\Microsoft\WinGet\Links - simply does not resolve and the
# failure is a task that "ran" and exited instantly. The bridge itself needs no
# ffmpeg at all: it moves bytes and decodes nothing.

param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$TASK = 'RadioLiveBridge'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an administrator PowerShell - registering a SYSTEM task needs it.'
}

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TASK -Confirm:$false
        "removed $TASK"
    } else { "$TASK was not registered" }
    return
}

# A service reads the machine environment, not this session's, so this is the
# machine copy on purpose - the same read restart-radio.ps1 makes.
$home_ = [Environment]::GetEnvironmentVariable('RADIO_HOME', 'Machine')
if (-not $home_) { throw 'RADIO_HOME is not a machine environment variable' }
$script = Join-Path $home_ 'live-bridge.js'
if (-not (Test-Path -LiteralPath $script)) { throw "not found: $script" }

$node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if (-not $node) { throw 'node.exe is not on the PATH of the session running this' }
if ($node -like "$env:LOCALAPPDATA*") {
    throw "node.exe resolves to a per-user path ($node). SYSTEM cannot see it; install node machine-wide."
}
"node:   $node"
"script: $script"

$action = New-ScheduledTaskAction -Execute $node -Argument ('"' + $script + '"')
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
# The same settings the other two watchers carry: never time out, never give
# up, and never start a second copy - two bridges would fight for one mount.
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -DontStopOnIdleEnd

if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TASK -Confirm:$false
}
Register-ScheduledTask -TaskName $TASK -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $TASK
Start-Sleep -Seconds 2

$t = Get-ScheduledTask -TaskName $TASK
"state:  $($t.State)"
try {
    $r = Invoke-WebRequest 'http://127.0.0.1:8007/host/onair' -UseBasicParsing -TimeoutSec 5
    "answer: $($r.Content)"
} catch {
    'the bridge is not answering on 127.0.0.1:8007 yet - look in $env:RADIO_LIQ\log\live-bridge.log'
}
