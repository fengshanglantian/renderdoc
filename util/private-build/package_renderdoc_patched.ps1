<#
.SYNOPSIS
  Package the patched RenderDoc into a self-contained, redistributable
  directory layout that mirrors the official RD MSI install.

.DESCRIPTION
  Combines:
    - patched binaries from <repo>\x64\<BuildConfig>                  (rebuilt)
    - patched APK     from <repo>\build-android[-release]\bin         (rebuilt)
    - auxiliary files from C:\Program Files\RenderDoc                 (vendored
      from official v1.44 install: plugins/, PySide2, libssl/crypto,
      renderdoc.chm, LICENSE, x86 sub-arch shim, etc. — these are not
      affected by our source-debug fix so re-using upstream binaries is fine.)

  All <repo>-relative paths are resolved from this script's own location
  (..\..\ from util\private-build\), so the script works on any clone
  without environment-specific edits.

  Produces:
    <DistRoot>\RenderDocPatched-source-debug[-release]\          full dir
    <DistRoot>\RenderDocPatched-source-debug[-release].zip       redistributable

.PARAMETER OfficialRD
  Path to an existing official RenderDoc install whose aux files we vendor.
  Default: C:\Program Files\RenderDoc

.PARAMETER BuildConfig
  Which RenderDoc build configuration to package: 'Development' or 'Release'.
  Default: 'Release'.  When this is supplied alone the script derives
  $PatchedBuild / $PatchedApk / package name automatically; explicit overrides
  still win.

.PARAMETER PatchedBuild
  Path to the rebuilt PC RenderDoc output dir.  Default:
  <repo>\x64\<BuildConfig>.

.PARAMETER PatchedApk
  Path to the rebuilt Android arm64 APK.  Default:
  <repo>\build-android[-release]\bin\org.renderdoc.renderdoccmd.arm64.apk.

.PARAMETER PackageName
  Override the output directory name under $DistRoot.  Default
  'RenderDocPatched-source-debug-release' for Release, 'RenderDocPatched-source-debug'
  for Development.

.PARAMETER DistRoot
  Where to drop the package.  Default: <repo>\dist (created if missing).

.PARAMETER MakeZip
  When set (default), also produce a .zip archive next to the dir.

.NOTES
  Run from a normal PowerShell (no admin needed).  The aux-file copy from
  Program Files only reads, it does not modify the official install.
#>
param(
    [string]$OfficialRD   = "C:\Program Files\RenderDoc",
    # When -BuildConfig is supplied, $PatchedBuild / $PatchedApk / $packageName are
    # auto-derived from it; explicit overrides still win.
    [ValidateSet('Development','Release')]
    [string]$BuildConfig  = 'Release',
    [string]$PatchedBuild = '',
    [string]$PatchedApk   = '',
    [string]$PackageName  = '',
    [string]$DistRoot     = '',
    [switch]$MakeZip      = $true
)

$ErrorActionPreference = 'Stop'

# --- resolve <repo> root from script location ---------------------------
# util\private-build\package_renderdoc_patched.ps1  ->  <repo>
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path

# --- defaults from BuildConfig ------------------------------------------
if (-not $PatchedBuild) {
    $PatchedBuild = Join-Path $repoRoot "x64\$BuildConfig"
}
if (-not $PatchedApk) {
    $androidBuildDir = if ($BuildConfig -eq 'Release') { 'build-android-release' } else { 'build-android' }
    $PatchedApk = Join-Path $repoRoot "$androidBuildDir\bin\org.renderdoc.renderdoccmd.arm64.apk"
}
if (-not $PackageName) {
    $PackageName = if ($BuildConfig -eq 'Release') {
        'RenderDocPatched-source-debug-release'
    } else {
        'RenderDocPatched-source-debug'
    }
}
if (-not $DistRoot) {
    $DistRoot = Join-Path $repoRoot 'dist'
}
if (-not (Test-Path -LiteralPath $DistRoot)) {
    New-Item -ItemType Directory -Path $DistRoot -Force | Out-Null
}

$packageName = $PackageName
$pkgDir      = Join-Path $DistRoot $packageName
$zipPath     = "$pkgDir.zip"

Write-Host "[pkg] BuildConfig    = $BuildConfig"
Write-Host "[pkg] PatchedBuild   = $PatchedBuild"
Write-Host "[pkg] PatchedApk     = $PatchedApk"
Write-Host "[pkg] PackageName    = $packageName"

# --- pre-flight checks ---------------------------------------------------
foreach ($p in @($PatchedBuild, $PatchedApk)) {
    if (-not (Test-Path -LiteralPath $p)) {
        throw "Required path missing: $p"
    }
}
if (-not (Test-Path -LiteralPath "$PatchedBuild\qrenderdoc.exe")) {
    throw "Patched qrenderdoc.exe not found in $PatchedBuild"
}

# Resolve OfficialRD: if it's missing or empty (e.g. because the user already
# overlaid a previous package on top of it and we only have the backup),
# fall back to the most recent `RenderDoc.backup-*` sibling.
function Resolve-OfficialSource([string]$primary) {
    if ((Test-Path -LiteralPath $primary) -and
        (Get-ChildItem -LiteralPath $primary -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        return $primary
    }
    $parent = Split-Path -Parent $primary
    $leaf   = Split-Path -Leaf   $primary
    $backup = Get-ChildItem -LiteralPath $parent -Directory -Filter "$leaf.backup-*" -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($backup -and (Get-ChildItem -LiteralPath $backup.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Write-Host "[pkg] $primary is empty; falling back to backup $($backup.FullName)" -ForegroundColor Yellow
        return $backup.FullName
    }
    throw "Cannot find aux files. Tried $primary and $parent\$leaf.backup-*"
}
$OfficialRD = Resolve-OfficialSource $OfficialRD

# --- clean & recreate package dir ---------------------------------------
if (Test-Path -LiteralPath $pkgDir) {
    Write-Host "[pkg] removing previous $pkgDir" -ForegroundColor Yellow
    Remove-Item -LiteralPath $pkgDir -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
New-Item -ItemType Directory -Path $pkgDir | Out-Null

# --- 1. files we built ourselves (overrides any vendored same-name) -----
$rebuiltRuntime = @(
    'qrenderdoc.exe',
    'renderdoccmd.exe',
    'renderdocshim64.dll',
    'renderdocui.exe',
    'renderdoc.dll',
    'renderdoc.json',
    'renderdoc_app.h',
    'Qt5Core.dll', 'Qt5Gui.dll', 'Qt5Network.dll', 'Qt5Svg.dll', 'Qt5Widgets.dll',
    'python36.dll', 'python36.zip', '_ctypes.pyd',
    'd3dcompiler_47.dll', 'dbghelp.dll', 'symsrv.dll', 'symsrv.yes'
)
Write-Host "[pkg] copying $($rebuiltRuntime.Count) rebuilt runtime files"
foreach ($f in $rebuiltRuntime) {
    $src = Join-Path $PatchedBuild $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $pkgDir
    } else {
        Write-Warning "missing rebuilt file (skipped): $f"
    }
}

# rebuilt qrenderdoc.pyd / renderdoc.pyd (Python bindings for `import renderdoc` in Python Shell)
New-Item -ItemType Directory -Path (Join-Path $pkgDir 'pymodules') | Out-Null
foreach ($f in @('qrenderdoc.pyd', 'renderdoc.pyd', 'd3dcompiler_47.dll')) {
    $src = Join-Path $PatchedBuild "pymodules\$f"
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $pkgDir "pymodules")
    }
}

# rebuilt qtplugins (platforms/qwindows.dll + imageformats/qsvg.dll)
$qtSrc = Join-Path $PatchedBuild 'qtplugins'
if (Test-Path -LiteralPath $qtSrc) {
    Copy-Item -LiteralPath $qtSrc -Destination $pkgDir -Recurse
}

# --- 2. files we vendor from the official install (un-patched, identical) -
$vendored = @(
    'libcrypto-1_1-x64.dll',
    'libssl-1_1-x64.dll',
    'shiboken2.dll',
    'renderdoc.chm',
    'LICENSE.md',
    'LICENSE.rtf'
)
Write-Host "[pkg] vendoring $($vendored.Count) auxiliary files from $OfficialRD"
foreach ($f in $vendored) {
    $src = Join-Path $OfficialRD $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $pkgDir
    } else {
        Write-Warning "missing official aux file (skipped): $f"
    }
}

# vendor PySide2 (Python bindings) verbatim
foreach ($d in @('PySide2', 'plugins', 'x86')) {
    $src = Join-Path $OfficialRD $d
    if (Test-Path -LiteralPath $src) {
        Write-Host "[pkg] vendoring directory $d/"
        Copy-Item -LiteralPath $src -Destination $pkgDir -Recurse
    }
}

# --- 3. drop-in our patched arm64 APK over the official one --------------
$apkDest = Join-Path $pkgDir 'plugins\android\org.renderdoc.renderdoccmd.arm64.apk'
if (-not (Test-Path -LiteralPath (Split-Path $apkDest))) {
    New-Item -ItemType Directory -Path (Split-Path $apkDest) -Force | Out-Null
}
Write-Host "[pkg] replacing arm64 APK with patched build"
Copy-Item -LiteralPath $PatchedApk -Destination $apkDest -Force

# also drop in install_as_default.ps1 next to the package files so receivers
# can choose to overlay this onto C:\Program Files\RenderDoc with one command
$installer = Join-Path (Split-Path $MyInvocation.MyCommand.Path) 'install_as_default.ps1'
if (Test-Path -LiteralPath $installer) {
    Write-Host "[pkg] including install_as_default.ps1 in package"
    Copy-Item -LiteralPath $installer -Destination $pkgDir
} else {
    Write-Warning "install_as_default.ps1 not found at $installer (skipped)"
}

# --- 4. write README ----------------------------------------------------
$readme = @"
RenderDoc — patched build (Android remote source-debug + Vulkan multi-replace fix)
====================================================================================

Upstream base : RenderDoc v1.45 (commit ad95260de1d8168f6f07f8f9d23fd7c78a4cb8c6)
Patched head  : private-build-all-fixes — commit cf79369c77e76b69b79a206fb2ff9324eec907f0
Patched on    : $(Get-Date -Format 'yyyy-MM-dd')
Source        : https://github.com/fengshanglantian/renderdoc/tree/private-build-all-fixes
Maintainer    : private fork (do NOT redistribute outside the team)


WHAT THIS FIXES
---------------

Three Vulkan replay bugs that bite UE5 mobile (Android remote replay) shader
debugging workflows, all stacked on top of stock RenderDoc v1.45:

 1. **Source-debug "Unavailable" after shader replace** (003c3dc4f)
    Replacing a Vulkan SPV with NonSemantic.Shader.DebugInfo.100 embedded
    HLSL on Android remote replay used to show "Source debugging Unavailable"
    because the host-side m_ShaderReflectionCache served the original (no-
    debug-info) reflection. Fix propagates the replacement SPV's reflection
    into the original ShaderModule slot and flushes the proxy cache.
    See PR #3844.

 2. **NULL deref in OpDebugValue/OpDebugDeclare** (2109da829)
    SPIR-V source debug walker crashed when curScope was NULL between a
    block terminator and the next OpDebugScope. Now defers the
    HasAncestor check until a valid scope is bound. See PR #3845.

 3. **Iterator invalidation in RefreshDerivedReplacements** (cf79369c7)
    The replay-mode pipeline-rebuild loop iterates m_Pipeline (an
    std::unordered_map) while inserting new entries via the wrapped
    vkCreateGraphicsPipelines. Inserting into an unordered_map can
    trigger rehash, which invalidates all iterators — continued use is
    undefined behaviour. Latent on small captures; manifests on real
    UE5 games where a single PS variant is referenced by tens of
    pipelines and the cumulative inserts push past max_load_factor,
    especially on Android libc++ whose prime-table bucket sequence
    leaves very small headroom after capture load. Symptoms include
    VK_ERROR_DEVICE_LOST or use-after-free crashes on the next replay.
    Fix splits the function into two phases: read-only ID collection,
    then a separate mutation pass.

Both endpoints (PC qrenderdoc and the on-device renderdoccmd APK) must run
the patched build — this package handles that automatically because
qrenderdoc auto-pushes the bundled APK to any phone whose installed RD
version doesn't match.

Verified on Pixel 9 Pro XL (Android 16, Tensor G4 / Mali, 16 KiB pages)
running UE5 Mobile Vulkan SM5 captures.


HOW TO USE — INDIVIDUAL
-----------------------
1. Unpack this folder anywhere (e.g. D:\Tools\RenderDocPatched).
2. Double-click qrenderdoc.exe.
3. (First-time use with a phone) plug in the Android device with USB
   debugging enabled. qrenderdoc will detect the version mismatch and
   prompt to push the bundled APK; click yes.
4. Capture / open a frame as usual; for shader-replace flows see your
   team's RenderDoc Python Shell scripts.


HOW TO USE — MAKE THIS THE SYSTEM DEFAULT (replace official v1.44 install)
--------------------------------------------------------------------------
Option A (one-liner, recommended — preserves .rdc file association):

  Right-click `install_as_default.ps1` (in this folder) -> Run with PowerShell.
  Or from a terminal:
      powershell -ExecutionPolicy Bypass -File .\install_as_default.ps1

  The script will:
    1. self-elevate to admin
    2. move existing C:\Program Files\RenderDoc\ to a timestamped backup
    3. copy this folder to C:\Program Files\RenderDoc\
    4. verify renderdoccmd.exe reports the patched commit hash

  To roll back later:
      powershell -ExecutionPolicy Bypass -File .\install_as_default.ps1 -Restore


Option B (manual, if you don't want to run a script):

  1. Add/Remove Programs -> uninstall "RenderDoc 1.44" / "RenderDoc"
  2. Copy the entire contents of this folder into
       C:\Program Files\RenderDoc\
     (create the dir if you uninstalled cleanly)
  3. Optionally pin C:\Program Files\RenderDoc\qrenderdoc.exe to taskbar.
  4. To re-associate .rdc capture files:
       right-click any .rdc -> Open With -> Choose another app ->
       More apps -> Look for another app -> select qrenderdoc.exe ->
       check "Always use this app"

Option C (portable, no admin):

  Keep the official install but always launch qrenderdoc.exe from THIS
  folder. Add this folder to %PATH% if you want `qrenderdoc` to resolve
  globally. Don't double-click .rdc files (they'll go to the official install).


HOW TO USE — SHARE WITH SOMEONE ELSE
------------------------------------
Just zip the whole folder and send it. The receiver does the same as
"INDIVIDUAL" above. The bundled APK auto-deploys to their phone too.

If you share to teammates whose phones are NOT arm64, note that
plugins\android\org.renderdoc.renderdoccmd.arm32.apk is the unpatched
upstream RD; arm32 devices will still hit the original Source-debug bug.
We did not rebuild arm32 (no test device).


WHAT'S IN THIS FOLDER
---------------------
  qrenderdoc.exe              ← patched UI
  renderdoccmd.exe            ← patched command-line variant
  renderdoc.dll               ← patched core (contains all three C++ patches)
  install_as_default.ps1      ← optional: overlay this onto C:\Program Files\RenderDoc
  plugins\android\
    org.renderdoc.renderdoccmd.arm64.apk   ← patched Android APK (auto-pushed)
    org.renderdoc.renderdoccmd.arm32.apk   ← upstream, NOT patched
    adb.exe / aapt.exe / apksigner.jar / zipalign.exe (vendored)
  PySide2\, qtplugins\, plugins\amd\d3d12\spirv\ (vendored from upstream)


KNOWN GOOD ENVIRONMENT
----------------------
- PC : Windows 10/11 x64
- Phone : Pixel 9 Pro XL Android 16, arm64-v8a (16 KiB pages)
- Capture : UE5 Mobile Vulkan SM5 (.rdc on Android remote)


TROUBLESHOOTING
---------------
- "Source debugging Unavailable" still shows after replace
  → Make sure the phone has the patched APK
       adb shell dumpsys package org.renderdoc.renderdoccmd.arm64 | findstr versionName
       expect: versionName=cf79369c77e76b69b79a206fb2ff9324eec907f0
       (if you see 050034a0… that's stock v1.44 — uninstall and reconnect to let qrenderdoc push the patched one)
  → Make sure you're running THIS qrenderdoc.exe and not the system one
       (Task Manager -> Details, look at qrenderdoc.exe path)

- VK_ERROR_DEVICE_LOST after replacing 2+ shaders simultaneously
  → Confirm both endpoints carry commit cf79369c7 or later:
       renderdoccmd.exe version          (PC side)
       adb shell dumpsys package org.renderdoc.renderdoccmd.arm64 | findstr versionName  (device side)
  → If your shader-replace tooling loads SPV paths from a config file,
    make sure it re-reads that config on every invocation. RenderDoc's
    Python Shell keeps the Python interpreter alive across script runs,
    so any module-level caching in your tool will serve stale paths
    after you edit the config mid-session — and replacing draw call B's
    shader with draw call A's SPV blob will also trigger Device Lost.

- Phone reports "App not installed for compatibility reasons" /
  "App was built for an older version of Android"
  → You're running the OLD APK from before the Android 16 deployment fixes.
    Reinstall this package's APK; it sets targetSdk=28 + 16 KiB ELF align.

- "Debug Pixel" button is greyed out after running the replace script
  → Use a replace script that calls SetEventID(force=True) after
    ReplaceResource — without it qrenderdoc keeps the cached
    PipelineState (with the original reflection) until you click
    another draw call and back, leaving Debug Pixel disabled.

For deeper issues, contact the package maintainer.
"@
$readme | Set-Content -Encoding utf8 -LiteralPath (Join-Path $pkgDir 'README.md')

# --- 5. summary report --------------------------------------------------
$totalSize = (Get-ChildItem -LiteralPath $pkgDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
"`n=== Package summary ===" 
"  dir   : $pkgDir"
"  size  : {0:N1} MB ({1:N0} files)" -f ($totalSize / 1MB), (Get-ChildItem -LiteralPath $pkgDir -Recurse -File).Count

# --- 6. zip if requested ------------------------------------------------
if ($MakeZip) {
    Write-Host "[pkg] compressing to $zipPath ..."
    Compress-Archive -Path "$pkgDir\*" -DestinationPath $zipPath -CompressionLevel Optimal -Force
    "  zip   : $zipPath"
    "  zip MB: {0:N1}" -f ((Get-Item -LiteralPath $zipPath).Length / 1MB)
}

Write-Host "[pkg] done." -ForegroundColor Green
