[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string[]] $Runtime = @('win-x64', 'win-arm64'),
    [string] $OutputDirectory = '',
    [switch] $SkipTests
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $projectRoot 'dist/windows' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$projectPath = Join-Path $projectRoot 'windows/src/DoubaoVoiceBridge.Windows/DoubaoVoiceBridge.Windows.csproj'
[xml] $versionXml = Get-Content -LiteralPath (Join-Path $projectRoot 'windows/Directory.Build.props') -Raw
$version = [string] $versionXml.Project.PropertyGroup.Version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Shared Windows Version must be X.Y.Z.' }
[xml] $manifestXml = Get-Content -LiteralPath (Join-Path $projectRoot 'windows/src/DoubaoVoiceBridge.Windows/app.manifest') -Raw
if ([string] $manifestXml.assembly.assemblyIdentity.version -ne "$version.0") { throw 'Windows manifest version does not match the shared version.' }
$null = Get-Command dotnet -ErrorAction Stop
$commit = (& git -C $projectRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot resolve source revision.' }
$dirty = @(& git -C $projectRoot status --porcelain).Count -gt 0
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect source status.' }
if (-not $SkipTests) {
    & dotnet run --project (Join-Path $projectRoot 'windows/tests/DoubaoVoiceBridge.Tests') --configuration Release
    if ($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }
    & dotnet run --project (Join-Path $projectRoot 'windows/tests/DoubaoVoiceBridge.DiagnosticsTests') --configuration Release
    if ($LASTEXITCODE -ne 0) { throw 'Diagnostic/configuration tests failed.' }
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
foreach ($rid in ($Runtime | Select-Object -Unique)) {
    $packageName = "DoubaoVoiceBridge-Windows-$rid-v$version"
    $publishPath = Join-Path $OutputDirectory $packageName
    # Only replace this exact named package, never the caller's output directory.
    if (Test-Path -LiteralPath $publishPath) { Remove-Item -LiteralPath $publishPath -Recurse -Force }
    & dotnet publish $projectPath --configuration Release --runtime $rid --self-contained true `
        -p:EnableWindowsTargeting=true -p:PublishSingleFile=false -p:PublishTrimmed=false `
        -p:DebugType=None -p:DebugSymbols=false --output $publishPath
    if ($LASTEXITCODE -ne 0) { throw "Publish failed for $rid." }
    if (-not (Test-Path -LiteralPath (Join-Path $publishPath 'DoubaoVoiceBridge.exe'))) { throw 'Published executable missing.' }
    $manifest = [ordered]@{
        version = $version
        sourceCommit = $commit
        sourceDirty = $dirty
        runtime = $rid
        builtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        framework = 'net10.0-windows'
        selfContained = $true
        signing = 'unsigned'
        validation = 'Cross-publish does not validate Windows, Doubao IME, UU mapping or remote delivery. See acceptance guide.'
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $publishPath 'build-info.json') -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination $publishPath
    $readme = Get-Content -LiteralPath (Join-Path $projectRoot 'windows/README.md') -Raw
    $readme.Replace('../docs/windows/', 'docs/') | Set-Content -LiteralPath (Join-Path $publishPath 'README-Windows.md') -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $projectRoot 'docs/windows') -Destination (Join-Path $publishPath 'docs') -Recurse
    $archivePath = Join-Path $OutputDirectory "$packageName.zip"
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
    Compress-Archive -Path (Join-Path $publishPath '*') -DestinationPath $archivePath -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $packageName.zip" | Set-Content -LiteralPath "$archivePath.sha256" -Encoding ascii
    Write-Output "Built $archivePath"
}
