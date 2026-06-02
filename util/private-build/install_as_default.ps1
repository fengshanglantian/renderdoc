<#
.SYNOPSIS
  Make the patched RenderDoc the system default by overlaying it on
  C:\Program Files\RenderDoc.

.DESCRIPTION
  Steps it performs:
    1. backup the existing C:\Program Files\RenderDoc to a sibling
       .backup-<timestamp> dir (so you can roll back)
    2. delete C:\Program Files\RenderDoc
    3. copy the patched dist directory to C:\Program Files\RenderDoc
    4. report .rdc file association status

  After running, double-clicking a .rdc file (or anything that launches
  qrenderdoc.exe) uses the patched build.

  REQUIRES ADMIN: writing under C:\Program Files needs elevation.

.PARAMETER PatchedDir
  Folder produced by package_renderdoc_patched.ps1.

  Default behaviour: if this script lives next to qrenderdoc.exe (i.e. the
  receiver unzipped RenderDocPatched-source-debug.zip and is running the
  installer from inside it), use that folder. Otherwise fall back to the
  build location <repo>\dist\RenderDocPatched-source-debug-release used by
  package_renderdoc_patched.ps1 when run from a local checkout.

.PARAMETER InstallTo
  Target install dir. Default matches the official MSI install path so
  Start Menu shortcuts and file associations keep working.

.PARAMETER NoBackup
  Skip the backup step (only do this if you already have a backup).

.PARAMETER Restore
  Instead of installing, restore the most recent backup found in
  $InstallTo's parent. Useful if something breaks.
#>
param(
    [string]$PatchedDir,
    [string]$InstallTo  = "C:\Program Files\RenderDoc",
    [switch]$NoBackup,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

if (-not $PatchedDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (Test-Path -LiteralPath (Join-Path $scriptDir 'qrenderdoc.exe')) {
        # Running from inside an unzipped package directory.
        $PatchedDir = $scriptDir
    } else {
        # Running from a fresh repo checkout (util\private-build\): look
        # for the most recent package under <repo>\dist\ (Release preferred).
        $repoRoot = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
        $distRoot = Join-Path $repoRoot 'dist'
        $cand     = Join-Path $distRoot 'RenderDocPatched-source-debug-release'
        if (-not (Test-Path -LiteralPath (Join-Path $cand 'qrenderdoc.exe'))) {
            $cand = Join-Path $distRoot 'RenderDocPatched-source-debug'
        }
        $PatchedDir = $cand
    }
    Write-Host "[init] PatchedDir resolved to: $PatchedDir" -ForegroundColor DarkGray
}

# Self-elevate if not admin.
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
if (-not $isAdmin) {
    Write-Host "Not admin -> relaunching elevated..." -ForegroundColor Yellow
    $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path,
               '-PatchedDir', $PatchedDir, '-InstallTo', $InstallTo)
    if ($NoBackup) { $args2 += '-NoBackup' }
    if ($Restore)  { $args2 += '-Restore' }
    Start-Process -FilePath 'powershell' -Verb RunAs -ArgumentList $args2 -Wait
    exit
}

$parent = Split-Path -Parent $InstallTo

if ($Restore) {
    $backup = Get-ChildItem -LiteralPath $parent -Directory -Filter "RenderDoc.backup-*" -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $backup) { throw "No backup found under $parent\RenderDoc.backup-*" }
    Write-Host "[restore] using backup: $($backup.FullName)" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $InstallTo) { Remove-Item -LiteralPath $InstallTo -Recurse -Force }
    Move-Item -LiteralPath $backup.FullName -Destination $InstallTo
    Write-Host "[restore] done. $InstallTo restored." -ForegroundColor Green
    exit
}

# --- preflight ----------------------------------------------------------
if (-not (Test-Path -LiteralPath "$PatchedDir\qrenderdoc.exe")) {
    throw "Patched dir invalid (no qrenderdoc.exe): $PatchedDir"
}

# --- backup -------------------------------------------------------------
$dirIsEmpty = $false
if (Test-Path -LiteralPath $InstallTo) {
    $dirIsEmpty = -not (Get-ChildItem -LiteralPath $InstallTo -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
}
if ((Test-Path -LiteralPath $InstallTo) -and $dirIsEmpty) {
    # Common case after a previously-aborted install: the dir exists but is
    # empty. No useful content to back up -- just remove it.
    Write-Host "[skip-backup] $InstallTo exists but is empty; removing without backup" -ForegroundColor DarkGray
    Remove-Item -LiteralPath $InstallTo -Recurse -Force
} elseif ((Test-Path -LiteralPath $InstallTo) -and (-not $NoBackup)) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$InstallTo.backup-$stamp"
    Write-Host "[backup] $InstallTo -> $backup" -ForegroundColor Cyan
    Move-Item -LiteralPath $InstallTo -Destination $backup
} elseif (Test-Path -LiteralPath $InstallTo) {
    Write-Host "[remove] $InstallTo (no backup)" -ForegroundColor Yellow
    Remove-Item -LiteralPath $InstallTo -Recurse -Force
}

# --- copy ---------------------------------------------------------------
Write-Host "[copy]   $PatchedDir -> $InstallTo" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $InstallTo | Out-Null
# Use -Path (not -LiteralPath) so the trailing * expands; Copy-Item with
# -LiteralPath treats `*` literally and copies nothing.
Copy-Item -Path "$PatchedDir\*" -Destination $InstallTo -Recurse -Force

# --- verify -------------------------------------------------------------
& "$InstallTo\renderdoccmd.exe" version
$ver = & "$InstallTo\renderdoccmd.exe" version 2>&1
Write-Host "`n[verify] $ver" -ForegroundColor Green
# Just sanity-check that we got a renderdoccmd version line (commit-hash content
# changes every rebuild so don't pin a literal).
if ($ver -notmatch 'renderdoccmd .* built from [0-9a-f]{40}') {
    Write-Warning "Unexpected version output. Did you copy the right dir?"
}

# --- report file association status ------------------------------------
$rdcAssoc = (cmd /c assoc .rdc 2>$null)
$ftype    = if ($rdcAssoc -match '=(.+)$') { (cmd /c ftype $matches[1] 2>$null) } else { '<none>' }
Write-Host "`n[.rdc association]" -ForegroundColor Cyan
Write-Host "  $rdcAssoc"
Write-Host "  $ftype"
Write-Host "`nDone. To roll back run:`n  powershell -File $($MyInvocation.MyCommand.Path) -Restore" -ForegroundColor Green
