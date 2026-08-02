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

while ($true) {
    foreach ($f in Get-ChildItem $req -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $id = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        try {
            $body = Get-Content $f.FullName -Raw | ConvertFrom-Json
            switch ($body.action) {
                'add'    { $r = Add-Speaker $body.name $body.password }
                'remove' { $r = Remove-Speaker $body.name }
                'list'   { $r = @{ ok = $true } }
                default  { $r = @{ ok = $false; error = 'unknown action' } }
            }
        }
        catch { $r = @{ ok = $false; error = 'could not read the request' } }

        $r.speakers = @(Get-Speakers)
        Write-Result $id $r
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    }

    # results are short lived - they carry a password
    Get-ChildItem $res -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 3
}
