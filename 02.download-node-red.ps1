param(
    [switch]$Force,
    [string]$NodeRed3Spec = '^3',
    [string]$NodeRed4Spec = '^4',
    [switch]$UseProxyEnv,
    [string]$MirrorProfile,
    [string]$NpmRegistry
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgDir = [System.IO.Path]::GetFullPath((Join-Path $scriptDir 'pkg'))

function Write-Title {
    param([string]$Text)
    Write-Host "`n========================================" -ForegroundColor Yellow
    Write-Host " $Text" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Remove-IfExists {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-IsInteractiveHost {
    try {
        return [Environment]::UserInteractive -and $Host.Name -ne 'ServerRemoteHost'
    } catch {
        return $false
    }
}

function Normalize-BaseUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }
    return $Url.Trim().TrimEnd('/')
}

function Resolve-NpmMirrorConfig {
    param(
        [string]$Profile,
        [string]$CustomNpmRegistry
    )

    $normalizedProfile = if ([string]::IsNullOrWhiteSpace($Profile)) { '' } else { $Profile.Trim().ToLowerInvariant() }

    switch ($normalizedProfile) {
        '1' { $normalizedProfile = 'official' }
        '2' { $normalizedProfile = 'taobao' }
        '3' { $normalizedProfile = 'custom' }
        'official' { }
        'taobao' { }
        'npmmirror' { $normalizedProfile = 'taobao' }
        'custom' { }
        '' { }
        default { throw "Unsupported MirrorProfile: $Profile" }
    }

    if ([string]::IsNullOrWhiteSpace($normalizedProfile) -and -not [string]::IsNullOrWhiteSpace($CustomNpmRegistry)) {
        $normalizedProfile = 'custom'
    }

    if ([string]::IsNullOrWhiteSpace($normalizedProfile) -and (Test-IsInteractiveHost)) {
        Write-Title 'Select npm Mirror'
        Write-Host '  1. Official: registry.npmjs.org' -ForegroundColor White
        Write-Host '  2. TaoBao/npmmirror: registry.npmmirror.com' -ForegroundColor White
        Write-Host '  3. Custom registry' -ForegroundColor White

        do {
            $answer = Read-Host 'Choose mirror [1/2/3] (default 1)'
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = '1' }
        } until ($answer -in @('1', '2', '3'))

        $normalizedProfile = switch ($answer) {
            '1' { 'official' }
            '2' { 'taobao' }
            '3' { 'custom' }
        }

        if ($normalizedProfile -eq 'custom') {
            $CustomNpmRegistry = Read-Host 'Input npm registry (example: https://registry.npmjs.org/)'
        }
    }

    if ([string]::IsNullOrWhiteSpace($normalizedProfile)) {
        $normalizedProfile = 'official'
    }

    switch ($normalizedProfile) {
        'official' { return 'https://registry.npmjs.org/' }
        'taobao' { return 'https://registry.npmmirror.com/' }
        'custom' {
            $normalizedRegistry = Normalize-BaseUrl -Url $CustomNpmRegistry
            if ([string]::IsNullOrWhiteSpace($normalizedRegistry)) {
                throw 'Custom registry requires -NpmRegistry.'
            }
            return $normalizedRegistry + '/'
        }
    }
}

function Save-NetworkEnv {
    return @{
        ALL_PROXY       = $env:ALL_PROXY
        HTTP_PROXY      = $env:HTTP_PROXY
        HTTPS_PROXY     = $env:HTTPS_PROXY
        NO_PROXY        = $env:NO_PROXY
        GIT_HTTP_PROXY  = $env:GIT_HTTP_PROXY
        GIT_HTTPS_PROXY = $env:GIT_HTTPS_PROXY
    }
}

function Restore-NetworkEnv {
    param([hashtable]$State)
    foreach ($key in @('ALL_PROXY', 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'GIT_HTTP_PROXY', 'GIT_HTTPS_PROXY')) {
        if ($null -eq $State[$key]) {
            Remove-Item -Path ("Env:{0}" -f $key) -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path ("Env:{0}" -f $key) -Value $State[$key]
        }
    }
}

function Clear-NetworkEnv {
    $env:ALL_PROXY = $null
    $env:HTTP_PROXY = $null
    $env:HTTPS_PROXY = $null
    $env:NO_PROXY = $null
    $env:GIT_HTTP_PROXY = $null
    $env:GIT_HTTPS_PROXY = $null
}

function Test-FileReady {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    return (Get-Item -LiteralPath $Path).Length -gt 0
}

function Get-FileSizeMB {
    param([string]$Path)
    return [math]::Round((Get-Item -LiteralPath $Path).Length / 1MB, 2)
}

function Get-AvailableNodePackages {
    $files = Get-ChildItem -LiteralPath $pkgDir -Filter 'node-v*-win-x64.zip' -ErrorAction SilentlyContinue
    $result = @()
    foreach ($f in $files) {
        if ($f.Name -match '^node-v(\d+\.\d+\.\d+)-win-x64\.zip$') {
            $version = $matches[1]
            $major = [int]($version.Split('.')[0])
            $result += [PSCustomObject]@{
                Name    = $f.Name
                Path    = $f.FullName
                Version = $version
                Major   = $major
            }
        }
    }
    return $result | Sort-Object Major, Version
}

function Select-NodePackage {
    param(
        [PSCustomObject[]]$Packages,
        [int[]]$PreferredMajors
    )

    foreach ($major in $PreferredMajors) {
        $candidate = $Packages | Where-Object { $_.Major -eq $major } | Select-Object -First 1
        if ($candidate) {
            return $candidate
        }
    }
    return $null
}

function Expand-NodeToolchain {
    param(
        [string]$ZipPath,
        [string]$WorkRoot
    )

    $extractRoot = Join-Path $WorkRoot ([System.IO.Path]::GetFileNameWithoutExtension($ZipPath))
    Remove-IfExists -Path $extractRoot
    Ensure-Dir -Path $extractRoot

    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractRoot -Force
    $inner = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
    if (-not $inner) {
        throw "Invalid Node.js zip layout: $ZipPath"
    }

    $nodeExe = Join-Path $inner.FullName 'node.exe'
    $npmCmd = Join-Path $inner.FullName 'npm.cmd'
    $npmCli = Join-Path $inner.FullName 'node_modules\npm\bin\npm-cli.js'

    if (-not (Test-Path -LiteralPath $nodeExe)) {
        throw "node.exe not found in $ZipPath"
    }

    return [PSCustomObject]@{
        RootDir = $inner.FullName
        NodeExe = $nodeExe
        NpmCmd  = $npmCmd
        NpmCli  = $npmCli
    }
}

function Invoke-NpmInstall {
    param(
        [string]$WorkingDirectory,
        [string]$PackageSpec,
        [pscustomobject]$Toolchain,
        [string]$Registry
    )

    $cmdArgs = @(
        'install',
        "node-red@$PackageSpec",
        '--omit=dev',
        '--omit=optional',
        '--no-audit',
        '--fund=false',
        "--registry=$Registry",
        '--cache',
        (Join-Path $WorkingDirectory '.npm-cache'),
        '--prefer-online',
        '--offline=false'
    )

    $oldRegistry = $env:NPM_CONFIG_REGISTRY
    $oldOffline = $env:NPM_CONFIG_OFFLINE
    $oldPreferOffline = $env:NPM_CONFIG_PREFER_OFFLINE
    $oldPreferOnline = $env:NPM_CONFIG_PREFER_ONLINE
    $oldCache = $env:NPM_CONFIG_CACHE
    $networkEnv = Save-NetworkEnv

    $env:NPM_CONFIG_REGISTRY = $Registry
    $env:NPM_CONFIG_OFFLINE = 'false'
    $env:NPM_CONFIG_PREFER_OFFLINE = 'false'
    $env:NPM_CONFIG_PREFER_ONLINE = 'true'
    $env:NPM_CONFIG_CACHE = Join-Path $WorkingDirectory '.npm-cache'

    try {
        if (-not $UseProxyEnv) {
            Clear-NetworkEnv
        }

        if (Test-Path -LiteralPath $Toolchain.NpmCmd) {
            & $Toolchain.NpmCmd @cmdArgs
            return
        }

        if (Test-Path -LiteralPath $Toolchain.NpmCli) {
            & $Toolchain.NodeExe $Toolchain.NpmCli @cmdArgs
            return
        }

        throw "npm was not found in extracted toolchain: $($Toolchain.RootDir)"
    } finally {
        $env:NPM_CONFIG_REGISTRY = $oldRegistry
        $env:NPM_CONFIG_OFFLINE = $oldOffline
        $env:NPM_CONFIG_PREFER_OFFLINE = $oldPreferOffline
        $env:NPM_CONFIG_PREFER_ONLINE = $oldPreferOnline
        $env:NPM_CONFIG_CACHE = $oldCache
        Restore-NetworkEnv -State $networkEnv
    }
}

function New-NodeRedPackage {
    param(
        [string]$ZipName,
        [string]$PackageSpec,
        [string]$Registry,
        [pscustomobject]$Toolchain
    )

    $zipPath = Join-Path $pkgDir $ZipName
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('nr-pkg-' + [Guid]::NewGuid().ToString('N'))
    $pushedLocation = $false

    if ((-not $Force) -and (Test-FileReady -Path $zipPath)) {
        Write-Host "  [SKIP] $ZipName ($(Get-FileSizeMB -Path $zipPath) MB)" -ForegroundColor Green
        return
    }

    Remove-IfExists -Path $zipPath
    Remove-IfExists -Path $tempDir
    Ensure-Dir -Path $tempDir

    try {
        Push-Location $tempDir
        $pushedLocation = $true

        Set-Content -LiteralPath (Join-Path $tempDir 'package.json') -Encoding ASCII -Value @'
{
  "name": "nr-offline-package",
  "private": true,
  "version": "0.0.0"
}
'@

        Write-Host "  [npm install] node-red@$PackageSpec" -ForegroundColor Gray
        Write-Host "               registry: $Registry" -ForegroundColor DarkGray
        Write-Host "               node.exe : $($Toolchain.NodeExe)" -ForegroundColor DarkGray
        Invoke-NpmInstall -WorkingDirectory $tempDir -PackageSpec $PackageSpec -Toolchain $Toolchain -Registry $Registry

        if ($LASTEXITCODE -ne 0) {
            throw "npm install exited with code $LASTEXITCODE"
        }

        $redJs = Join-Path $tempDir 'node_modules\node-red\red.js'
        $nrPkg = Join-Path $tempDir 'node_modules\node-red\package.json'

        if (-not (Test-Path -LiteralPath $redJs)) {
            throw 'node_modules\node-red\red.js not found'
        }
        if (-not (Test-Path -LiteralPath $nrPkg)) {
            throw 'node_modules\node-red\package.json not found'
        }

        $nrVer = (Get-Content -Raw -LiteralPath $nrPkg | ConvertFrom-Json).version

        Remove-IfExists -Path (Join-Path $tempDir '.npmrc')
        Remove-IfExists -Path (Join-Path $tempDir 'package-lock.json')
        Remove-IfExists -Path (Join-Path $tempDir '.npm-cache')

        Write-Host "  [COMPRESS] creating $ZipName" -ForegroundColor Gray
        Compress-Archive -Path (Join-Path $tempDir '*') -DestinationPath $zipPath -Force

        if (-not (Test-FileReady -Path $zipPath)) {
            throw 'compressed zip is empty'
        }

        Write-Host "  [OK] $ZipName (Node-RED v$nrVer, $(Get-FileSizeMB -Path $zipPath) MB)" -ForegroundColor Green
    } catch {
        Remove-IfExists -Path $zipPath
        Write-Host "  [FAIL] $ZipName : $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        if ($pushedLocation) {
            Pop-Location
        }
        Remove-IfExists -Path $tempDir
    }
}

Ensure-Dir -Path $pkgDir
Get-ChildItem -LiteralPath $pkgDir -Filter '*.zip' -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -eq 0 } |
    ForEach-Object { Remove-IfExists -Path $_.FullName }

$nodePackages = Get-AvailableNodePackages
if ($nodePackages.Count -eq 0) {
    Write-Host 'pkg directory does not contain any Node.js zip package.' -ForegroundColor Red
    Write-Host 'Please run .\01.download-nodejs.ps1 first.' -ForegroundColor Yellow
    exit 1
}

$nr3Node = Select-NodePackage -Packages $nodePackages -PreferredMajors @(16, 14)
$nr4Node = Select-NodePackage -Packages $nodePackages -PreferredMajors @(22, 20, 18)

if (-not $nr3Node) {
    Write-Host 'Missing compatible Node.js package for Node-RED 3.x. Need Node 16 or 14.' -ForegroundColor Red
    Write-Host 'Please run .\01.download-nodejs.ps1 first.' -ForegroundColor Yellow
    exit 1
}
if (-not $nr4Node) {
    Write-Host 'Missing compatible Node.js package for Node-RED 4.x. Need Node 22, 20 or 18.' -ForegroundColor Red
    Write-Host 'Please run .\01.download-nodejs.ps1 first.' -ForegroundColor Yellow
    exit 1
}

$registry = Resolve-NpmMirrorConfig -Profile $MirrorProfile -CustomNpmRegistry $NpmRegistry
$toolchainRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('nr-node-toolchains-' + [Guid]::NewGuid().ToString('N'))
Ensure-Dir -Path $toolchainRoot

try {
    Write-Host "Download directory: $pkgDir" -ForegroundColor Cyan
    Write-Host "npm registry      : $registry" -ForegroundColor Cyan
    Write-Host "NR3 Node.js       : $($nr3Node.Name)" -ForegroundColor Cyan
    Write-Host "NR4 Node.js       : $($nr4Node.Name)" -ForegroundColor Cyan

    Write-Title 'Preparing Node.js toolchains'
    $nr3Toolchain = Expand-NodeToolchain -ZipPath $nr3Node.Path -WorkRoot $toolchainRoot
    if ($nr4Node.Path -eq $nr3Node.Path) {
        $nr4Toolchain = $nr3Toolchain
    } else {
        $nr4Toolchain = Expand-NodeToolchain -ZipPath $nr4Node.Path -WorkRoot $toolchainRoot
    }

    Write-Title 'Creating Node-RED 3.x package'
    New-NodeRedPackage -ZipName 'node-red-3.x.zip' -PackageSpec $NodeRed3Spec -Registry $registry -Toolchain $nr3Toolchain

    Write-Title 'Creating Node-RED 4.x package'
    New-NodeRedPackage -ZipName 'node-red-4.x.zip' -PackageSpec $NodeRed4Spec -Registry $registry -Toolchain $nr4Toolchain

    Write-Title 'Node-RED Package Summary'
    Get-ChildItem -LiteralPath $pkgDir -Filter 'node-red-*.zip' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        Write-Host "  $($_.Name) - $([math]::Round($_.Length / 1MB, 2)) MB" -ForegroundColor White
    }

    Write-Host "`nDone. Offline packages are ready in pkg\" -ForegroundColor Green
} finally {
    Remove-IfExists -Path $toolchainRoot
}
