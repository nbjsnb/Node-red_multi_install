param(
    [switch]$Install,
    [switch]$ListPkg,
    [string]$InstallRoot,
    [switch]$Force,
    [string]$Nr3Version,
    [string]$Nr4Version
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgDir = Join-Path $scriptDir 'pkg'

function Write-Title {
    param([string]$Text)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Test-IsInteractiveHost {
    try {
        return [Environment]::UserInteractive -and $Host.Name -ne 'ServerRemoteHost'
    } catch {
        return $false
    }
}

function Write-Info {
    param([string]$Text)
    Write-Host "  [INFO] $Text" -ForegroundColor Gray
}

function Write-OK {
    param([string]$Text)
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  [WARN] $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Text)
    Write-Host "  [FAIL] $Text" -ForegroundColor Red
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-InstallRootPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [System.IO.Path]::GetFullPath($script:scriptDir)
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $script:scriptDir $Path))
}

function Remove-DirIfExists {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-FileAscii {
    param(
        [string]$Path,
        [string]$Content
    )
    Set-Content -LiteralPath $Path -Value $Content -Encoding ASCII
}

function Get-VersionFromNodeZipName {
    param([string]$FileName)
    if ($FileName -match '^node-v(\d+\.\d+\.\d+)-win-x64\.zip$') {
        return $matches[1]
    }
    return $null
}

function Get-AvailableNodePackages {
    $files = Get-ChildItem -LiteralPath $pkgDir -Filter 'node-v*-win-x64.zip' -ErrorAction SilentlyContinue
    $result = @()

    foreach ($file in $files) {
        $version = Get-VersionFromNodeZipName -FileName $file.Name
        if ($version) {
            $major = [int]($version.Split('.')[0])
            $result += [PSCustomObject]@{
                FileName = $file.Name
                FilePath = $file.FullName
                Version  = $version
                Major    = $major
            }
        }
    }

    return $result | Sort-Object Major, Version
}

function Get-AvailableNodeRedPackages {
    $files = Get-ChildItem -LiteralPath $pkgDir -Filter 'node-red-*.zip' -ErrorAction SilentlyContinue
    $result = @()

    foreach ($file in $files) {
        if ($file.Name -match '^node-red-(\d+)\.x\.zip$') {
            $major = [int]$matches[1]
            $result += [PSCustomObject]@{
                FileName = $file.Name
                FilePath = $file.FullName
                Major    = $major
                Tag      = "$major.x"
            }
        }
    }

    return $result | Sort-Object Major
}

function Get-PreferredNodeMajors {
    param([int]$NrMajor)

    switch ($NrMajor) {
        3 { return @(16, 14) }
        4 { return @(22, 20, 18) }
        default { return @() }
    }
}

function Resolve-RequestedNodePackage {
    param(
        [PSCustomObject[]]$Packages,
        [int]$NrMajor,
        [string]$RequestedVersion
    )

    $compatibleMajors = Get-PreferredNodeMajors -NrMajor $NrMajor
    if ([string]::IsNullOrWhiteSpace($RequestedVersion)) {
        foreach ($major in $compatibleMajors) {
            $candidate = $Packages | Where-Object { $_.Major -eq $major } | Select-Object -First 1
            if ($candidate) {
                return $candidate
            }
        }
        return $null
    }

    $normalized = $RequestedVersion.Trim()

    $exactFile = $Packages | Where-Object { $_.FileName -ieq $normalized } | Select-Object -First 1
    if ($exactFile) {
        return $exactFile
    }

    $exactVersion = $Packages | Where-Object { $_.Version -eq $normalized } | Select-Object -First 1
    if ($exactVersion) {
        return $exactVersion
    }

    if ($normalized -match '^\d+$') {
        $majorCandidate = $Packages | Where-Object { $_.Major -eq [int]$normalized } | Select-Object -First 1
        if ($majorCandidate) {
            return $majorCandidate
        }
    }

    throw "Requested NR$NrMajor Node.js package not found: $RequestedVersion"
}

function Install-PortableNode {
    param(
        [string]$Root,
        [string]$TargetDirName,
        [string]$NodeZipPath,
        [switch]$ForceInstall
    )

    $targetDir = Join-Path $Root $TargetDirName
    $nodeExe = Join-Path $targetDir 'node.exe'

    if ((-not $ForceInstall) -and (Test-Path -LiteralPath $nodeExe)) {
        try {
            $installedVersion = (& $nodeExe -v).Trim()
            Write-OK "$TargetDirName already exists ($installedVersion), skipping"
            return
        } catch {
            Write-Warn "$TargetDirName exists but node.exe is not usable, reinstalling"
        }
    }

    if (-not (Test-Path -LiteralPath $NodeZipPath)) {
        throw "Node.js zip not found: $NodeZipPath"
    }

    Write-Title "Install Node.js -> $TargetDirName"

    $cacheDir = Join-Path $Root '.cache'
    $extractRoot = Join-Path $cacheDir ('extract-' + [System.IO.Path]::GetFileNameWithoutExtension($NodeZipPath))
    Ensure-Dir -Path $cacheDir
    Remove-DirIfExists -Path $extractRoot
    Ensure-Dir -Path $extractRoot

    Write-Info "Extracting $NodeZipPath"
    Expand-Archive -LiteralPath $NodeZipPath -DestinationPath $extractRoot -Force

    $inner = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
    if (-not $inner) {
        throw "Unexpected Node.js zip layout: $NodeZipPath"
    }

    Remove-DirIfExists -Path $targetDir
    Ensure-Dir -Path $targetDir
    Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $targetDir -Recurse -Force

    if (-not (Test-Path -LiteralPath $nodeExe)) {
        throw "Install verification failed: missing $nodeExe"
    }

    Write-OK "$TargetDirName installed"
}

function Install-NodeRed {
    param(
        [string]$Root,
        [string]$TargetDirName,
        [string]$NodeRedZipPath,
        [switch]$ForceInstall
    )

    $targetDir = Join-Path $Root $TargetDirName
    $redJs = Join-Path $targetDir 'node_modules\node-red\red.js'

    if ((-not $ForceInstall) -and (Test-Path -LiteralPath $redJs)) {
        Write-OK "$TargetDirName already exists, skipping"
        return
    }

    if (-not (Test-Path -LiteralPath $NodeRedZipPath)) {
        throw "Node-RED zip not found: $NodeRedZipPath"
    }

    Write-Title "Install Node-RED -> $TargetDirName"
    Remove-DirIfExists -Path $targetDir
    Ensure-Dir -Path $targetDir

    Write-Info "Extracting $NodeRedZipPath"
    Expand-Archive -LiteralPath $NodeRedZipPath -DestinationPath $targetDir -Force

    if (-not (Test-Path -LiteralPath $redJs)) {
        throw "Install verification failed: missing $redJs"
    }

    Write-OK "$TargetDirName installed"
}

function Generate-LauncherCmd {
    param(
        [string]$Root,
        [string]$NodeRedDirName,
        [string]$CmdName,
        [string]$NodeDirName
    )

    $cmdPath = Join-Path (Join-Path $Root $NodeRedDirName) $CmdName
    $content = @"
@echo off
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "NODE=%ROOT%\$NodeDirName\node.exe"
set "RED_JS=%~dp0node_modules\node-red\red.js"

if not exist "%NODE%" (
  echo Missing Node.js runtime: %NODE%
  exit /b 2
)

if not exist "%RED_JS%" (
  echo Missing Node-RED entry: %RED_JS%
  exit /b 3
)

"%NODE%" "%RED_JS%" %*
endlocal
"@

    Write-FileAscii -Path $cmdPath -Content $content
    Write-OK "Generated launcher: $NodeRedDirName\$CmdName"
}

function Generate-EnvStartScript {
    param([string]$Root)

    $path = Join-Path $Root 'start-nr.bat'
    $content = @"
@echo off
setlocal

set "ARG_VERSION=%~1"
set "ARG_PORT=%~2"

if not "%ARG_VERSION%"=="" (
  set "NR_VERSION=%ARG_VERSION%"
)

if not "%ARG_PORT%"=="" (
  set "NR_PORT=%ARG_PORT%"
)

if "%NR_VERSION%"=="" (
  echo Usage:
  echo   %~nx0 3 1880
  echo   %~nx0 4 1990
  echo.
  echo Legacy environment variable mode is also supported:
  echo   set NR_VERSION=3
  echo   set NR_PORT=1880
  echo   %~nx0
  exit /b 1
)

if "%NR_PORT%"=="" (
  echo Missing port. Example:
  echo   %~nx0 3 1880
  exit /b 2
)

set "ROOT=%~dp0"
for %%I in ("%ROOT%.") do set "ROOT=%%~fI"

if "%NR_VERSION%"=="3" (
  set "NR_CMD=%ROOT%\node-red3.x\node-red3.cmd"
  set "USERDIR=%ROOT%\prj\nr3-%NR_PORT%"
) else if "%NR_VERSION%"=="4" (
  set "NR_CMD=%ROOT%\node-red4.x\node-red4.cmd"
  set "USERDIR=%ROOT%\prj\nr4-%NR_PORT%"
) else (
  echo Unsupported NR_VERSION: %NR_VERSION%
  echo Supported values: 3, 4
  exit /b 3
)

if not exist "%NR_CMD%" (
  echo Missing launcher: %NR_CMD%
  echo Run 03.install-offline.ps1 -Install first
  exit /b 4
)

if not exist "%USERDIR%" mkdir "%USERDIR%"

echo ========================================
echo Version : %NR_VERSION%
echo Port    : %NR_PORT%
echo userDir : %USERDIR%
echo ========================================
call "%NR_CMD%" --userDir "%USERDIR%" --port %NR_PORT%
endlocal
"@

    Write-FileAscii -Path $path -Content $content
    Write-OK 'Generated start-nr.bat'
}

function Get-InstalledNodeRedVersion {
    param(
        [string]$Root,
        [string]$NodeRedDirName
    )

    $packageJson = Join-Path $Root "$NodeRedDirName\node_modules\node-red\package.json"
    if (-not (Test-Path -LiteralPath $packageJson)) {
        return $null
    }

    return (Get-Content -Raw -LiteralPath $packageJson | ConvertFrom-Json).version
}

function Show-PkgList {
    Write-Title 'Available Packages In pkg'

    $nodePkgs = Get-AvailableNodePackages
    if ($nodePkgs.Count -eq 0) {
        Write-Warn 'No Node.js package found (pkg\node-v*-win-x64.zip)'
    } else {
        Write-Host 'Node.js packages:' -ForegroundColor Yellow
        foreach ($pkg in $nodePkgs) {
            Write-Host "  [Node $($pkg.Major)] $($pkg.FileName) -> v$($pkg.Version)" -ForegroundColor Gray
        }
    }

    $nrPkgs = Get-AvailableNodeRedPackages
    if ($nrPkgs.Count -eq 0) {
        Write-Warn 'No Node-RED package found (pkg\node-red-*.zip)'
    } else {
        Write-Host "`nNode-RED packages:" -ForegroundColor Yellow
        foreach ($pkg in $nrPkgs) {
            Write-Host "  [NR $($pkg.Major)] $($pkg.FileName)" -ForegroundColor Gray
        }
    }

    Write-Host "`nCompatibility:" -ForegroundColor Yellow
    Write-Host '  NR 3.x -> Node.js 14 or 16'
    Write-Host '  NR 4.x -> Node.js 18, 20 or 22'
}

function Read-Choice {
    param(
        [string]$Prompt,
        [string[]]$ValidChoices,
        [string]$DefaultChoice
    )

    do {
        $suffix = if ([string]::IsNullOrWhiteSpace($DefaultChoice)) { '' } else { " (default $DefaultChoice)" }
        $answer = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            $answer = $DefaultChoice
        }
    } until ($answer -in $ValidChoices)

    return $answer
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultValue = $false
    )

    $defaultChoice = if ($DefaultValue) { 'Y' } else { 'N' }
    $answer = Read-Choice -Prompt "$Prompt [Y/N]" -ValidChoices @('Y', 'N', 'y', 'n') -DefaultChoice $defaultChoice
    return $answer.ToUpperInvariant() -eq 'Y'
}

function Read-OptionalText {
    param(
        [string]$Prompt,
        [string]$DefaultValue = ''
    )

    $suffix = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { '' } else { " (default: $DefaultValue)" }
    $answer = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultValue
    }
    return $answer.Trim()
}

function Invoke-InteractiveMode {
    Write-Title 'Interactive Menu'
    Write-Host '  1. List pkg packages'
    Write-Host '  2. Install offline packages'
    Write-Host '  3. Exit'

    $mode = Read-Choice -Prompt 'Choose action [1/2/3]' -ValidChoices @('1', '2', '3') -DefaultChoice '2'

    switch ($mode) {
        '1' {
            Show-PkgList
            return
        }
        '2' {
            Show-PkgList

            $customInstallRoot = Read-OptionalText -Prompt 'Install root directory (relative paths are based on script directory)' -DefaultValue $script:InstallRoot
            if (-not [string]::IsNullOrWhiteSpace($customInstallRoot)) {
                $script:InstallRoot = Resolve-InstallRootPath -Path $customInstallRoot
            }

            Write-Info "Resolved install root: $script:InstallRoot"

            $script:Force = Read-YesNo -Prompt 'Force reinstall existing directories?' -DefaultValue:$script:Force

            if (Read-YesNo -Prompt 'Manually choose Node.js package for NR3?' -DefaultValue:$false) {
                $script:Nr3Version = Read-OptionalText -Prompt 'NR3 Node.js version/package (example: 16 or node-v16.20.2-win-x64.zip)'
            }

            if (Read-YesNo -Prompt 'Manually choose Node.js package for NR4?' -DefaultValue:$false) {
                $script:Nr4Version = Read-OptionalText -Prompt 'NR4 Node.js version/package (example: 22 or node-v22.22.2-win-x64.zip)'
            }

            Invoke-Install
            return
        }
        '3' {
            return
        }
    }
}

$InstallRoot = Resolve-InstallRootPath -Path $InstallRoot

function Invoke-Install {
    Write-Title 'Offline Install'

    if (-not (Test-Path -LiteralPath $pkgDir)) {
        throw "pkg directory not found: $pkgDir"
    }

    $nodePkgs = Get-AvailableNodePackages
    $nrPkgs = Get-AvailableNodeRedPackages

    if ($nodePkgs.Count -eq 0) {
        throw "No Node.js package found in pkg. Run .\01.download-nodejs.ps1 first."
    }
    if ($nrPkgs.Count -eq 0) {
        throw "No Node-RED package found in pkg. Run .\02.download-node-red.ps1 first."
    }

    Ensure-Dir -Path $InstallRoot
    Ensure-Dir -Path (Join-Path $InstallRoot 'prj')
    Ensure-Dir -Path (Join-Path $InstallRoot '.cache')

    $nr3Pkg = $nrPkgs | Where-Object { $_.Major -eq 3 } | Select-Object -First 1
    $nr4Pkg = $nrPkgs | Where-Object { $_.Major -eq 4 } | Select-Object -First 1

    if (-not $nr3Pkg -and -not $nr4Pkg) {
        throw 'pkg does not contain node-red-3.x.zip or node-red-4.x.zip'
    }

    if ($nr3Pkg) {
        $nr3Node = Resolve-RequestedNodePackage -Packages $nodePkgs -NrMajor 3 -RequestedVersion $Nr3Version
        if (-not $nr3Node) {
            Write-Warn 'Skipping NR3 install because no compatible Node.js package was found'
        } else {
            Write-Info "NR3 -> $($nr3Node.FileName)"
            Install-PortableNode -Root $InstallRoot -TargetDirName ("nodejs{0}" -f $nr3Node.Major) -NodeZipPath $nr3Node.FilePath -ForceInstall:$Force
            Install-NodeRed -Root $InstallRoot -TargetDirName 'node-red3.x' -NodeRedZipPath $nr3Pkg.FilePath -ForceInstall:$Force
            Generate-LauncherCmd -Root $InstallRoot -NodeRedDirName 'node-red3.x' -CmdName 'node-red3.cmd' -NodeDirName ("nodejs{0}" -f $nr3Node.Major)
        }
    }

    if ($nr4Pkg) {
        $nr4Node = Resolve-RequestedNodePackage -Packages $nodePkgs -NrMajor 4 -RequestedVersion $Nr4Version
        if (-not $nr4Node) {
            Write-Warn 'Skipping NR4 install because no compatible Node.js package was found'
        } else {
            Write-Info "NR4 -> $($nr4Node.FileName)"
            Install-PortableNode -Root $InstallRoot -TargetDirName ("nodejs{0}" -f $nr4Node.Major) -NodeZipPath $nr4Node.FilePath -ForceInstall:$Force
            Install-NodeRed -Root $InstallRoot -TargetDirName 'node-red4.x' -NodeRedZipPath $nr4Pkg.FilePath -ForceInstall:$Force
            Generate-LauncherCmd -Root $InstallRoot -NodeRedDirName 'node-red4.x' -CmdName 'node-red4.cmd' -NodeDirName ("nodejs{0}" -f $nr4Node.Major)
        }
    }

    Generate-EnvStartScript -Root $InstallRoot

    $nr3Installed = Test-Path -LiteralPath (Join-Path $InstallRoot 'node-red3.x\node_modules\node-red\red.js')
    $nr4Installed = Test-Path -LiteralPath (Join-Path $InstallRoot 'node-red4.x\node_modules\node-red\red.js')

    $summary = [ordered]@{
        installRoot = $InstallRoot
        nr3 = $null
        nr4 = $null
    }

    if ($nr3Installed) {
        $summary.nr3 = [ordered]@{
            nodeRedVersion = Get-InstalledNodeRedVersion -Root $InstallRoot -NodeRedDirName 'node-red3.x'
            startCommand   = '.\start-nr.bat 3 1880'
        }
    }

    if ($nr4Installed) {
        $summary.nr4 = [ordered]@{
            nodeRedVersion = Get-InstalledNodeRedVersion -Root $InstallRoot -NodeRedDirName 'node-red4.x'
            startCommand   = '.\start-nr.bat 4 1990'
        }
    }

    $summaryPath = Join-Path $InstallRoot 'node-red-multi-install-result.json'
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

    Write-Title 'Install Complete'
    Write-Host "Install root: $InstallRoot" -ForegroundColor Green

    if ($summary.nr3) {
        Write-Host "NR3 ($($summary.nr3.nodeRedVersion)) -> .\start-nr.bat 3 1880" -ForegroundColor White
    }
    if ($summary.nr4) {
        Write-Host "NR4 ($($summary.nr4.nodeRedVersion)) -> .\start-nr.bat 4 1990" -ForegroundColor White
    }

    Write-Host "Summary file: $summaryPath" -ForegroundColor Gray
}

$modeCount = @($Install, $ListPkg).Where({ $_ -eq $true }).Count
if ($modeCount -gt 1) {
    throw 'Use only one mode: -Install or -ListPkg'
}

if ($modeCount -eq 0) {
    if (Test-IsInteractiveHost) {
        Invoke-InteractiveMode
        exit 0
    }

    Write-Host @"

Node-RED Offline Installer
==========================

Usage:
  .\03.install-offline.ps1 -ListPkg
  .\03.install-offline.ps1 -Install [-InstallRoot D:\nr] [-Force]
  After install: .\start-nr.bat 3 1880

Compatibility:
  NR 3.x -> Node.js 14 or 16
  NR 4.x -> Node.js 18, 20 or 22

Optional:
  -Nr3Version 16
  -Nr4Version node-v22.22.2-win-x64.zip

"@
    exit 0
}

if ($ListPkg) {
    Show-PkgList
    exit 0
}

if ($Install) {
    Invoke-Install
    exit 0
}
