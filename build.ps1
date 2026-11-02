<#
.SYNOPSIS
    Builds Aseprite from the official source code on Windows.

.DESCRIPTION
    Downloads the Aseprite sources and a matching Skia build, configures the
    Visual Studio toolchain and compiles Aseprite with CMake and Ninja.
    CMake and Ninja are downloaded automatically when they are missing.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

    The resulting binary is covered by the Aseprite EULA: it is for personal
    use only and must not be redistributed.

.EXAMPLE
    .\build.ps1
    Builds the latest release for this machine.

.EXAMPLE
    .\build.ps1 -Version v1.3.17 -Arch arm64 -Yes
    Builds a specific release for Windows on ARM without prompts.
#>
[CmdletBinding()]
param(
    # Aseprite release to build, e.g. v1.3.18.6 (default: latest)
    [string]$Version = $(if ($env:ASEPRITE_VERSION) { $env:ASEPRITE_VERSION } else { 'latest' }),
    # Target architecture (default: host)
    [ValidateSet('', 'x64', 'arm64')]
    [string]$Arch = $(if ($env:TARGET_ARCH) { $env:TARGET_ARCH } else { '' }),
    # Override the Skia tag (default: read from the sources)
    [string]$SkiaTag = $env:SKIA_TAG,
    # Always compile Skia instead of downloading a prebuilt package
    [switch]$SkiaFromSource,
    [ValidateSet('Release', 'RelWithDebInfo')]
    [string]$BuildType = 'Release',
    # Parallel compile jobs (default: based on CPUs and RAM)
    [int]$Jobs = 0,
    [string]$OutputDir = '',
    # Downloads and build files. Keep it short: Windows has a 260 character path limit.
    [string]$WorkDir = '',
    # Install Visual Studio Build Tools (and Python on ARM64) with winget
    [switch]$InstallDeps,
    # Discard previous build files for this version
    [switch]$Fresh,
    # Do not create a .zip, keep only the folder
    [switch]$NoArchive,
    # Do not ask for confirmation
    [switch]$Yes,
    # List the most recent Aseprite releases and exit
    [switch]$List,
    # Remove the work and output directories and exit
    [switch]$Clean,
    # Print the version of this script and exit
    [switch]$ScriptVersion
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:Version_ = '4.0.0'
$script:Root = $PSScriptRoot
$script:AsepriteRepo = 'aseprite/aseprite'
$script:SkiaRepo = 'aseprite/skia'
$script:InCI = [bool]$env:GITHUB_ACTIONS

# Portable tools used when the installed ones are missing or too old
$script:Tools = @{
    cmake = @{
        Version = '3.31.8'
        x64     = @{ Url = 'https://github.com/Kitware/CMake/releases/download/v3.31.8/cmake-3.31.8-windows-x86_64.zip'
                     Sha256 = '81aa9964dbabd71fe02e7ec50472fd3ad56138c49944515ece9001efbff8d719' }
        arm64   = @{ Url = 'https://github.com/Kitware/CMake/releases/download/v3.31.8/cmake-3.31.8-windows-arm64.zip'
                     Sha256 = 'd37ca89ec60aece080664ee936f7aaffdfdbde0a201b165c45ecfaf68a4c1fa9' }
    }
    ninja = @{
        Version = '1.12.1'
        x64     = @{ Url = 'https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip'
                     Sha256 = 'f550fec705b6d6ff58f2db3c374c2277a37691678d6aba463adcbb129108467a' }
        arm64   = @{ Url = 'https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-winarm64.zip'
                     Sha256 = '79c96a50e0deafec212cfa85aa57c6b74003f52d9d1673ddcd1eab1c958c5900' }
    }
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Message) {
    if ($script:InCI) { Write-Host "::group::$Message" }
    Write-Host ''
    Write-Host '==> ' -ForegroundColor Blue -NoNewline
    Write-Host $Message -ForegroundColor White
}
function Close-Step { if ($script:InCI) { Write-Host '::endgroup::' } }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Write-Ok([string]$Message) { Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) {
    Write-Host "warning: $Message" -ForegroundColor Yellow
    if ($script:InCI) { Write-Host "::warning::$Message" }
}
function Stop-Build([string]$Message) {
    if ($script:InCI) { Write-Host "::error::$Message" }
    throw $Message
}

function Confirm-Action([string]$Prompt) {
    if ($Yes) { return $true }
    if ($script:InCI -or -not [Environment]::UserInteractive) {
        Stop-Build "$Prompt (refusing to continue in non-interactive mode, use -Yes)"
    }
    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -match '^[YySs]$')
}

function Invoke-WithRetry([scriptblock]$Action, [int]$Attempts = 4, [int]$DelaySeconds = 3) {
    for ($i = 1; $i -le $Attempts; $i++) {
        try { return & $Action }
        catch {
            if ($i -eq $Attempts) { throw }
            Write-Warn "attempt $i/$Attempts failed: $($_.Exception.Message). Retrying in $DelaySeconds s"
            Start-Sleep -Seconds $DelaySeconds
            $DelaySeconds *= 2
        }
    }
}

# Runs a native command and fails on a non-zero exit code
function Invoke-Native([string]$FilePath, [string[]]$Arguments) {
    Write-Verbose "$FilePath $($Arguments -join ' ')"
    # Out-Host keeps the command output on screen without leaking it into
    # the pipeline, where it would become part of the caller's return value.
    & $FilePath @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Stop-Build "'$(Split-Path -Leaf $FilePath)' failed with exit code $LASTEXITCODE"
    }
}

function Test-Command([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
function Invoke-GitHubApi([string]$Path) {
    $headers = @{ 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'
                  'User-Agent' = 'aseprite-compiler' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    return Invoke-WithRetry { Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers $headers -TimeoutSec 60 }
}

function Get-RemoteFile([string]$Url, [string]$Destination, [string]$Sha256 = '') {
    if ((Test-Path $Destination) -and $Sha256) {
        if ((Get-FileHash $Destination -Algorithm SHA256).Hash -eq $Sha256) { return }
        Write-Warn "cached $(Split-Path -Leaf $Destination) is corrupt, downloading it again"
        Remove-Item $Destination -Force
    }
    if (Test-Path $Destination) { return }

    New-Item -ItemType Directory -Force -Path (Split-Path $Destination) | Out-Null
    $partial = "$Destination.part"
    Write-Info "downloading $(Split-Path -Leaf $Destination)"
    Invoke-WithRetry -Attempts 4 -DelaySeconds 5 {
        if (Test-Command 'curl.exe') {
            $progress = if ($script:InCI) { '-sS' } else { '--progress-bar' }
            & curl.exe -fL --connect-timeout 30 --retry 3 $progress -o $partial $Url
            if ($LASTEXITCODE -ne 0) { throw "curl exited with code $LASTEXITCODE" }
        } else {
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -TimeoutSec 600
        }
    } | Out-Null

    if ($Sha256) {
        $actual = (Get-FileHash $partial -Algorithm SHA256).Hash
        if ($actual -ne $Sha256) {
            Remove-Item $partial -Force
            Stop-Build "checksum mismatch for $(Split-Path -Leaf $Destination): expected $Sha256, got $actual"
        }
    }
    Move-Item -Force $partial $Destination
}

function Expand-Zip([string]$Archive, [string]$Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    # bsdtar (bundled with Windows 10 1803+) is much faster than Expand-Archive
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
        & $tar -xf $Archive -C $Destination
        if ($LASTEXITCODE -eq 0) { return }
        Write-Warn 'tar.exe failed, falling back to Expand-Archive'
    }
    Expand-Archive -Path $Archive -DestinationPath $Destination -Force
}

# ---------------------------------------------------------------------------
# Platform and toolchain
# ---------------------------------------------------------------------------
function Get-HostArch {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default { Stop-Build "unsupported CPU architecture: $arch (Aseprite requires a 64-bit system)" }
    }
}

function Get-VsWhere {
    $path = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $path) { return $path }
    return $null
}

function Find-VisualStudio([string]$TargetArch) {
    $vswhere = Get-VsWhere
    if (-not $vswhere) { return $null }
    $component = if ($TargetArch -eq 'arm64') { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' }
                 else { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
    $path = & $vswhere -latest -products '*' -requires $component -property installationPath
    if ($path) { return ($path | Select-Object -First 1) }
    return $null
}

function Install-Dependencies([string]$TargetArch, [string]$HostArch) {
    Write-Step 'Installing dependencies with winget'
    if (-not (Test-Command 'winget')) {
        Stop-Build 'winget is not available. Install "App Installer" from the Microsoft Store or install the dependencies manually (see README.md)'
    }
    if (-not (Find-VisualStudio $TargetArch)) {
        $components = '--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.26100 --includeRecommended'
        if ($TargetArch -eq 'arm64') {
            $components += ' --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --add Microsoft.VisualStudio.Component.VC.Llvm.Clang'
        }
        Write-Info 'installing Visual Studio 2022 Build Tools (this takes a while)'
        Invoke-Native 'winget' @('install', '--id', 'Microsoft.VisualStudio.2022.BuildTools', '-e',
            '--accept-source-agreements', '--accept-package-agreements',
            '--override', "--wait --passive $components")
    } else {
        Write-Ok 'Visual Studio with C++ tools already installed'
    }
    if ($TargetArch -eq 'arm64' -and -not (Find-Python)) {
        Invoke-Native 'winget' @('install', '--id', 'Python.Python.3.12', '-e',
            '--accept-source-agreements', '--accept-package-agreements')
    }
    if (-not (Test-Command 'git')) {
        Invoke-Native 'winget' @('install', '--id', 'Git.Git', '-e',
            '--accept-source-agreements', '--accept-package-agreements')
    }
    Write-Ok 'dependencies installed (open a new terminal if a tool is not found)'
    Close-Step
}

function Import-VsEnvironment([string]$VsPath, [string]$TargetArch, [string]$HostArch) {
    $vsDevCmd = Join-Path $VsPath 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path $vsDevCmd)) { Stop-Build "VsDevCmd.bat not found in $VsPath" }
    $target = if ($TargetArch -eq 'arm64') { 'arm64' } else { 'amd64' }
    $hostArg = if ($HostArch -eq 'arm64') { 'arm64' } else { 'amd64' }

    $output = & cmd.exe /s /c "`"$vsDevCmd`" -no_logo -arch=$target -host_arch=$hostArg && set"
    if ($LASTEXITCODE -ne 0) { Stop-Build "unable to initialise the Visual Studio environment ($vsDevCmd)" }
    foreach ($line in $output) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
    if (-not (Test-Command 'cl.exe')) { Stop-Build 'cl.exe is not available after loading the Visual Studio environment' }
}

function Find-Python {
    foreach ($candidate in @('python', 'python3', 'py')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        # Skip the Microsoft Store alias, which only opens the store
        if ($cmd.Source -like '*\WindowsApps\*') { continue }
        $args_ = if ($candidate -eq 'py') { @('-3', '-c', 'import sys; print(sys.executable)') }
                 else { @('-c', 'import sys; print(sys.executable)') }
        $exe = & $cmd.Source @args_ 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe) { return ($exe | Select-Object -First 1).Trim() }
    }
    return $null
}

function Resolve-Tool([string]$Name, [string]$MinVersion, [string]$HostArch, [string]$ToolsDir) {
    $cmd = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($cmd) {
        $versionText = (& $cmd.Source --version | Select-Object -First 1)
        if ($versionText -match '(\d+\.\d+(\.\d+)?)' -and [version]$Matches[1] -ge [version]$MinVersion) {
            return $cmd.Source
        }
        Write-Warn "$Name $($Matches[1]) is too old (needs $MinVersion), using a portable copy"
    }
    $spec = $script:Tools[$Name]
    $asset = $spec[$HostArch]
    $dir = Join-Path $ToolsDir "$Name-$($spec.Version)-$HostArch"
    $exe = Get-ChildItem -Path $dir -Recurse -Filter "$Name.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) {
        $zip = Join-Path $ToolsDir (Split-Path -Leaf $asset.Url)
        Get-RemoteFile $asset.Url $zip $asset.Sha256
        Expand-Zip $zip $dir
        $exe = Get-ChildItem -Path $dir -Recurse -Filter "$Name.exe" | Select-Object -First 1
    }
    if (-not $exe) { Stop-Build "unable to set up $Name" }
    return $exe.FullName
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
function Show-Versions {
    $releases = Invoke-GitHubApi "repos/$script:AsepriteRepo/releases?per_page=15"
    Write-Host 'Recent Aseprite releases:' -ForegroundColor White
    foreach ($r in $releases) {
        $suffix = if ($r.prerelease) { '  (pre-release)' } else { '' }
        Write-Host ('  {0,-16} {1}{2}' -f $r.tag_name, $r.published_at.ToString().Substring(0, 10), $suffix)
    }
}

function Resolve-AsepriteRelease([string]$Requested) {
    Write-Step 'Resolving Aseprite version'
    try {
        if ($Requested -eq 'latest') {
            $release = Invoke-GitHubApi "repos/$script:AsepriteRepo/releases/latest"
        } else {
            if ($Requested -notlike 'v*') { $Requested = "v$Requested" }
            $release = Invoke-GitHubApi "repos/$script:AsepriteRepo/releases/tags/$Requested"
        }
    } catch {
        Stop-Build "unable to find Aseprite release '$Requested' ($($_.Exception.Message)). Use -List to see the available releases"
    }
    $asset = $release.assets | Where-Object { $_.name -like '*-Source.zip' } | Select-Object -First 1
    $info = [ordered]@{
        Tag    = $release.tag_name
        Url    = $null
        Sha256 = ''
    }
    if ($asset) {
        $info.Url = $asset.browser_download_url
        if ($asset.PSObject.Properties['digest'] -and $asset.digest) {
            $info.Sha256 = ($asset.digest -replace '^sha256:', '').ToUpperInvariant()
        }
    }
    Write-Info "version  $($info.Tag)"
    if ($info.Url) { Write-Info "source   $(Split-Path -Leaf $info.Url)" }
    else { Write-Info 'source   git clone (no source package published for this release)' }
    Close-Step
    return $info
}

function Get-AsepriteSources($Release, [string]$Work) {
    Write-Step "Fetching Aseprite $($Release.Tag) sources"
    $dir = Join-Path $Work "src\$($Release.Tag)"
    $marker = Join-Path $dir '.aseprite-compiler-complete'
    if (Test-Path $marker) {
        Write-Ok "reusing sources in $dir"
        Close-Step
        return $dir
    }
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }

    if ($Release.Url) {
        $zip = Join-Path $Work "downloads\$(Split-Path -Leaf $Release.Url)"
        Get-RemoteFile $Release.Url $zip $Release.Sha256
        if ($Release.Sha256) { Write-Ok "checksum verified (sha256 $($Release.Sha256.ToLowerInvariant()))" }
        Write-Info 'extracting'
        Expand-Zip $zip $dir
    } else {
        if (-not (Test-Command 'git')) { Stop-Build 'git is required to download this release (install Git for Windows)' }
        Invoke-WithRetry {
            Invoke-Native 'git' @('-c', 'advice.detachedHead=false', '-c', 'core.longpaths=true', 'clone',
                '--quiet', '--depth', '1', '--recursive', '--shallow-submodules', '--branch', $Release.Tag,
                "https://github.com/$script:AsepriteRepo.git", $dir)
        } | Out-Null
    }
    if (-not (Test-Path (Join-Path $dir 'laf\CMakeLists.txt'))) { Stop-Build 'the Aseprite sources are incomplete' }
    New-Item -ItemType File -Force -Path $marker | Out-Null
    Write-Ok "sources ready in $dir"
    Close-Step
    return $dir
}

# Source fixes required to build with MSVC for ARM64. MSVC defines _WIN64 on
# ARM64 too, but some upstream preprocessor checks use it to mean "x86-64".
# Each fix is a regular expression anchored to a whole line, so only those
# exact checks change. The edits are idempotent and are no-ops on x64.
function Repair-Sources([string]$SourceDir) {
    $fixes = @(
        # SSE2 intrinsics guard: x86-64 only. The separate 64-bit pointer
        # check in the same file starts with defined(__LP64__) and must keep
        # _WIN64, so it does not match this pattern.
        @{ File = 'src\doc\primitives.cpp'
           Pattern = '(?m)^(\s*#\s*if\s+defined\(__x86_64__\)\s*\|\|\s*)defined\(_WIN64\)'
           Replacement = '${1}defined(_M_X64)' },
        # Undo the over-broad edit made by build.ps1 4.0.0 in cached sources
        @{ File = 'src\doc\primitives.cpp'
           Pattern = '(?m)^(\s*#\s*if\s+defined\(__LP64__\)\s*\|\|\s*defined\(__x86_64__\)\s*\|\|\s*)defined\(_M_X64\)'
           Replacement = '${1}defined(_WIN64)' },
        # Report the right CPU architecture in the About dialog
        @{ File = 'laf\base\platform.h'
           Pattern = '(?m)^(\s*#\s*if\s+defined\(__arm64__\)\s*\|\|\s*defined\(__aarch64__\))\s*$'
           Replacement = '${1} || defined(_M_ARM64)' }
    )
    foreach ($fix in $fixes) {
        $path = Join-Path $SourceDir $fix.File
        if (-not (Test-Path $path)) { continue }
        $text = [IO.File]::ReadAllText($path)
        $patched = [regex]::Replace($text, $fix.Pattern, $fix.Replacement)
        if ($patched -ne $text) {
            [IO.File]::WriteAllText($path, $patched)
            Write-Info "patched $($fix.File) for MSVC ARM64"
        }
    }
}

function Get-Skia([string]$SourceDir, [string]$TargetArch, [string]$Work, [string]$Ninja, [string]$VsPath) {
    Write-Step 'Preparing Skia'
    $tag = $SkiaTag
    if (-not $tag) {
        $tagFile = Join-Path $SourceDir 'laf\misc\skia-tag.txt'
        if (-not (Test-Path $tagFile)) { Stop-Build "$tagFile not found; specify the Skia tag with -SkiaTag" }
        $tag = (Get-Content $tagFile -Raw).Trim()
    }
    if ($tag -notmatch '^m\d+-[0-9a-f]+$') { Stop-Build "invalid Skia tag: $tag" }
    Write-Info "tag      $tag"

    $dir = Join-Path $Work "deps\skia-$tag-$TargetArch"
    $libDir = Join-Path $dir "out\Release-$TargetArch"
    if (Test-Path (Join-Path $libDir 'skia.lib')) {
        Write-Ok "reusing Skia in $dir"
        Close-Step
        return @{ Tag = $tag; Dir = $dir; LibDir = $libDir }
    }

    $package = $null
    if (-not $SkiaFromSource) {
        try {
            $release = Invoke-GitHubApi "repos/$script:SkiaRepo/releases/tags/$tag"
            $name = "Skia-Windows-Release-$TargetArch.zip"
            $package = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
        } catch {
            Write-Warn "unable to query Skia releases: $($_.Exception.Message)"
        }
    }

    if ($package) {
        Write-Info "package  $($package.name) (prebuilt)"
        $zip = Join-Path $Work "downloads\skia-$tag-$($package.name)"
        Get-RemoteFile $package.browser_download_url $zip
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        try { Expand-Zip $zip $dir }
        catch {
            Remove-Item -Force $zip
            Stop-Build 'the Skia package is corrupt, run the script again to download it'
        }
    } else {
        Write-Info "no prebuilt package for windows-$TargetArch, compiling Skia from source"
        $python = Find-Python
        if (-not $python) { Stop-Build 'Python 3 is required to compile Skia (use -InstallDeps or install it from python.org)' }
        if (-not (Test-Command 'git')) { Stop-Build 'git is required to compile Skia (use -InstallDeps or install Git for Windows)' }
        $skiaArgs = @((Join-Path $script:Root 'scripts\build-skia.py'), '--tag', $tag, '--arch', $TargetArch,
                      '--dest', $dir, '--ninja', $Ninja, '--win-vc', (Join-Path $VsPath 'VC'))
        if ($Jobs -gt 0) { $skiaArgs += @('--jobs', "$Jobs") }
        Invoke-Native $python $skiaArgs
    }
    if (-not (Test-Path (Join-Path $libDir 'skia.lib'))) { Stop-Build "skia.lib not found in $libDir" }
    Write-Ok "Skia ready in $dir"
    Close-Step
    return @{ Tag = $tag; Dir = $dir; LibDir = $libDir }
}

function Get-DefaultJobs {
    $cpus = [Environment]::ProcessorCount
    try {
        $memGb = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    } catch { $memGb = 8 }
    $jobs = [math]::Max(1, [math]::Floor($memGb * 2 / 3))
    return [int][math]::Min($cpus, $jobs)
}

function Build-Aseprite([string]$SourceDir, $Skia, [string]$TargetArch, [string]$Work, [string]$CMake, [string]$Ninja, [bool]$FromPackage, [string]$Tag) {
    Write-Step 'Configuring Aseprite'
    $buildDir = Join-Path $Work "build\$Tag-$TargetArch"
    if ($Fresh -and (Test-Path $buildDir)) { Remove-Item -Recurse -Force $buildDir }
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

    $cmakeArgs = @(
        '-S', $SourceDir, '-B', $buildDir, '-G', 'Ninja',
        "-DCMAKE_MAKE_PROGRAM=$Ninja",
        "-DCMAKE_BUILD_TYPE=$BuildType",
        '-DCMAKE_C_COMPILER=cl', '-DCMAKE_CXX_COMPILER=cl',
        '-DLAF_BACKEND=skia',
        "-DSKIA_DIR=$($Skia.Dir)",
        "-DSKIA_LIBRARY_DIR=$($Skia.LibDir)",
        "-DSKIA_LIBRARY=$(Join-Path $Skia.LibDir 'skia.lib')",
        '-DENABLE_TESTS=OFF',
        '-DENABLE_CCACHE=OFF'
    )
    # The source package is not a git checkout
    if ($FromPackage) { $cmakeArgs += '-DUPDATE_VERSION_WITH_GIT=OFF' }
    Invoke-Native $CMake $cmakeArgs
    Close-Step

    $jobCount = if ($Jobs -gt 0) { $Jobs } else { Get-DefaultJobs }
    Write-Step "Compiling Aseprite ($jobCount parallel jobs)"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Native $Ninja @('-C', $buildDir, '-j', "$jobCount", 'aseprite')
    Write-Ok ('compiled in {0:mm}m {0:ss}s' -f $timer.Elapsed)
    Close-Step
    return (Join-Path $buildDir 'bin')
}

function New-Package([string]$BinDir, [string]$SourceDir, [string]$Tag, [string]$TargetArch, [string]$SkiaTagUsed, [string]$Output) {
    Write-Step 'Packaging'
    $name = "aseprite-$Tag-windows-$TargetArch"
    $dest = Join-Path $Output $name
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    $exe = Join-Path $BinDir 'aseprite.exe'
    if (-not (Test-Path $exe)) { Stop-Build 'aseprite.exe was not produced' }
    Copy-Item $exe $dest
    Copy-Item -Recurse (Join-Path $BinDir 'data') $dest
    # icudtl.dat is loaded at runtime by Skia's text shaping on Windows
    $icu = Join-Path $BinDir 'icudtl.dat'
    if (Test-Path $icu) { Copy-Item $icu $dest } else { Write-Warn 'icudtl.dat not found; text shaping may be degraded' }
    Copy-Item (Join-Path $SourceDir 'EULA.txt') $dest

    $notice = @"
Aseprite $Tag (windows-$TargetArch)
Built from https://github.com/$script:AsepriteRepo on $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC
Skia: $SkiaTagUsed
Build type: $BuildType

This build is covered by the Aseprite End-User License Agreement
(EULA.txt). It may only be used for personal purposes and must not be
redistributed. To support the developers, buy Aseprite at
https://www.aseprite.org/
"@
    Set-Content -Path (Join-Path $dest 'BUILD-INFO.txt') -Value $notice -Encoding ASCII
    Write-Ok "application: $dest"

    if (-not $NoArchive) {
        $zip = "$dest.zip"
        if (Test-Path $zip) { Remove-Item -Force $zip }
        $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        $created = $false
        if (Test-Path $tar) {
            Push-Location $Output
            try { & $tar -a -c -f "$name.zip" $name; $created = ($LASTEXITCODE -eq 0) } finally { Pop-Location }
        }
        if (-not $created) { Compress-Archive -Path $dest -DestinationPath $zip -Force }
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -Path "$zip.sha256" -Value "$hash  $name.zip" -Encoding ASCII
        Write-Ok "archive:     $zip"
    }
    Close-Step
    return $name
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Main {
    if ($ScriptVersion) { Write-Output $script:Version_; return }

    if (-not $WorkDir) { $script:WorkDirResolved = Join-Path $script:Root '.work' } else { $script:WorkDirResolved = $WorkDir }
    if (-not $OutputDir) { $script:OutputDirResolved = Join-Path $script:Root 'output' } else { $script:OutputDirResolved = $OutputDir }
    New-Item -ItemType Directory -Force -Path $script:WorkDirResolved, $script:OutputDirResolved | Out-Null
    $work = (Resolve-Path $script:WorkDirResolved).Path
    $output = (Resolve-Path $script:OutputDirResolved).Path

    if ($List) { Show-Versions; return }
    if ($Clean) {
        Write-Info "this removes $work and $output"
        if (Confirm-Action 'Delete them?') {
            Remove-Item -Recurse -Force $work, $output -ErrorAction SilentlyContinue
            Write-Ok 'clean'
        }
        return
    }

    $hostArch = Get-HostArch
    $targetArch = if ($Arch) { $Arch } else { $hostArch }
    Write-Host ("Aseprite build script {0}  (windows-{1} -> {2})" -f $script:Version_, $hostArch, $targetArch) -ForegroundColor White

    if ($work.Length -gt 60) {
        Write-Warn "the work directory path is long ($($work.Length) characters); if the build fails with path errors use -WorkDir C:\asebuild"
    }

    if ($InstallDeps) { Install-Dependencies $targetArch $hostArch }

    Write-Step 'Checking build requirements'
    $vs = Find-VisualStudio $targetArch
    if (-not $vs) {
        $hint = if ($targetArch -eq 'arm64') { '"MSVC ARM64 build tools" and "C++ Clang tools for Windows"' } else { 'the "Desktop development with C++" workload' }
        Stop-Build "Visual Studio 2022 (or Build Tools) with $hint was not found. Run with -InstallDeps or install it from https://visualstudio.microsoft.com/downloads/"
    }
    Write-Info "visual studio  $vs"
    Import-VsEnvironment $vs $targetArch $hostArch
    $toolsDir = Join-Path $work 'tools'
    $cmake = Resolve-Tool 'cmake' '3.20' $hostArch $toolsDir
    $ninja = Resolve-Tool 'ninja' '1.10' $hostArch $toolsDir
    Write-Info "cmake          $cmake"
    Write-Info "ninja          $ninja"

    $drive = [IO.Path]::GetPathRoot($work)
    $freeGb = [math]::Floor((Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -eq $drive } | Select-Object -First 1).Free / 1GB)
    $needed = if ($SkiaFromSource -or $targetArch -eq 'arm64') { 12 } else { 6 }
    Write-Info "free space     $freeGb GB on $drive"
    if ($freeGb -lt $needed) {
        Write-Warn "about $needed GB of free space are recommended"
        if (-not (Confirm-Action 'Continue anyway?')) { Stop-Build 'aborted by user' }
    }
    Write-Ok 'all requirements satisfied'
    Close-Step

    $release = Resolve-AsepriteRelease $Version
    $source = Get-AsepriteSources $release $work
    Repair-Sources $source
    $skia = Get-Skia $source $targetArch $work $ninja $vs
    $bin = Build-Aseprite $source $skia $targetArch $work $cmake $ninja ([bool]$release.Url) $release.Tag
    $name = New-Package $bin $source $release.Tag $targetArch $skia.Tag $output

    Write-Host ''
    Write-Host 'Build completed' -ForegroundColor Green
    Write-Host "  Version   $($release.Tag)"
    Write-Host "  Target    windows-$targetArch"
    Write-Host "  Output    $(Join-Path $output $name)"
    Write-Host "  Run       $(Join-Path $output "$name\aseprite.exe")"
    Write-Host ''
    Write-Host 'Personal use only. Redistribution is prohibited by the Aseprite EULA.' -ForegroundColor DarkGray

    if ($script:InCI -and $env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "version=$($release.Tag)", "package=$name", "output_dir=$output" -Encoding UTF8
    }
}

try {
    Main
} catch {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    if ($VerbosePreference -eq 'Continue') { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    exit 1
}
