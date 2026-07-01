# WSA-Auto-Installer-v1.9-compatible-debug-fixed.ps1
# Совместимо с Windows PowerShell 5.1 (Windows 10/11)
# Назначение: скачать подходящую сборку WSABuilds с Google Apps/GApps, распаковать и запустить Run.bat

[CmdletBinding()]
param(
    [string]$InstallDir = "C:\WSA",
    [switch]$RemoveArchiveAfterInstall,
    [switch]$DebugSearch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:NeedsReboot = $false
$script:TempExtractDir = $null
$script:DebugLogPath = Join-Path ([System.IO.Path]::GetTempPath()) ("WSA-Auto-Installer-debug-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")

function Write-DebugLog {
    param([string]$Message)

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        Add-Content -LiteralPath $script:DebugLogPath -Value "[$timestamp] $Message" -Encoding UTF8
    } catch {
        # Лог отладки не должен ломать основной сценарий.
    }
}

function Write-DebugConsole {
    param([string]$Message)

    if ($DebugSearch) {
        Write-Host "  DEBUG: $Message" -ForegroundColor DarkGray
    }
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$Name
    )

    if (($null -eq $Object) -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    # В Windows PowerShell 5.1 доступ через .PSObject.Properties[$Name]
    # иногда даёт неинформативную ошибку "Типы аргумента не совпадают"
    # на объектах, пришедших из Invoke-RestMethod/Invoke-WebRequest.
    # Поэтому используем более совместимый перебор свойств.
    try {
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) {
                return $Object[$Name]
            }
        }
    } catch {
        # Продолжаем через PSObject.
    }

    try {
        $property = $Object.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if ($property) {
            return $property.Value
        }
    } catch {
        return $null
    }

    return $null
}

function ConvertTo-SafeArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            $items += $item
        }
        return @($items)
    }

    return @($Value)
}

function Write-ErrorRecordToDebugLog {
    param($ErrorRecord)

    if ($null -eq $ErrorRecord) {
        return
    }

    try { Write-DebugLog "FATAL: $($ErrorRecord.Exception.Message)" } catch { }
    try { Write-DebugLog "FATAL type: $($ErrorRecord.Exception.GetType().FullName)" } catch { }
    try { Write-DebugLog "FATAL id: $($ErrorRecord.FullyQualifiedErrorId)" } catch { }

    try {
        if ($ErrorRecord.InvocationInfo) {
            $position = [string]$ErrorRecord.InvocationInfo.PositionMessage
            $position = $position -replace "`r?`n", ' | '
            Write-DebugLog "FATAL position: $position"
        }
    } catch { }

    try {
        if ($ErrorRecord.ScriptStackTrace) {
            $stack = [string]$ErrorRecord.ScriptStackTrace
            $stack = $stack -replace "`r?`n", ' | '
            Write-DebugLog "FATAL stack: $stack"
        }
    } catch { }
}

Write-DebugLog "Запуск WSA Auto Installer v1.9"
Write-DebugLog "PowerShell: $($PSVersionTable.PSVersion); Edition: $($PSVersionTable.PSEdition); OS: $([Environment]::OSVersion.VersionString)"

function Wait-And-Exit {
    param(
        [string]$Message,
        [int]$ExitCode = 0
    )

    if ($Message) {
        Write-Host $Message -ForegroundColor Yellow
    }

    try {
        [void](Read-Host "Нажмите Enter для выхода")
    } catch {
        # Ничего не делаем: Read-Host может быть недоступен при неинтерактивном запуске.
    }

    exit $ExitCode
}

function ConvertTo-ProcessArgument {
    param([string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument -match '[\s"]') {
        $escaped = $Argument.Replace('"', '\"')
        return '"' + $escaped + '"'
    }

    return $Argument
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-AsAdministrator {
    $currentProcess = Get-Process -Id $PID
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-InstallDir', $InstallDir
    )

    if ($RemoveArchiveAfterInstall) {
        $arguments += '-RemoveArchiveAfterInstall'
    }

    if ($DebugSearch) {
        $arguments += '-DebugSearch'
    }

    $argumentLine = ($arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
    Start-Process -FilePath $currentProcess.Path -Verb RunAs -ArgumentList $argumentLine
}

function Enable-WindowsFeatureWithDism {
    param(
        [string]$FeatureName,
        [string]$DisplayName
    )

    Write-Host "  - $DisplayName ... " -NoNewline

    & dism.exe /online /enable-feature /featurename:$FeatureName /all /norestart | Out-Null
    $exitCode = $LASTEXITCODE

    switch ($exitCode) {
        0 {
            Write-Host "OK" -ForegroundColor Green
        }
        3010 {
            $script:NeedsReboot = $true
            Write-Host "OK (требуется перезагрузка)" -ForegroundColor Yellow
        }
        default {
            throw "DISM вернул ошибку $exitCode при включении компонента $FeatureName"
        }
    }
}

function Get-SevenZipPath {
    $paths = New-Object System.Collections.Generic.List[string]

    $command = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        [void]$paths.Add($command.Source)
    }

    if ($env:ProgramFiles) {
        [void]$paths.Add((Join-Path $env:ProgramFiles '7-Zip\7z.exe'))
    }

    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($programFilesX86) {
        [void]$paths.Add((Join-Path $programFilesX86 '7-Zip\7z.exe'))
    }

    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if ($localAppData) {
        [void]$paths.Add((Join-Path $localAppData 'Programs\7-Zip\7z.exe'))
    }

    foreach ($path in $paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $path
        }
    }

    return $null
}

function Resolve-InstallPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Параметр InstallDir пустой"
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)

    try {
        return [System.IO.Path]::GetFullPath($expanded)
    } catch {
        throw "Некорректный путь установки: $Path"
    }
}

function Test-InstallVolumeIsNtfs {
    param([string]$FullInstallDir)

    $root = [System.IO.Path]::GetPathRoot($FullInstallDir)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Не удалось определить диск для пути $FullInstallDir"
    }

    if ($root -notmatch '^[A-Za-z]:\\$') {
        throw "InstallDir должен быть на локальном диске, например C:\WSA. Текущий корень: $root"
    }

    $driveLetter = $root.Substring(0, 1)
    $fileSystem = $null

    $getVolumeCommand = Get-Command Get-Volume -ErrorAction SilentlyContinue
    if ($getVolumeCommand) {
        try {
            $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
            $fileSystem = $volume.FileSystem
        } catch {
            $fileSystem = $null
        }
    }

    if (-not $fileSystem) {
        try {
            $logicalDisk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$($driveLetter):'" -ErrorAction Stop
            $fileSystem = $logicalDisk.FileSystem
        } catch {
            $fileSystem = $null
        }
    }

    if ($fileSystem -and ($fileSystem -ne 'NTFS')) {
        throw "Диск $root использует файловую систему $fileSystem. WSA нужно устанавливать на NTFS."
    }

    if (-not $fileSystem) {
        Write-Host "  Предупреждение: не удалось проверить файловую систему диска $root" -ForegroundColor Yellow
    }
}

function Get-HostTarget {
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 19041) {
        throw "Windows build $build не поддерживается. Нужна Windows 10/11 build 19041 или новее."
    }

    if ($build -ge 22000) {
        $osToken = 'Windows_11'
        $osName = 'Windows 11'
    } else {
        $osToken = 'Windows_10'
        $osName = 'Windows 10'
    }

    $arch = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if (-not $arch) {
        $arch = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
    }

    if ($arch -match 'ARM64') {
        $archToken = 'arm64'
    } elseif ($arch -match 'AMD64|x64') {
        $archToken = 'x64'
    } else {
        throw "Неподдерживаемая архитектура процессора: $arch"
    }

    return [pscustomobject]@{
        OsToken = $osToken
        OsName = $osName
        ArchToken = $archToken
    }
}


function Get-ReleaseVersionSortKey {
    param([string]$Tag)

    if ([string]::IsNullOrWhiteSpace($Tag)) {
        return '000000.000000.000000.000000.000000.000000'
    }

    $major = 0
    $minor = 0
    $build = 0
    $revision = 0
    $lts = 0
    $hotfix = 0

    if ($Tag -match '(\d+)\.(\d+)\.(\d+)\.(\d+)') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        $build = [int]$Matches[3]
        $revision = [int]$Matches[4]
    }

    if ($Tag -match '(?i)LTS[_-]?(\d+)') {
        $lts = [int]$Matches[1]
    }

    if ($Tag -match '(?i)HOTFIX[_-]?(\d+)') {
        $hotfix = [int]$Matches[1]
    }

    return ('{0:D6}.{1:D6}.{2:D6}.{3:D6}.{4:D6}.{5:D6}' -f $major, $minor, $build, $revision, $lts, $hotfix)
}

function Get-ReleaseTargetMatchInfo {
    param(
        $Release,
        [string]$OsToken,
        [string]$ArchToken
    )

    $tagName = [string](Get-ObjectPropertyValue -Object $Release -Name 'tag_name')
    $releaseName = [string](Get-ObjectPropertyValue -Object $Release -Name 'name')
    $body = [string](Get-ObjectPropertyValue -Object $Release -Name 'body')
    $draftValue = Get-ObjectPropertyValue -Object $Release -Name 'draft'
    $publishedAt = [string](Get-ObjectPropertyValue -Object $Release -Name 'published_at')

    $rawAssets = Get-ObjectPropertyValue -Object $Release -Name 'assets'
    $assetNames = @()
    if ($rawAssets) {
        $assetNames = @($rawAssets | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name 'name') })
    }

    $assetText = $assetNames -join ' '
    $primaryText = "$tagName $releaseName"
    $fullText = "$primaryText $body $assetText"

    $primaryHasWindows11 = ($primaryText -match '(?i)Windows[_\s-]*11')
    $fullHasWindows11 = ($fullText -match '(?i)Windows[_\s-]*11')
    $primaryHasWindows10 = ($primaryText -match '(?i)Windows[_\s-]*10')
    $fullHasWindows10 = ($fullText -match '(?i)Windows[_\s-]*10')
    $primaryHasArm64 = ($primaryText -match '(?i)(arm64|aarch64)')
    $fullHasArm64 = ($fullText -match '(?i)(arm64|aarch64)')
    $primaryHasX64 = ($primaryText -match '(?i)(x64|x86[_-]?64|amd64)')
    $fullHasX64 = ($fullText -match '(?i)(x64|x86[_-]?64|amd64)')

    if ($OsToken -eq 'Windows_11') {
        $osMatches = $primaryHasWindows11 -or $fullHasWindows11
    } else {
        $osMatches = $primaryHasWindows10 -or $fullHasWindows10
    }

    if ($ArchToken -eq 'arm64') {
        $archMatches = $primaryHasArm64 -or $fullHasArm64
    } else {
        $archMatches = -not $primaryHasArm64
        # Для x64 отсутствие маркера архитектуры допускается: часть релизов указывает архитектуру только в ассетах.
    }

    $isDraft = $false
    if ($null -ne $draftValue) {
        try { $isDraft = [bool]$draftValue } catch { $isDraft = $false }
    }

    $matchesTarget = (-not $isDraft) -and $osMatches -and $archMatches
    $reason = 'match'

    if ($isDraft) {
        $reason = 'draft release'
    } elseif (-not $osMatches) {
        $reason = "no $OsToken marker"
    } elseif (-not $archMatches) {
        $reason = "no $ArchToken match"
    }

    return [pscustomobject]@{
        Tag = $tagName
        Name = $releaseName
        Draft = $isDraft
        PublishedAt = $publishedAt
        AssetCount = $assetNames.Count
        SevenZipAssets = @($assetNames | Where-Object { $_ -match '(?i)\.7z$' })
        PrimaryHasWindows11 = $primaryHasWindows11
        FullHasWindows11 = $fullHasWindows11
        PrimaryHasWindows10 = $primaryHasWindows10
        FullHasWindows10 = $fullHasWindows10
        PrimaryHasArm64 = $primaryHasArm64
        FullHasArm64 = $fullHasArm64
        PrimaryHasX64 = $primaryHasX64
        FullHasX64 = $fullHasX64
        OsMatches = $osMatches
        ArchMatches = $archMatches
        MatchesTarget = $matchesTarget
        Reason = $reason
    }
}

function Write-ReleaseSearchDiagnostics {
    param(
        [string]$SourceName,
        $Releases,
        [string]$OsToken,
        [string]$ArchToken
    )

    $releaseItems = @(ConvertTo-SafeArray -Value $Releases)

    Write-DebugLog "===== Release search diagnostics: $SourceName ====="
    Write-DebugLog "Target: OS=$OsToken; Arch=$ArchToken; Releases=$($releaseItems.Count)"

    $infos = @()
    $index = 0
    foreach ($releaseItem in $releaseItems) {
        try {
            $infos += Get-ReleaseTargetMatchInfo -Release $releaseItem -OsToken $OsToken -ArchToken $ArchToken
        } catch {
            Write-DebugLog "Release diagnostics failed for ${SourceName}[$index]: $($_.Exception.Message)"
        }
        $index++
    }

    $matches = @($infos | Where-Object { $_.MatchesTarget })
    Write-DebugLog "Matched releases: $($matches.Count)"

    $groups = @($infos | Group-Object Reason | Sort-Object Count -Descending)
    foreach ($group in $groups) {
        Write-DebugLog "Filter reason: $($group.Name) = $($group.Count)"
    }

    $limit = [Math]::Min($infos.Count, 60)
    for ($i = 0; $i -lt $limit; $i++) {
        $info = $infos[$i]
        Write-DebugLog ("Release[{0}]: tag='{1}'; name='{2}'; published='{3}'; draft={4}; assets={5}; reason='{6}'; osMatch={7}; archMatch={8}; Win11(primary/full)={9}/{10}; Win10(primary/full)={11}/{12}; ARM(primary/full)={13}/{14}; X64(primary/full)={15}/{16}" -f `
            $i, $info.Tag, $info.Name, $info.PublishedAt, $info.Draft, $info.AssetCount, $info.Reason, $info.OsMatches, $info.ArchMatches, $info.PrimaryHasWindows11, $info.FullHasWindows11, $info.PrimaryHasWindows10, $info.FullHasWindows10, $info.PrimaryHasArm64, $info.FullHasArm64, $info.PrimaryHasX64, $info.FullHasX64)

        if ($info.SevenZipAssets.Count -gt 0) {
            Write-DebugLog ("  7z assets: " + (($info.SevenZipAssets | Select-Object -First 20) -join ' | '))
        }
    }

    Write-Host "  Диагностика поиска записана в: $script:DebugLogPath" -ForegroundColor Yellow

    if ($DebugSearch) {
        Write-Host "  DEBUG: $SourceName вернул релизов: $($releaseItems.Count), подходящих: $($matches.Count)" -ForegroundColor DarkGray
        foreach ($group in ($groups | Select-Object -First 5)) {
            Write-Host "  DEBUG: причина фильтрации: $($group.Name) = $($group.Count)" -ForegroundColor DarkGray
        }
        foreach ($info in ($infos | Select-Object -First 10)) {
            Write-Host "  DEBUG: $($info.Tag) => $($info.Reason)" -ForegroundColor DarkGray
        }
    }
}

function New-SourceForgeReleaseObject {
    param([string]$Tag)

    return [pscustomobject]@{
        tag_name = [string]$Tag
        name = [string]$Tag
        body = ''
        assets = @()
        assets_url = $null
        draft = $false
        prerelease = $false
        published_at = $null
        source = 'SourceForgeFolder'
    }
}

function Get-SourceForgeReleaseFolders {
    $rootUrl = 'https://sourceforge.net/projects/wsabuilds.mirror/files/'
    $headers = @{
        'User-Agent' = 'WSA-Auto-Installer'
    }

    Write-DebugLog "SourceForge root request: $rootUrl"

    try {
        $response = Invoke-WebRequest -Uri $rootUrl -UseBasicParsing -Headers $headers
    } catch {
        Write-DebugLog "SourceForge root request failed: $($_.Exception.Message)"
        Write-Host "  Предупреждение: не удалось получить список папок SourceForge: $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }

    $html = [string]$response.Content
    $pattern = '/projects/wsabuilds\.mirror/files/(?<folder>Windows_[^/"''<>]+)/'
    $matches = [regex]::Matches($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    $seen = @{}
    $releases = New-Object System.Collections.Generic.List[object]

    foreach ($match in $matches) {
        $rawFolder = $match.Groups['folder'].Value
        if ([string]::IsNullOrWhiteSpace($rawFolder)) {
            continue
        }

        $decodedFolder = [System.Uri]::UnescapeDataString($rawFolder)
        $decodedFolder = [System.Net.WebUtility]::HtmlDecode($decodedFolder)

        if ($seen.ContainsKey($decodedFolder)) {
            continue
        }

        $seen[$decodedFolder] = $true
        [void]$releases.Add((New-SourceForgeReleaseObject -Tag $decodedFolder))
    }

    if ($releases.Count -eq 0) {
        # Резервный вариант: текущая известная LTS-папка зеркала.
        # Используется только если HTML SourceForge изменился и regex не смог вытащить ссылки.
        [void]$releases.Add((New-SourceForgeReleaseObject -Tag 'Windows_11_2407.40000.4.0_LTS_7_HOTFIX_1'))
        [void]$releases.Add((New-SourceForgeReleaseObject -Tag 'Windows_10_2407.40000.4.0_LTS_7_HOTFIX_1'))
    }

    Write-DebugLog "SourceForge folders found: $($releases.Count)"
    return @(ConvertTo-SafeArray -Value $releases)
}

function Get-ReleaseSortDate {
    param($Release)

    $publishedAt = Get-ObjectPropertyValue -Object $Release -Name 'published_at'
    if ($publishedAt) {
        try {
            return [datetime]$publishedAt
        } catch {
            return [datetime]::MinValue
        }
    }

    return [datetime]::MinValue
}

function Get-ReleaseSearchText {
    param($Release)

    $rawAssets = Get-ObjectPropertyValue -Object $Release -Name 'assets'
    $assetNames = @()
    if ($rawAssets) {
        $assetNames = @($rawAssets | ForEach-Object { Get-ObjectPropertyValue -Object $_ -Name 'name' })
    }

    return "$(Get-ObjectPropertyValue -Object $Release -Name 'tag_name') $(Get-ObjectPropertyValue -Object $Release -Name 'name') $(Get-ObjectPropertyValue -Object $Release -Name 'body') $($assetNames -join ' ')"
}

function Test-ReleaseMatchesTarget {
    param(
        $Release,
        [string]$OsToken,
        [string]$ArchToken
    )

    $info = Get-ReleaseTargetMatchInfo -Release $Release -OsToken $OsToken -ArchToken $ArchToken
    return [bool]$info.MatchesTarget
}

function Test-AssetIsGoogleAppsBuild {
    param($Asset)

    $name = $Asset.name

    if ($name -match '(?i)NoGApps') {
        return $false
    }

    if ($name -match '(?i)MindTheGapps') {
        return $true
    }

    # В актуальных LTS-сборках часть ассетов переименована из MindTheGapps в GApps.
    return ($name -match '(?i)(^|[-_])GApps([-. _]|$)')
}

function Test-AssetMatchesArch {
    param(
        $Asset,
        [string]$ArchToken
    )

    $name = $Asset.name

    if ($ArchToken -eq 'arm64') {
        return ($name -match '(?i)(arm64|aarch64)')
    }

    if ($name -match '(?i)(arm64|aarch64)') {
        return $false
    }

    if ($name -match '(?i)(x64|x86[_-]?64|amd64)') {
        return $true
    }

    # Если имя ассета не содержит архитектуру, полагаемся на уже выбранный релиз.
    return $true
}

function ConvertTo-DownloadAsset {
    param(
        $RawAsset,
        [string]$Source
    )

    if (-not $RawAsset) {
        return $null
    }

    $name = $RawAsset.name
    $url = $RawAsset.browser_download_url

    if (-not $name) {
        return $null
    }

    if (-not $url) {
        return $null
    }

    return [pscustomobject]@{
        name = [string]$name
        browser_download_url = [string]$url
        Source = [string]$Source
    }
}

function Get-GitHubReleaseAssets {
    param($Release)

    $items = @()

    $releaseAssets = Get-ObjectPropertyValue -Object $Release -Name 'assets'
    $assetsUrl = Get-ObjectPropertyValue -Object $Release -Name 'assets_url'

    if ($releaseAssets) {
        $items += @($releaseAssets)
    }

    if (($items.Count -eq 0) -and $assetsUrl) {
        try {
            $headers = @{
                'User-Agent' = 'WSA-Auto-Installer'
                'Accept' = 'application/vnd.github+json'
            }
            $items += @(Invoke-RestMethod -Uri $assetsUrl -Headers $headers)
        } catch {
            Write-Host "  Предупреждение: не удалось получить список GitHub assets для $(Get-ObjectPropertyValue -Object $Release -Name 'tag_name'): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $assets = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        $asset = ConvertTo-DownloadAsset -RawAsset $item -Source 'GitHub'
        if ($asset) {
            [void]$assets.Add($asset)
        }
    }

    return @(ConvertTo-SafeArray -Value $assets)
}

function Get-SourceForgeReleaseAssets {
    param($Release)

    $tag = [string](Get-ObjectPropertyValue -Object $Release -Name 'tag_name')
    if ([string]::IsNullOrWhiteSpace($tag)) {
        return @()
    }

    $encodedTag = [System.Uri]::EscapeDataString($tag)
    $folderUrl = "https://sourceforge.net/projects/wsabuilds.mirror/files/$encodedTag/"
    $headers = @{
        'User-Agent' = 'WSA-Auto-Installer'
    }

    try {
        $response = Invoke-WebRequest -Uri $folderUrl -UseBasicParsing -Headers $headers
    } catch {
        Write-Host "  Предупреждение: не удалось открыть зеркало SourceForge для ${tag}: $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }

    $html = [string]$response.Content
    $pattern = '/projects/wsabuilds\.mirror/files/[^"''<>]+/(?<name>[^/"''<>]+\.7z)(?:/download)?'
    $matches = [regex]::Matches($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    $seen = @{}
    $assets = New-Object System.Collections.Generic.List[object]

    foreach ($match in $matches) {
        $rawName = $match.Groups['name'].Value
        if ([string]::IsNullOrWhiteSpace($rawName)) {
            continue
        }

        $decodedName = [System.Uri]::UnescapeDataString($rawName)
        $decodedName = [System.Net.WebUtility]::HtmlDecode($decodedName)

        if ($seen.ContainsKey($decodedName)) {
            continue
        }

        $seen[$decodedName] = $true
        $encodedName = [System.Uri]::EscapeDataString($decodedName)
        $downloadUrl = "https://sourceforge.net/projects/wsabuilds.mirror/files/$encodedTag/$encodedName/download"

        [void]$assets.Add([pscustomobject]@{
            name = [string]$decodedName
            browser_download_url = [string]$downloadUrl
            Source = 'SourceForge'
        })
    }

    return @(ConvertTo-SafeArray -Value $assets)
}

function Get-AssetPreferenceScore {
    param($Asset)

    $name = $Asset.name
    $score = 0

    # Предпочитаем сборку без Amazon Appstore.
    if ($name -match '(?i)(RemovedAmazon|NoAmazon|No[-_ ]?Amazon)') {
        $score -= 100
    }

    # Предпочитаем сборки без явно указанного root-решения, если они есть.
    if ($name -match '(?i)KernelSU') {
        $score += 300
    }

    if ($name -match '(?i)with[-_]?magisk|magisk') {
        $score += 200
    }

    if ($name -match '(?i)canary') {
        $score += 50
    }

    if ($name -match '(?i)stable') {
        $score += 20
    }

    # GitHub предпочтительнее, но SourceForge нужен как рабочий fallback для текущих зеркал.
    if ($Asset.Source -eq 'SourceForge') {
        $score += 5
    }

    return $score
}

function Get-BestGoogleAppsRelease {
    param(
        [string]$OsToken,
        [string]$ArchToken
    )

    Write-Host "  Поиск подходящего релиза WSABuilds для $OsToken / $ArchToken..." -ForegroundColor Cyan
    Write-DebugLog "Начат поиск релиза: OS=$OsToken; Arch=$ArchToken"

    $headers = @{
        'User-Agent' = 'WSA-Auto-Installer'
        'Accept' = 'application/vnd.github+json'
    }

    $allReleases = @()
    $githubError = $null

    for ($page = 1; $page -le 5; $page++) {
        $uri = "https://api.github.com/repos/MustardChef/WSABuilds/releases?per_page=100&page=$page"
        Write-DebugLog "GitHub releases request: $uri"

        try {
            $batch = @(ConvertTo-SafeArray -Value (Invoke-RestMethod -Uri $uri -Headers $headers))
            Write-DebugLog "GitHub page $page returned $($batch.Count) objects"
            Write-DebugConsole "GitHub page ${page}: $($batch.Count) объектов"
        } catch {
            $githubError = $_.Exception.Message
            Write-DebugLog "GitHub releases request failed on page ${page}: $githubError"
            Write-Host "  Предупреждение: GitHub API недоступен или вернул ошибку: $githubError" -ForegroundColor Yellow
            break
        }

        if ($batch.Count -eq 0) {
            break
        }

        $firstMessage = Get-ObjectPropertyValue -Object $batch[0] -Name 'message'
        $firstTag = Get-ObjectPropertyValue -Object $batch[0] -Name 'tag_name'
        if ($firstMessage -and (-not $firstTag)) {
            Write-DebugLog "GitHub returned non-release response object: message='$firstMessage'"
            break
        }

        $allReleases += $batch

        if ($batch.Count -lt 100) {
            break
        }
    }

    if ($allReleases.Count -gt 0) {
        try {
            Write-ReleaseSearchDiagnostics -SourceName 'GitHub' -Releases $allReleases -OsToken $OsToken -ArchToken $ArchToken
        } catch {
            Write-DebugLog "GitHub diagnostics failed: $($_.Exception.Message)"
        }

        $matching = @(
            $allReleases | Where-Object {
                Test-ReleaseMatchesTarget -Release $_ -OsToken $OsToken -ArchToken $ArchToken
            }
        )

        if ($matching.Count -gt 0) {
            $best = $matching |
                Sort-Object @{ Expression = { Get-ReleaseSortDate $_ }; Descending = $true }, @{ Expression = { Get-ReleaseVersionSortKey ([string](Get-ObjectPropertyValue -Object $_ -Name 'tag_name')) }; Descending = $true } |
                Select-Object -First 1

            Write-DebugLog "Selected GitHub release: $(Get-ObjectPropertyValue -Object $best -Name 'tag_name')"
            return $best
        }
    } else {
        Write-DebugLog "GitHub returned no releases. Error='$githubError'"
    }

    Write-Host "  GitHub не дал подходящего релиза. Проверяю зеркало SourceForge..." -ForegroundColor Yellow
    $sourceForgeReleases = @(Get-SourceForgeReleaseFolders)

    if ($sourceForgeReleases.Count -gt 0) {
        try {
            Write-ReleaseSearchDiagnostics -SourceName 'SourceForge root' -Releases $sourceForgeReleases -OsToken $OsToken -ArchToken $ArchToken
        } catch {
            Write-DebugLog "SourceForge diagnostics failed: $($_.Exception.Message)"
        }

        $sfMatching = @(
            $sourceForgeReleases | Where-Object {
                Test-ReleaseMatchesTarget -Release $_ -OsToken $OsToken -ArchToken $ArchToken
            }
        )

        if ($sfMatching.Count -gt 0) {
            $bestSf = $sfMatching |
                Sort-Object @{ Expression = { Get-ReleaseVersionSortKey ([string](Get-ObjectPropertyValue -Object $_ -Name 'tag_name')) }; Descending = $true } |
                Select-Object -First 1

            Write-DebugLog "Selected SourceForge release folder: $(Get-ObjectPropertyValue -Object $bestSf -Name 'tag_name')"
            Write-Host "  Используется релиз из зеркала SourceForge: $(Get-ObjectPropertyValue -Object $bestSf -Name 'tag_name')" -ForegroundColor Cyan
            return $bestSf
        }
    }

    throw "Не найден подходящий релиз WSABuilds для $OsToken / $ArchToken. Подробная диагностика записана в: $script:DebugLogPath"
}

function Get-PreferredAsset {
    param(
        $Release,
        [string]$ArchToken
    )

    $releaseTag = [string](Get-ObjectPropertyValue -Object $Release -Name 'tag_name')
    Write-DebugLog "Начат поиск ассета для релиза '$releaseTag'; Arch=$ArchToken"

    $allAssets = @()
    $gitHubAssets = @(Get-GitHubReleaseAssets -Release $Release)
    $sourceForgeAssets = @(Get-SourceForgeReleaseAssets -Release $Release)
    $allAssets += $gitHubAssets
    $allAssets += $sourceForgeAssets

    Write-DebugLog "Assets collected for '$releaseTag': GitHub=$($gitHubAssets.Count); SourceForge=$($sourceForgeAssets.Count); Total=$($allAssets.Count)"
    Write-DebugConsole "ассетов: GitHub=$($gitHubAssets.Count), SourceForge=$($sourceForgeAssets.Count), всего=$($allAssets.Count)"

    foreach ($asset in $allAssets) {
        $is7z = ($asset.name -match '(?i)\.7z$')
        $isGapps = Test-AssetIsGoogleAppsBuild -Asset $asset
        $isArch = Test-AssetMatchesArch -Asset $asset -ArchToken $ArchToken
        Write-DebugLog "Asset: source=$($asset.Source); name='$($asset.name)'; is7z=$is7z; isGApps=$isGapps; archMatch=$isArch; url=$($asset.browser_download_url)"
    }

    $assets = @(
        $allAssets | Where-Object {
            ($_.name -match '(?i)\.7z$') -and
            (Test-AssetIsGoogleAppsBuild -Asset $_) -and
            (Test-AssetMatchesArch -Asset $_ -ArchToken $ArchToken)
        }
    )

    if ($assets.Count -eq 0) {
        $names = @($allAssets | Select-Object -ExpandProperty name -ErrorAction SilentlyContinue) -join ', '
        if (-not $names) { $names = 'список ассетов пуст' }
        throw "В релизе $releaseTag не найден подходящий архив Google Apps/GApps для $ArchToken. Найдено: $names. Подробная диагностика записана в: $script:DebugLogPath"
    }

    $selected = ($assets |
        Sort-Object @{ Expression = { Get-AssetPreferenceScore $_ }; Ascending = $true }, Name |
        Select-Object -First 1)

    Write-DebugLog "Selected asset: source=$($selected.Source); name='$($selected.name)'; url=$($selected.browser_download_url)"
    return $selected
}

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }

    $headers = @{
        'User-Agent' = 'WSA-Auto-Installer'
    }

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -Headers $headers
    } catch {
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }

        throw "Не удалось скачать архив: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "Файл не был создан после скачивания: $Destination"
    }

    $size = (Get-Item -LiteralPath $Destination).Length
    if ($size -lt 100MB) {
        throw "Скачанный файл слишком маленький ($size байт). Вероятно, скачивание не удалось."
    }
}

function Find-ExtractedWsaRoot {
    param([string]$Root)

    $runBats = @(Get-ChildItem -Path $Root -Filter 'Run.bat' -File -Recurse -ErrorAction SilentlyContinue)

    if ($runBats.Count -eq 0) {
        throw "Run.bat не найден после распаковки"
    }

    $withManifest = @(
        $runBats | Where-Object {
            Test-Path -LiteralPath (Join-Path $_.DirectoryName 'AppxManifest.xml') -PathType Leaf
        }
    )

    if ($withManifest.Count -gt 0) {
        return $withManifest[0].DirectoryName
    }

    throw "Run.bat найден, но рядом нет AppxManifest.xml. Распакованная папка не похожа на корень WSA."
}

function Backup-ExistingInstallDir {
    param([string]$FullInstallDir)

    if (-not (Test-Path -LiteralPath $FullInstallDir)) {
        return $null
    }

    $root = [System.IO.Path]::GetPathRoot($FullInstallDir)
    $normalized = [System.IO.Path]::GetFullPath($FullInstallDir).TrimEnd('\')

    if ($normalized -eq $root.TrimEnd('\')) {
        throw "InstallDir не должен указывать на корень диска: $FullInstallDir"
    }

    $parent = Split-Path -Parent $normalized
    $leaf = Split-Path -Leaf $normalized
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $parent "$leaf.backup-$timestamp"

    $counter = 1
    while (Test-Path -LiteralPath $backup) {
        $backup = Join-Path $parent "$leaf.backup-$timestamp-$counter"
        $counter++
    }

    Write-Host "  Старая папка установки будет переименована в:" -ForegroundColor Yellow
    Write-Host "  $backup" -ForegroundColor Yellow

    try {
        Rename-Item -LiteralPath $normalized -NewName (Split-Path -Leaf $backup) -ErrorAction Stop
    } catch {
        throw "Не удалось переименовать старую папку установки. Закройте WSA/Android-приложения и повторите запуск. Детали: $($_.Exception.Message)"
    }

    return $backup
}

try {
    if (-not (Test-IsAdministrator)) {
        Write-Host "Запрашиваю права администратора..." -ForegroundColor Yellow
        Restart-AsAdministrator
        exit
    }

    Clear-Host
    Write-Host "WSA Auto Installer v1.9 (расширенная диагностика поиска)" -ForegroundColor Cyan
    Write-Host "Подготовка Windows + скачивание WSABuilds с Google Play`n" -ForegroundColor Cyan

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Host "  Предупреждение: не удалось принудительно установить TLS 1.2" -ForegroundColor Yellow
    }

    $InstallDir = Resolve-InstallPath -Path $InstallDir
    Test-InstallVolumeIsNtfs -FullInstallDir $InstallDir

    Write-Host "[1/4] Включение компонентов Windows..." -ForegroundColor Green
    Enable-WindowsFeatureWithDism 'VirtualMachinePlatform' 'Virtual Machine Platform'
    Enable-WindowsFeatureWithDism 'HypervisorPlatform' 'Windows Hypervisor Platform'

    Write-Host "  - Developer Mode ... " -NoNewline
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    if (-not (Test-Path -LiteralPath $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name 'AllowDevelopmentWithoutDevLicense' -Value 1 -Type DWord -Force
    Write-Host "OK" -ForegroundColor Green

    if ($script:NeedsReboot) {
        Wait-And-Exit "Требуется перезагрузка Windows. Перезагрузите ПК и запустите скрипт снова."
    }

    $target = Get-HostTarget
    Write-DebugLog "Detected target: OS=$($target.OsName); OsToken=$($target.OsToken); Arch=$($target.ArchToken); InstallDir=$InstallDir; DebugSearch=$DebugSearch"

    Write-Host "`n[2/4] Поиск и скачивание сборки..." -ForegroundColor Green
    Write-Host "  Целевая система: $($target.OsName) / $($target.ArchToken)" -ForegroundColor Cyan

    $release = Get-BestGoogleAppsRelease -OsToken $target.OsToken -ArchToken $target.ArchToken
    $asset = Get-PreferredAsset -Release $release -ArchToken $target.ArchToken

    $downloadsDir = Join-Path $env:USERPROFILE 'Downloads'
    $downloadPath = Join-Path $downloadsDir $asset.name

    Write-Host "  Релиз: $($release.tag_name)" -ForegroundColor Cyan
    Write-Host "  Файл:  $($asset.name)" -ForegroundColor Cyan
    Write-Host "  Источник: $($asset.Source)" -ForegroundColor Cyan

    Download-File -Url $asset.browser_download_url -Destination $downloadPath
    Write-Host "  Скачивание завершено." -ForegroundColor Green

    Write-Host "`n[3/4] Распаковка..." -ForegroundColor Green

    $sevenZip = Get-SevenZipPath
    if (-not $sevenZip) {
        throw "7-Zip не найден. Установите 7-Zip и повторите запуск."
    }

    $script:TempExtractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("WSA-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $script:TempExtractDir -ItemType Directory -Force | Out-Null

    & $sevenZip x $downloadPath "-o$script:TempExtractDir" -y | Out-Null
    $sevenZipExitCode = $LASTEXITCODE

    if ($sevenZipExitCode -ne 0) {
        throw "7-Zip завершился с кодом $sevenZipExitCode"
    }

    $wsaRoot = Find-ExtractedWsaRoot -Root $script:TempExtractDir

    $installParent = Split-Path -Parent $InstallDir
    if (-not (Test-Path -LiteralPath $installParent -PathType Container)) {
        New-Item -Path $installParent -ItemType Directory -Force | Out-Null
    }

    $backupPath = Backup-ExistingInstallDir -FullInstallDir $InstallDir

    try {
        Move-Item -LiteralPath $wsaRoot -Destination $InstallDir -Force
    } catch {
        if ($backupPath -and (Test-Path -LiteralPath $backupPath) -and (-not (Test-Path -LiteralPath $InstallDir))) {
            Rename-Item -LiteralPath $backupPath -NewName (Split-Path -Leaf $InstallDir) -ErrorAction SilentlyContinue
        }

        throw "Не удалось переместить распакованную WSA-папку в $InstallDir. Детали: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'Run.bat') -PathType Leaf)) {
        throw "После перемещения в $InstallDir не найден Run.bat"
    }

    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'AppxManifest.xml') -PathType Leaf)) {
        throw "После перемещения в $InstallDir не найден AppxManifest.xml"
    }

    Remove-Item -LiteralPath $script:TempExtractDir -Recurse -Force
    $script:TempExtractDir = $null
    Write-Host "`n[4/4] Запуск установки..." -ForegroundColor Green

    $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/d /c Run.bat' -WorkingDirectory $InstallDir -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        throw "Run.bat завершился с кодом $($process.ExitCode)"
    }

    Write-Host "`nУСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!" -ForegroundColor Green
    Write-Host "Ищите в меню Пуск: Windows Subsystem for Android и Google Play Store" -ForegroundColor Green
    Write-Host "Папка установки: $InstallDir" -ForegroundColor Cyan

    if ($RemoveArchiveAfterInstall) {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Архив сохранён: $downloadPath" -ForegroundColor DarkGray
    }

    Wait-And-Exit "Готово."
} catch {
    Write-ErrorRecordToDebugLog -ErrorRecord $_
    Write-Host "`nОШИБКА: $($_.Exception.Message)" -ForegroundColor Red
    if ($script:DebugLogPath -and (Test-Path -LiteralPath $script:DebugLogPath -PathType Leaf)) {
        Write-Host "Лог отладки: $script:DebugLogPath" -ForegroundColor Yellow
        Write-Host "Пришлите содержимое этого файла, если ошибка повторится." -ForegroundColor Yellow
    }
    Wait-And-Exit "Исправьте ошибку и запустите скрипт снова." 1
} finally {
    if ($script:TempExtractDir -and (Test-Path -LiteralPath $script:TempExtractDir)) {
        Remove-Item -LiteralPath $script:TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
