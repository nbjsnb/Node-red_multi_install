param(
    [switch]$Force,
    [switch]$UseProxyEnv,
    [string]$MirrorProfile,
    [string]$NodeMirrorBase
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgDir = [System.IO.Path]::GetFullPath((Join-Path $scriptDir 'pkg'))

$nodePackages = @(
    @{ Name = 'node-v14.21.3-win-x64.zip'; Version = '14.21.3'; Line = 'Node.js 14 LTS (EOL)' },
    @{ Name = 'node-v16.20.2-win-x64.zip'; Version = '16.20.2'; Line = 'Node.js 16 LTS (EOL)' },
    @{ Name = 'node-v18.20.4-win-x64.zip'; Version = '18.20.4'; Line = 'Node.js 18 LTS (EOL)' },
    @{ Name = 'node-v20.11.1-win-x64.zip'; Version = '20.11.1'; Line = 'Node.js 20 LTS (EOL as of 2026-04-25)' },
    @{ Name = 'node-v22.22.2-win-x64.zip'; Version = '22.22.2'; Line = 'Node.js 22 LTS' }
)

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

function Normalize-BaseUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }
    return $Url.Trim().TrimEnd('/')
}

function Test-IsInteractiveHost {
    try {
        return [Environment]::UserInteractive -and $Host.Name -ne 'ServerRemoteHost'
    } catch {
        return $false
    }
}

function Resolve-NodeMirrorConfig {
    param(
        [string]$Profile,
        [string]$CustomNodeMirrorBase
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

    if ([string]::IsNullOrWhiteSpace($normalizedProfile) -and -not [string]::IsNullOrWhiteSpace($CustomNodeMirrorBase)) {
        $normalizedProfile = 'custom'
    }

    if ([string]::IsNullOrWhiteSpace($normalizedProfile) -and (Test-IsInteractiveHost)) {
        Write-Title 'Select Node.js Mirror'
        Write-Host '  1. Official: nodejs.org' -ForegroundColor White
        Write-Host '  2. TaoBao/npmmirror' -ForegroundColor White
        Write-Host '  3. Custom mirror' -ForegroundColor White

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
            $CustomNodeMirrorBase = Read-Host 'Input Node.js mirror base (example: https://nodejs.org/dist)'
        }
    }

    if ([string]::IsNullOrWhiteSpace($normalizedProfile)) {
        $normalizedProfile = 'official'
    }

    switch ($normalizedProfile) {
        'official' {
            return [PSCustomObject]@{
                DisplayName    = 'Official'
                NodeMirrorBase = 'https://nodejs.org/dist'
            }
        }
        'taobao' {
            return [PSCustomObject]@{
                DisplayName    = 'TaoBao/npmmirror'
                NodeMirrorBase = 'https://npmmirror.com/mirrors/node'
            }
        }
        'custom' {
            $normalizedNodeMirror = Normalize-BaseUrl -Url $CustomNodeMirrorBase
            if ([string]::IsNullOrWhiteSpace($normalizedNodeMirror)) {
                throw 'Custom mirror requires -NodeMirrorBase.'
            }

            return [PSCustomObject]@{
                DisplayName    = 'Custom'
                NodeMirrorBase = $normalizedNodeMirror
            }
        }
    }
}

function Get-NodeDownloadUrl {
    param(
        [string]$BaseUrl,
        [string]$Version,
        [string]$Name
    )
    return ('{0}/v{1}/{2}' -f (Normalize-BaseUrl -Url $BaseUrl), $Version, $Name)
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

function Download-File {
    param(
        [string]$Name,
        [string]$Url,
        [string]$Label
    )

    $outPath = Join-Path $pkgDir $Name
    $tmpPath = "$outPath.partial"
    $networkEnv = Save-NetworkEnv

    if ((-not $Force) -and (Test-FileReady -Path $outPath)) {
        Write-Host "  [SKIP] $Name ($(Get-FileSizeMB -Path $outPath) MB)" -ForegroundColor Green
        return
    }

    Remove-IfExists -Path $tmpPath
    if ($Force) {
        Remove-IfExists -Path $outPath
    }

    Write-Host "  [DOWNLOAD] $Label" -ForegroundColor Cyan
    Write-Host "             $Url" -ForegroundColor DarkGray

    try {
        if (-not $UseProxyEnv) {
            Clear-NetworkEnv
        }

        try {
            Invoke-WebRequest -Uri $Url -OutFile $tmpPath -TimeoutSec 1800
        } catch {
            $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
            if (-not $curlCmd) {
                throw
            }

            Write-Host '  [RETRY] Invoke-WebRequest failed, retrying with curl.exe' -ForegroundColor DarkYellow
            & $curlCmd.Source '-L' '--fail' '--output' $tmpPath $Url
            if ($LASTEXITCODE -ne 0) {
                throw "curl.exe exited with code $LASTEXITCODE"
            }
        }

        if (-not (Test-FileReady -Path $tmpPath)) {
            throw 'downloaded file is empty'
        }

        Move-Item -LiteralPath $tmpPath -Destination $outPath -Force
        Write-Host "  [OK] $Name ($(Get-FileSizeMB -Path $outPath) MB)" -ForegroundColor Green
    } catch {
        Remove-IfExists -Path $tmpPath
        Remove-IfExists -Path $outPath
        Write-Host "  [FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Restore-NetworkEnv -State $networkEnv
    }
}

Ensure-Dir -Path $pkgDir
Get-ChildItem -LiteralPath $pkgDir -Filter '*.zip' -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -eq 0 } |
    ForEach-Object { Remove-IfExists -Path $_.FullName }

$mirror = Resolve-NodeMirrorConfig -Profile $MirrorProfile -CustomNodeMirrorBase $NodeMirrorBase

Write-Host "Download directory: $pkgDir" -ForegroundColor Cyan
Write-Host "Mirror profile    : $($mirror.DisplayName)" -ForegroundColor Cyan
Write-Host "Node.js mirror    : $($mirror.NodeMirrorBase)" -ForegroundColor Cyan

$step = 0
foreach ($pkg in $nodePackages) {
    $step++
    Write-Title "Step $step/$($nodePackages.Count): Downloading $($pkg.Name)"
    $nodeUrl = Get-NodeDownloadUrl -BaseUrl $mirror.NodeMirrorBase -Version $pkg.Version -Name $pkg.Name
    Download-File -Name $pkg.Name -Url $nodeUrl -Label $pkg.Line
}

Write-Title 'Node.js Download Summary'
Get-ChildItem -LiteralPath $pkgDir -Filter 'node-v*-win-x64.zip' | Sort-Object Name | ForEach-Object {
    Write-Host "  $($_.Name) - $([math]::Round($_.Length / 1MB, 2)) MB" -ForegroundColor White
}

Write-Host "`nDone. Next step: run .\02.download-node-red.ps1" -ForegroundColor Green
