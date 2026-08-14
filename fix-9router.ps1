<#
  fix-9router.ps1 - Patch 9Router's compiled OpenCode Free executor to send the
  x-opencode-session / x-opencode-project / x-opencode-request headers and CLI
  User-Agent that the real opencode client sends. Without them, requests hit a
  shared anonymous quota and fail with "Free usage exceeded" after a couple calls.

  Run:  powershell -ExecutionPolicy Bypass -File fix-9router.ps1
  (then restart 9Router - the patch is loaded at startup)

  Safe: backs up the chunk to <file>.bak, patches by pattern (version-tolerant),
  validates syntax after patching, and skips if already patched.
#>

$ErrorActionPreference = "Stop"

function Get-9RouterInstall {
    try {
        $root = (npm root -g 2>$null | Select-Object -First 1).Trim()
    } catch { $root = "" }
    $candidates = @()
    if ($root) { $candidates += (Join-Path $root "9router") }
    # Fallbacks for common layouts
    $candidates += (Join-Path $env:APPDATA "npm\node_modules\9router")
    $candidates += (Join-Path $env:USERPROFILE ".npm-global\lib\node_modules\9router")
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Find-ExecutorChunk($base) {
    $serverDirs = @(
        (Join-Path $base "app\.next-cli-build\server\chunks"),
        (Join-Path $base "app\.next\server\chunks"),
        (Join-Path $base "app\.next-cli-build\server")
    )
    foreach ($dir in $serverDirs) {
        if (-not (Test-Path $dir)) { continue }
        $hit = Get-ChildItem $dir -Recurse -File -Filter "*.js" -ErrorAction SilentlyContinue |
            Select-String -Pattern 'Authorization:"Bearer public"' -List -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty Path
        if ($hit) { return $hit }
    }
    return $null
}

$install = Get-9RouterInstall
if (-not $install) {
    Write-Host "ERROR: 9Router install not found. Is it installed via npm (npm i -g 9router)?"
    exit 1
}
Write-Host "9Router install: $install"

$chunk = Find-ExecutorChunk $install
if (-not $chunk) {
    Write-Host "ERROR: opencode executor chunk not found under $install\app\.next-cli-build"
    exit 1
}
Write-Host "Found chunk: $chunk"

$content = Get-Content $chunk -Raw

if ($content -match '"x-opencode-session"') {
    Write-Host "Already patched - nothing to do."
    exit 0
}

$pattern = '(buildHeaders\(\)\{)(return\{"Content-Type":"application/json",Authorization:"Bearer public","x-opencode-client":"desktop",)(Accept:)([^}]*)(\}\})'
if (-not $content -match $pattern) {
    Write-Host "ERROR: buildHeaders signature not found in this version. No changes made."
    exit 1
}

$replacement = ('$1var _s=this._sid||(this._sid="ses_"+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2)),_p=this._pid||(this._pid="p_"+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2));' +
    '$2"x-opencode-session":_s,"x-opencode-project":_p,"x-opencode-request":_s+":"+Date.now()+":"+Math.random().toString(36).slice(2),"User-Agent":"opencode/1.17.0",$3$4$5')

$backup = "$chunk.bak"
Copy-Item $chunk $backup -Force
Write-Host "Backup: $backup"

$new = $content -replace $pattern, $replacement
if ($new -eq $content) {
    Write-Host "ERROR: replacement produced no change. No changes made."
    exit 1
}

Set-Content $chunk $new -NoNewline -Encoding utf8

# Validate syntax with the same Node that runs 9Router
try {
    node --check $chunk
    if ($LASTEXITCODE -ne 0) { throw "node --check failed" }
    Write-Host "Syntax check: OK"
} catch {
    Copy-Item $backup $chunk -Force
    Write-Host "ERROR: syntax check failed - restored backup. $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Host "PATCHED. Restart 9Router (or reboot the tray app) for it to take effect."
Write-Host "Note: 'npm i -g 9router@latest' will overwrite this fix - re-run the script after updating."