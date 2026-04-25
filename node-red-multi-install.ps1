param(
    [switch]$Install,
    [switch]$ListPkg,
    [string]$InstallRoot,
    [switch]$Force,
    [string]$Nr3Version,
    [string]$Nr4Version
)

& (Join-Path $PSScriptRoot '03.install-offline.ps1') @PSBoundParameters
