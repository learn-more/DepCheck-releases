<#
.SYNOPSIS
    Renders site/ into _site with the current release baked in.

.DESCRIPTION
    The page used to read the GitHub API on every request from PHP. Pages is static, so the same data is filled in
    here instead, once per deploy. Everything the visitor sees is plain HTML: no API call from the browser, no
    unauthenticated rate limit, no blank page without JavaScript.

    Nothing here is required for a working download. The buttons fall back to the /releases/latest/download/
    redirect, which always points at the newest assets, so a failed or stale render costs the version, size and
    hash on the page and nothing else.

.PARAMETER Repo
    owner/name holding the releases. Defaults to the repository the workflow runs in.
#>
[CmdletBinding()]
param(
    [string]$Repo = $env:GITHUB_REPOSITORY,
    [string]$SiteDir = 'site',
    [string]$OutputDir = '_site'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# "no release yet" is a 404 from gh, and a fresh repository has one. Handled below, not thrown.
$PSNativeCommandUseErrorActionPreference = $false

if (-not $Repo) { throw 'Repo is empty and GITHUB_REPOSITORY is not set.' }

$binaries = [ordered]@{ x64 = 'DepCheck-x64.exe'; x86 = 'DepCheck-x86.exe' }
$latestUrl = "https://github.com/$Repo/releases/latest"

function ConvertTo-Html([string]$text)
{
    if ($null -eq $text) { return '' }
    [System.Net.WebUtility]::HtmlEncode($text)
}

function Get-Property($object, [string]$name)
{
    if ($null -eq $object) { return $null }
    $prop = $object.PSObject.Properties[$name]
    if ($prop) { return $prop.Value }
    return $null
}

# /releases/latest skips drafts and prereleases, which is what release.yml produces until a draft is published by
# hand. So an unpublished draft never reaches the site.
$json = gh api "repos/$Repo/releases/latest" 2>$null
$release = $null
if ($LASTEXITCODE -eq 0 -and $json)
{
    $release = $json | ConvertFrom-Json
}
else
{
    Write-Host "::notice title=Site::No published release for $Repo. Rendering with fallback download links."
}

$version = ''
$signing = 'unknown'
$sumsUrl = ''
$assets = @{}

if ($release)
{
    $version = [string]$release.tag_name
    foreach ($asset in @(Get-Property $release 'assets'))
    {
        $assets[$asset.name] = $asset
    }
    if ($assets.ContainsKey('SHA256SUMS.txt'))
    {
        $sumsUrl = [string]$assets['SHA256SUMS.txt'].browser_download_url
    }

    # signing-status.ps1 opens the notes with exactly one of these. Matching the whole marker matters: a plain
    # substring test for "signed release" also matches "Unsigned release".
    $body = [string](Get-Property $release 'body')
    if ($body -match '(?m)^>\s*\*\*Signed release\.\*\*') { $signing = 'signed' }
    elseif ($body -match '(?m)^>\s*\*\*Partially signed release\.\*\*') { $signing = 'partial' }
    elseif ($body -match '(?m)^>\s*\*\*Unsigned release\.\*\*') { $signing = 'unsigned' }
}

# The API reports asset hashes as "sha256:<hex>". Older releases predate that field, so fall back to the
# SHA256SUMS.txt the release ships anyway.
$sums = @{}
$needFallback = $false
foreach ($name in $binaries.Values)
{
    if ($assets.ContainsKey($name) -and -not (Get-Property $assets[$name] 'digest')) { $needFallback = $true }
}
if ($needFallback -and $sumsUrl)
{
    try
    {
        $text = Invoke-RestMethod -Uri $sumsUrl -Headers @{ 'User-Agent' = 'depcheck.com' } -TimeoutSec 20
        foreach ($line in ([string]$text) -split "`n")
        {
            if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(\S+)\s*$') { $sums[$Matches[2]] = $Matches[1].ToLower() }
        }
        Write-Host "Read $($sums.Count) hash(es) from SHA256SUMS.txt."
    }
    catch
    {
        Write-Host "::warning title=Site::Could not read SHA256SUMS.txt: $($_.Exception.Message)"
    }
}

$rows = New-Object System.Collections.Generic.List[string]
foreach ($arch in $binaries.Keys)
{
    $name = $binaries[$arch]
    $asset = if ($assets.ContainsKey($name)) { $assets[$name] } else { $null }

    $href = if ($asset) { [string]$asset.browser_download_url } else { "$latestUrl/download/$name" }
    $size = if ($asset) { [string][math]::Round($asset.size / 1KB) + ' KB' } else { '' }

    $hash = ''
    $digest = [string](Get-Property $asset 'digest')
    if ($digest -like 'sha256:*') { $hash = $digest.Substring(7) }
    elseif ($sums.ContainsKey($name)) { $hash = $sums[$name] }

    $rows.Add("			<tr>")
    $rows.Add("				<td><a class=""dl"" href=""$(ConvertTo-Html $href)"">&nbsp;&nbsp;&nbsp;&nbsp;DepCheck for $(ConvertTo-Html $arch)</a></td>")
    $rows.Add("				<td class=""note"">$(ConvertTo-Html $size)</td>")
    $rows.Add("			</tr>")
    if ($hash)
    {
        $rows.Add("			<tr>")
        $rows.Add("				<td class=""hash"" colspan=""2"">SHA-256: $(ConvertTo-Html $hash)</td>")
        $rows.Add("			</tr>")
    }
}

$signingHtml = switch ($signing)
{
    'signed'   { "			Authenticode signed &ndash; check the signature before running.<br>" }
    'partial'  { "			Partially signed &ndash; verify every download against SHA256SUMS.txt.<br>" }
    'unsigned' { "			Not signed &ndash; verify against SHA256SUMS.txt.<br>" }
    default    { '' }
}

$sumsHtml = ''
if ($sumsUrl) { $sumsHtml = "			<a href=""$(ConvertTo-Html $sumsUrl)"">SHA256SUMS.txt</a> &middot;" }

if (Test-Path $OutputDir) { Remove-Item $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutputDir | Out-Null
Copy-Item -Path (Join-Path $SiteDir '*') -Destination $OutputDir -Recurse -Force
# Keeps Pages from running the output through Jekyll.
New-Item -ItemType File -Path (Join-Path $OutputDir '.nojekyll') | Out-Null

$html = Get-Content (Join-Path $SiteDir 'index.html') -Raw
$html = $html.Replace('<!--{{VERSION}}-->', $(if ($version) { ' ' + (ConvertTo-Html $version) } else { '' }))
$html = $html.Replace('<!--{{DOWNLOADS}}-->', ($rows -join "`n"))
$html = $html.Replace('<!--{{SIGNING}}-->', $signingHtml)
$html = $html.Replace('<!--{{SUMS}}-->', $sumsHtml)
Set-Content -Path (Join-Path $OutputDir 'index.html') -Value $html -Encoding UTF8 -NoNewline

Write-Host "Rendered $OutputDir/index.html for $(if ($version) { $version } else { '(no release)' }), signing: $signing"

# The Actions pwsh shell exits with $LASTEXITCODE, and a repository without a release leaves the 404 from gh in it.
# Rendering succeeded either way, so say so.
exit 0
