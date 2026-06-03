#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Scan', 'Clean', 'Optimize', 'Health', 'All', 'WingetUpgrade', 'WingetInstall', 'WingetUninstall', 'Backup')]
    [string]$Action = 'Scan',

    [ValidateSet('Safe', 'Standard', 'Deep')]
    [string]$Preset = 'Safe',

    [switch]$Apply,
    [switch]$CreateRestorePoint,
    [switch]$Elevate,
    [switch]$KeepOpen,
    [switch]$Interactive,
    [string[]]$InstallPackage = @(),
    [string]$InstallList = '',
    [string[]]$UninstallPackage = @(),
    [string]$UninstallList = '',
    [string]$WingetSource = 'winget',
    [string]$BackupDestination = '',
    [ValidateSet('Local', 'All')]
    [string]$BackupMode = 'All',
    [string[]]$BackupFolder = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos'),
    [string]$ReportDirectory = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($ReportDirectory)) {
    $ReportDirectory = Join-Path $script:ScriptRoot 'reports'
}
$script:UserProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$script:SuppressKeepOpenPause = $false

$script:RunStarted = Get-Date
$script:Report = [ordered]@{
    Tool = 'ps1-toolkit'
    Version = '0.3.0'
    Started = $script:RunStarted.ToString('s')
    ComputerName = $env:COMPUTERNAME
    UserName = $env:USERNAME
    IsAdministrator = $false
    Action = $Action
    Preset = $Preset
    Apply = [bool]$Apply
    Items = New-Object System.Collections.ArrayList
    Totals = [ordered]@{
        EstimatedBytes = 0
        RemovedBytes = 0
        RemovedItems = 0
        FailedItems = 0
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedSelf {
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if (-not $scriptPath) {
        throw 'Cannot determine script path for elevation.'
    }

    $arguments = New-Object System.Collections.ArrayList
    if ($KeepOpen) { [void]$arguments.Add('-NoExit') }
    [void]$arguments.Add('-NoProfile')
    [void]$arguments.Add('-ExecutionPolicy')
    [void]$arguments.Add('Bypass')
    [void]$arguments.Add('-File')
    [void]$arguments.Add(('"{0}"' -f $scriptPath))
    [void]$arguments.Add('-Action')
    [void]$arguments.Add($Action)
    [void]$arguments.Add('-Preset')
    [void]$arguments.Add($Preset)
    if ($Apply) { [void]$arguments.Add('-Apply') }
    if ($CreateRestorePoint) { [void]$arguments.Add('-CreateRestorePoint') }
    if ($KeepOpen) { [void]$arguments.Add('-KeepOpen') }
    if ($Interactive) { [void]$arguments.Add('-Interactive') }
    $installPackages = @($InstallPackage | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($installPackages.Count -gt 0) {
        [void]$arguments.Add('-InstallPackage')
        [void]$arguments.Add(('"{0}"' -f ($installPackages -join ',')))
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallList)) {
        [void]$arguments.Add('-InstallList')
        [void]$arguments.Add(('"{0}"' -f $InstallList))
    }
    $uninstallPackages = @($UninstallPackage | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($uninstallPackages.Count -gt 0) {
        [void]$arguments.Add('-UninstallPackage')
        [void]$arguments.Add(('"{0}"' -f ($uninstallPackages -join ',')))
    }
    if (-not [string]::IsNullOrWhiteSpace($UninstallList)) {
        [void]$arguments.Add('-UninstallList')
        [void]$arguments.Add(('"{0}"' -f $UninstallList))
    }
    if (-not [string]::IsNullOrWhiteSpace($WingetSource)) {
        [void]$arguments.Add('-WingetSource')
        [void]$arguments.Add(('"{0}"' -f $WingetSource))
    }
    if (-not [string]::IsNullOrWhiteSpace($BackupDestination)) {
        [void]$arguments.Add('-BackupDestination')
        [void]$arguments.Add(('"{0}"' -f $BackupDestination))
    }
    [void]$arguments.Add('-BackupMode')
    [void]$arguments.Add($BackupMode)
    $backupFolders = @($BackupFolder | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($backupFolders.Count -gt 0) {
        [void]$arguments.Add('-BackupFolder')
        [void]$arguments.Add(('"{0}"' -f ($backupFolders -join ',')))
    }
    if (-not [string]::IsNullOrWhiteSpace($ReportDirectory)) {
        [void]$arguments.Add('-ReportDirectory')
        [void]$arguments.Add(('"{0}"' -f $ReportDirectory))
    }

    Start-Process -FilePath 'powershell.exe' -ArgumentList ($arguments -join ' ') -Verb RunAs -WorkingDirectory $script:ScriptRoot | Out-Null
}

function Initialize-ReportDirectory {
    if (-not (Test-Path -LiteralPath $ReportDirectory)) {
        New-Item -Path $ReportDirectory -ItemType Directory -Force | Out-Null
    }
}

function Write-Step {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
}

function Clear-InteractiveScreen {
    if ($Interactive) {
        Clear-Host
    }
}

function Add-ReportItem {
    param(
        [string]$Category,
        [string]$Name,
        [string]$Status,
        [string]$Details = '',
        [long]$Bytes = 0
    )

    [void]$script:Report.Items.Add([ordered]@{
        Time = (Get-Date).ToString('s')
        Category = $Category
        Name = $Name
        Status = $Status
        Details = $Details
        Bytes = $Bytes
    })
}

function Convert-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DirectorySize {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    $total = 0L
    Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (-not $_.PSIsContainer) {
                $total += $_.Length
            }
        }
    return $total
}

function Get-UserShellFolder {
    param([string]$Key)

    $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    try {
        $value = Get-ItemProperty -Path $regPath -Name $Key -ErrorAction Stop
        return [Environment]::ExpandEnvironmentVariables($value.$Key)
    }
    catch {
        return $null
    }
}

function Get-DownloadsPath {
    $path = Get-UserShellFolder -Key '{374DE290-123F-4565-9164-39C4925E467B}'
    if (-not $path) {
        $path = Join-Path $script:UserProfile 'Downloads'
    }
    return $path
}

function Get-ActiveUserFolderPath {
    param([string]$Folder)

    switch ($Folder) {
        'Desktop' { return [Environment]::GetFolderPath('Desktop') }
        'Documents' { return [Environment]::GetFolderPath('MyDocuments') }
        'Downloads' { return Get-DownloadsPath }
        'Pictures' { return [Environment]::GetFolderPath('MyPictures') }
        'Music' { return [Environment]::GetFolderPath('MyMusic') }
        'Videos' { return [Environment]::GetFolderPath('MyVideos') }
        default { return $null }
    }
}

function Get-CleanupTargets {
    param([string]$SelectedPreset)

    $targets = New-Object System.Collections.ArrayList
    $safeTargets = @(
        @{ Name = 'User temp'; Path = $env:TEMP; Pattern = '*' },
        @{ Name = 'Windows temp'; Path = "$env:windir\Temp"; Pattern = '*' },
        @{ Name = 'Thumbnail cache'; Path = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"; Pattern = 'thumbcache_*.db' },
        @{ Name = 'DirectX shader cache'; Path = "$env:LOCALAPPDATA\D3DSCache"; Pattern = '*' }
    )

    foreach ($target in $safeTargets) { [void]$targets.Add($target) }

    if ($SelectedPreset -in @('Standard', 'Deep')) {
        $standardTargets = @(
            @{ Name = 'Windows Update download cache'; Path = "$env:windir\SoftwareDistribution\Download"; Pattern = '*' },
            @{ Name = 'Microsoft Edge cache'; Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"; Pattern = '*' },
            @{ Name = 'Chrome cache'; Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"; Pattern = '*' },
            @{ Name = 'Firefox cache'; Path = "$env:APPDATA\Mozilla\Firefox\Profiles"; Pattern = 'cache2' }
        )
        foreach ($target in $standardTargets) { [void]$targets.Add($target) }
    }

    if ($SelectedPreset -eq 'Deep') {
        $deepTargets = @(
            @{ Name = 'Crash dumps'; Path = "$env:LOCALAPPDATA\CrashDumps"; Pattern = '*' },
            @{ Name = 'Windows memory dumps'; Path = $env:windir; Pattern = 'MEMORY.DMP' },
            @{ Name = 'Minidumps'; Path = "$env:windir\Minidump"; Pattern = '*' }
        )
        foreach ($target in $deepTargets) { [void]$targets.Add($target) }
    }

    return $targets
}

function Invoke-FileCleanup {
    param(
        [hashtable]$Target,
        [switch]$ActuallyApply
    )

    $path = [Environment]::ExpandEnvironmentVariables($Target.Path)
    if (-not (Test-Path -LiteralPath $path)) {
        Add-ReportItem -Category 'Clean' -Name $Target.Name -Status 'Skipped' -Details "Path not found: $path"
        return
    }

    Write-Step "Scanning $($Target.Name): $path"
    $items = @(Get-ChildItem -LiteralPath $path -Filter $Target.Pattern -Force -Recurse -ErrorAction SilentlyContinue)
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    $bytes = 0L
    foreach ($file in $files) { $bytes += $file.Length }

    $script:Report.Totals.EstimatedBytes += $bytes

    if (-not $ActuallyApply) {
        Add-ReportItem -Category 'Clean' -Name $Target.Name -Status 'DryRun' -Details ("Would remove {0} items from {1}" -f $items.Count, $path) -Bytes $bytes
        Write-Step ("Dry run: {0} would remove about {1}" -f $Target.Name, (Convert-Bytes $bytes)) -Color Yellow
        return
    }

    $removed = 0
    $failed = 0
    $removedBytes = 0L

    foreach ($item in $items) {
        try {
            if (-not $item.PSIsContainer) {
                $removedBytes += $item.Length
            }
            Remove-Item -LiteralPath $item.FullName -Force -Recurse -ErrorAction Stop
            $removed++
        }
        catch {
            $failed++
        }
    }

    $script:Report.Totals.RemovedBytes += $removedBytes
    $script:Report.Totals.RemovedItems += $removed
    $script:Report.Totals.FailedItems += $failed
    Add-ReportItem -Category 'Clean' -Name $Target.Name -Status 'Applied' -Details ("Removed {0} items; {1} failed" -f $removed, $failed) -Bytes $removedBytes
    Write-Step ("Cleaned {0}: removed {1}, failed {2}, freed about {3}" -f $Target.Name, $removed, $failed, (Convert-Bytes $removedBytes)) -Color Green
}

function Clear-RecycleBinSafe {
    param([switch]$ActuallyApply)

    if (-not $ActuallyApply) {
        Add-ReportItem -Category 'Clean' -Name 'Recycle Bin' -Status 'DryRun' -Details 'Would empty recycle bin.'
        Write-Step 'Dry run: would empty recycle bin' -Color Yellow
        return
    }

    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Add-ReportItem -Category 'Clean' -Name 'Recycle Bin' -Status 'Applied' -Details 'Recycle bin emptied.'
        Write-Step 'Recycle bin emptied' -Color Green
    }
    catch {
        Add-ReportItem -Category 'Clean' -Name 'Recycle Bin' -Status 'Failed' -Details $_.Exception.Message
        $script:Report.Totals.FailedItems++
        Write-Step "Recycle bin cleanup failed: $($_.Exception.Message)" -Color Red
    }
}

function New-SystemRestorePoint {
    if (-not $script:Report.IsAdministrator) {
        Add-ReportItem -Category 'Safety' -Name 'Restore point' -Status 'Skipped' -Details 'Administrator rights required.'
        return
    }

    try {
        Write-Step 'Creating restore point...'
        Checkpoint-Computer -Description 'Before ps1-toolkit maintenance' -RestorePointType 'MODIFY_SETTINGS'
        Add-ReportItem -Category 'Safety' -Name 'Restore point' -Status 'Created' -Details 'Before ps1-toolkit maintenance'
        Write-Step 'Restore point created' -Color Green
    }
    catch {
        Add-ReportItem -Category 'Safety' -Name 'Restore point' -Status 'Failed' -Details $_.Exception.Message
        Write-Step "Restore point failed: $($_.Exception.Message)" -Color Yellow
    }
}

function Invoke-Scan {
    Write-Step 'Collecting system scan...' -Color Cyan

    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $processor = Get-CimInstance Win32_Processor | Select-Object -First 1
    $drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"

    Add-ReportItem -Category 'Scan' -Name 'Operating system' -Status 'Info' -Details ("{0} build {1}" -f $os.Caption, $os.BuildNumber)
    Add-ReportItem -Category 'Scan' -Name 'Computer' -Status 'Info' -Details ("{0}; {1:N2} GB RAM; {2}" -f $computer.Model, ($computer.TotalPhysicalMemory / 1GB), $processor.Name)

    foreach ($drive in $drives) {
        $detail = "{0}: free {1} of {2}" -f $drive.DeviceID, (Convert-Bytes $drive.FreeSpace), (Convert-Bytes $drive.Size)
        Add-ReportItem -Category 'Scan' -Name 'Drive space' -Status 'Info' -Details $detail
        Write-Step $detail
    }

    foreach ($target in (Get-CleanupTargets -SelectedPreset 'Deep')) {
        $path = [Environment]::ExpandEnvironmentVariables($target.Path)
        $bytes = Get-DirectorySize -Path $path
        Add-ReportItem -Category 'Scan' -Name $target.Name -Status 'Info' -Details $path -Bytes $bytes
    }

    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object -First 40 Name, Command, Location)
    Add-ReportItem -Category 'Scan' -Name 'Startup entries' -Status 'Info' -Details ("Found {0} entries. See JSON report for details." -f $startup.Count)
    $script:Report.StartupEntries = $startup

    $hotfixes = @(Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, InstalledOn, Description)
    $script:Report.RecentHotFixes = $hotfixes
}

function Invoke-Clean {
    Write-Step ("Starting {0} cleanup. Apply={1}" -f $Preset, [bool]$Apply) -Color Cyan

    if ($Apply -and $CreateRestorePoint) {
        New-SystemRestorePoint
    }

    $targets = Get-CleanupTargets -SelectedPreset $Preset
    foreach ($target in $targets) {
        Invoke-FileCleanup -Target $target -ActuallyApply:$Apply
    }

    Clear-RecycleBinSafe -ActuallyApply:$Apply
}

function Invoke-Optimize {
    Write-Step 'Optimizing fixed volumes with Windows Optimize-Volume...' -Color Cyan

    if (-not $script:Report.IsAdministrator) {
        Add-ReportItem -Category 'Optimize' -Name 'Optimize-Volume' -Status 'Skipped' -Details 'Administrator rights required.'
        Write-Step 'Drive optimization requires Administrator rights.' -Color Yellow
        return
    }

    $volumes = @(Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter })
    foreach ($volume in $volumes) {
        try {
            Write-Step "Optimizing $($volume.DriveLetter):"
            Optimize-Volume -DriveLetter $volume.DriveLetter -Verbose:$false
            Add-ReportItem -Category 'Optimize' -Name "$($volume.DriveLetter):" -Status 'Applied' -Details 'Optimize-Volume completed.'
        }
        catch {
            Add-ReportItem -Category 'Optimize' -Name "$($volume.DriveLetter):" -Status 'Failed' -Details $_.Exception.Message
            Write-Step "Optimization failed for $($volume.DriveLetter): $($_.Exception.Message)" -Color Red
        }
    }
}

function Invoke-Health {
    Write-Step 'Running Windows health checks...' -Color Cyan

    if (-not $script:Report.IsAdministrator) {
        Add-ReportItem -Category 'Health' -Name 'DISM/SFC' -Status 'Skipped' -Details 'Administrator rights required.'
        Write-Step 'DISM and SFC repairs require Administrator rights.' -Color Yellow
        return
    }

    $commands = @(
        @{ Name = 'DISM RestoreHealth'; File = 'dism.exe'; Args = '/Online /Cleanup-Image /RestoreHealth' },
        @{ Name = 'SFC ScanNow'; File = 'sfc.exe'; Args = '/scannow' }
    )

    foreach ($command in $commands) {
        try {
            Write-Step "Running $($command.Name). This may take a while..."
            $process = Start-Process -FilePath $command.File -ArgumentList $command.Args -Wait -PassThru -NoNewWindow
            Add-ReportItem -Category 'Health' -Name $command.Name -Status "ExitCode $($process.ExitCode)" -Details "$($command.File) $($command.Args)"
        }
        catch {
            Add-ReportItem -Category 'Health' -Name $command.Name -Status 'Failed' -Details $_.Exception.Message
            Write-Step "$($command.Name) failed: $($_.Exception.Message)" -Color Red
        }
    }
}

function Test-WingetAvailable {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Add-ReportItem -Category 'Winget' -Name 'winget.exe' -Status 'Missing' -Details 'Install or update App Installer from Microsoft Store.'
        Write-Step 'winget.exe was not found. Install or update App Installer from Microsoft Store.' -Color Yellow
        return $false
    }

    Add-ReportItem -Category 'Winget' -Name 'winget.exe' -Status 'Found' -Details $winget.Source
    return $true
}

function Invoke-WingetCommand {
    param(
        [string]$Name,
        [string[]]$Arguments
    )

    Write-Step ("winget {0}" -f ($Arguments -join ' ')) -Color Cyan
    $output = @(& winget.exe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $details = ($output | Select-Object -Last 12) -join [Environment]::NewLine

    if ($exitCode -eq 0) {
        Add-ReportItem -Category 'Winget' -Name $Name -Status 'ExitCode 0' -Details $details
        Write-Step "$Name completed" -Color Green
    }
    else {
        Add-ReportItem -Category 'Winget' -Name $Name -Status "ExitCode $exitCode" -Details $details
        Write-Step "$Name exited with code $exitCode" -Color Yellow
    }

    foreach ($line in $output) {
        Write-Host $line
    }
}

function Invoke-WingetUpgrade {
    if (-not (Test-WingetAvailable)) { return }

    if (-not $Apply) {
        Add-ReportItem -Category 'Winget' -Name 'Software upgrades' -Status 'DryRun' -Details 'Listed available upgrades only.'
        Invoke-WingetCommand -Name 'List available upgrades' -Arguments @('upgrade', '--source', $WingetSource, '--accept-source-agreements', '--disable-interactivity')
        return
    }

    Invoke-WingetCommand -Name 'Upgrade all packages' -Arguments @(
        'upgrade',
        '--all',
        '--source',
        $WingetSource,
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
}

function Get-UninstallPackageTargets {
    $targets = New-Object System.Collections.ArrayList

    foreach ($package in $UninstallPackage) {
        if (-not [string]::IsNullOrWhiteSpace($package)) {
            [void]$targets.Add($package.Trim())
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($UninstallList)) {
        $resolvedPath = [Environment]::ExpandEnvironmentVariables($UninstallList)
        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            throw "Uninstall list not found: $resolvedPath"
        }

        $lines = Get-Content -LiteralPath $resolvedPath
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -and -not $trimmed.StartsWith('#')) {
                [void]$targets.Add($trimmed)
            }
        }
    }

    return @($targets | Select-Object -Unique)
}

function Get-InstallPackageTargets {
    $targets = New-Object System.Collections.ArrayList

    foreach ($package in $InstallPackage) {
        if (-not [string]::IsNullOrWhiteSpace($package)) {
            foreach ($part in $package.Split(',')) {
                if (-not [string]::IsNullOrWhiteSpace($part)) {
                    [void]$targets.Add($part.Trim())
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($InstallList)) {
        $resolvedPath = [Environment]::ExpandEnvironmentVariables($InstallList)
        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            throw "Install list not found: $resolvedPath"
        }

        $lines = Get-Content -LiteralPath $resolvedPath
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -and -not $trimmed.StartsWith('#')) {
                [void]$targets.Add($trimmed)
            }
        }
    }

    return @($targets | Select-Object -Unique)
}

function Invoke-WingetBatchInstall {
    if (-not (Test-WingetAvailable)) { return }

    $targets = @(Get-InstallPackageTargets)
    if ($targets.Count -eq 0) {
        Add-ReportItem -Category 'Winget' -Name 'Batch install' -Status 'Skipped' -Details 'No packages were provided.'
        Write-Step 'No packages were provided for batch install.' -Color Yellow
        return
    }

    foreach ($target in $targets) {
        if (-not $Apply) {
            Add-ReportItem -Category 'Winget' -Name "Install $target" -Status 'DryRun' -Details 'Showing package manifest only.'
            Invoke-WingetCommand -Name "Find package $target" -Arguments @('show', '--id', $target, '--exact', '--source', $WingetSource, '--accept-source-agreements', '--disable-interactivity')
            continue
        }

        Invoke-WingetCommand -Name "Install $target" -Arguments @(
            'install',
            '--id',
            $target,
            '--exact',
            '--source',
            $WingetSource,
            '--silent',
            '--accept-package-agreements',
            '--accept-source-agreements',
            '--disable-interactivity'
        )
    }
}

function Invoke-WingetBatchUninstall {
    if (-not (Test-WingetAvailable)) { return }

    $targets = @(Get-UninstallPackageTargets)
    if ($targets.Count -eq 0) {
        Add-ReportItem -Category 'Winget' -Name 'Batch uninstall' -Status 'Skipped' -Details 'No packages were provided.'
        Write-Step 'No packages were provided for batch uninstall.' -Color Yellow
        return
    }

    foreach ($target in $targets) {
        if (-not $Apply) {
            Add-ReportItem -Category 'Winget' -Name "Uninstall $target" -Status 'DryRun' -Details 'Showing installed package match only.'
            Invoke-WingetCommand -Name "Find installed package $target" -Arguments @('list', '--id', $target, '--exact', '--source', $WingetSource, '--accept-source-agreements', '--disable-interactivity')
            continue
        }

        Invoke-WingetCommand -Name "Uninstall $target" -Arguments @(
            'uninstall',
            '--id',
            $target,
            '--exact',
            '--source',
            $WingetSource,
            '--silent',
            '--accept-source-agreements',
            '--disable-interactivity'
        )
    }
}

function Get-BackupSourceFolders {
    $sources = New-Object System.Collections.ArrayList
    $validFolders = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos')
    $selectedFolders = @($BackupFolder | ForEach-Object { $_.Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

    foreach ($folderName in $selectedFolders) {
        if ($folderName -notin $validFolders) {
            Add-ReportItem -Category 'Backup' -Name $folderName -Status 'Skipped' -Details 'Unsupported backup folder name.'
            continue
        }

        if ($BackupMode -eq 'Local') {
            $localPath = Join-Path $script:UserProfile $folderName
            if (Test-Path -LiteralPath $localPath -PathType Container) {
                [void]$sources.Add([ordered]@{ Name = $folderName; Path = $localPath })
            }
            else {
                Add-ReportItem -Category 'Backup' -Name $folderName -Status 'Skipped' -Details "Local path not found: $localPath"
            }
            continue
        }

        $activePath = Get-ActiveUserFolderPath -Folder $folderName
        $fallbackLocalPath = Join-Path $script:UserProfile $folderName
        $seen = @{}

        if ($activePath -and (Test-Path -LiteralPath $activePath -PathType Container)) {
            [void]$sources.Add([ordered]@{ Name = $folderName; Path = $activePath })
            $seen[$activePath.ToLowerInvariant()] = $true
        }

        if ($fallbackLocalPath -and (Test-Path -LiteralPath $fallbackLocalPath -PathType Container) -and -not $seen.ContainsKey($fallbackLocalPath.ToLowerInvariant())) {
            $label = if ($activePath -and $activePath -ne $fallbackLocalPath) { "$folderName (local)" } else { $folderName }
            [void]$sources.Add([ordered]@{ Name = $label; Path = $fallbackLocalPath })
        }
    }

    return @($sources)
}

function Invoke-Backup {
    Write-Step ("Starting user backup. Mode={0}, Apply={1}" -f $BackupMode, [bool]$Apply) -Color Cyan

    if ([string]::IsNullOrWhiteSpace($BackupDestination)) {
        throw 'BackupDestination is required for Backup action.'
    }

    $destination = [Environment]::ExpandEnvironmentVariables($BackupDestination)
    $destination = $destination -replace '"', ''
    $destination = $destination.TrimEnd('\')

    if ([string]::IsNullOrWhiteSpace($destination)) {
        throw 'BackupDestination resolved to an empty path.'
    }

    $sources = @(Get-BackupSourceFolders)
    if ($sources.Count -eq 0) {
        Add-ReportItem -Category 'Backup' -Name 'User folders' -Status 'Skipped' -Details 'No valid source folders were found.'
        Write-Step 'No valid source folders were found for backup.' -Color Yellow
        return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $sessionDestination = Join-Path $destination "ps1-toolkit-backup-$env:USERNAME-$timestamp"
    $backupLog = Join-Path $sessionDestination "backup-$timestamp.log"

    if (-not $Apply) {
        foreach ($source in $sources) {
            $sourceBytes = Get-DirectorySize -Path $source.Path
            $targetPath = Join-Path $sessionDestination $source.Name
            Add-ReportItem -Category 'Backup' -Name $source.Name -Status 'DryRun' -Details ("Would copy {0} to {1}" -f $source.Path, $targetPath) -Bytes $sourceBytes
            Write-Step ("Dry run: would back up {0} from {1} ({2})" -f $source.Name, $source.Path, (Convert-Bytes $sourceBytes)) -Color Yellow
        }
        Add-ReportItem -Category 'Backup' -Name 'Destination' -Status 'DryRun' -Details $sessionDestination
        return
    }

    if (-not (Test-Path -LiteralPath $sessionDestination)) {
        New-Item -ItemType Directory -Path $sessionDestination -Force -ErrorAction Stop | Out-Null
    }

    "ps1-toolkit Backup" | Out-File -FilePath $backupLog -Encoding UTF8
    "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $backupLog -Append -Encoding UTF8
    "User: $env:USERNAME" | Out-File -FilePath $backupLog -Append -Encoding UTF8
    "Mode: $BackupMode" | Out-File -FilePath $backupLog -Append -Encoding UTF8
    "Destination: $sessionDestination" | Out-File -FilePath $backupLog -Append -Encoding UTF8
    ('-' * 60) | Out-File -FilePath $backupLog -Append -Encoding UTF8

    $failed = 0
    foreach ($source in $sources) {
        $targetPath = Join-Path $sessionDestination $source.Name
        if (-not (Test-Path -LiteralPath $targetPath)) {
            New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
        }

        Write-Step ("Backing up {0}: {1}" -f $source.Name, $source.Path) -Color Cyan
        "--- $($source.Name) ---" | Out-File -FilePath $backupLog -Append -Encoding UTF8
        "Source: $($source.Path)" | Out-File -FilePath $backupLog -Append -Encoding UTF8
        "Target: $targetPath" | Out-File -FilePath $backupLog -Append -Encoding UTF8

        & robocopy.exe $source.Path $targetPath /E /COPY:DAT /R:3 /W:3 /XJ /NDL /NFL /NP /LOG+:$backupLog
        $exitCode = $LASTEXITCODE

        if ($exitCode -ge 8) {
            $failed++
            Add-ReportItem -Category 'Backup' -Name $source.Name -Status "Failed $exitCode" -Details "Robocopy failed. See $backupLog"
            Write-Step ("Backup failed for {0}. Robocopy exit code {1}" -f $source.Name, $exitCode) -Color Red
        }
        elseif ($exitCode -eq 0) {
            Add-ReportItem -Category 'Backup' -Name $source.Name -Status 'NoChanges' -Details "Already up to date: $targetPath"
            Write-Step ("No changes for {0}" -f $source.Name) -Color Green
        }
        else {
            Add-ReportItem -Category 'Backup' -Name $source.Name -Status "Copied $exitCode" -Details "Copied to $targetPath"
            Write-Step ("Backed up {0}" -f $source.Name) -Color Green
        }

        '' | Out-File -FilePath $backupLog -Append -Encoding UTF8
    }

    "Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $backupLog -Append -Encoding UTF8
    "Failures: $failed" | Out-File -FilePath $backupLog -Append -Encoding UTF8
    Add-ReportItem -Category 'Backup' -Name 'Backup log' -Status 'Created' -Details $backupLog

    if ($failed -gt 0) {
        $script:Report.Totals.FailedItems += $failed
    }
}

function Save-Report {
    Initialize-ReportDirectory
    $script:Report.Completed = (Get-Date).ToString('s')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $jsonPath = Join-Path $ReportDirectory "ps1-toolkit-$stamp.json"
    $textPath = Join-Path $ReportDirectory "ps1-toolkit-$stamp.txt"

    $script:Report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('ps1-toolkit Report')
    [void]$lines.Add(('Started: {0}' -f $script:Report.Started))
    [void]$lines.Add(('Computer: {0}' -f $script:Report.ComputerName))
    [void]$lines.Add(('Action: {0}; Preset: {1}; Apply: {2}' -f $script:Report.Action, $script:Report.Preset, $script:Report.Apply))
    [void]$lines.Add('')
    foreach ($item in $script:Report.Items) {
        $size = if ($item.Bytes -gt 0) { " [$((Convert-Bytes $item.Bytes))]" } else { '' }
        [void]$lines.Add(('{0} | {1} | {2} | {3}{4}' -f $item.Category, $item.Name, $item.Status, $item.Details, $size))
    }
    [void]$lines.Add('')
    [void]$lines.Add(('Estimated cleanup: {0}' -f (Convert-Bytes $script:Report.Totals.EstimatedBytes)))
    [void]$lines.Add(('Removed: {0} in {1} items' -f (Convert-Bytes $script:Report.Totals.RemovedBytes), $script:Report.Totals.RemovedItems))
    [void]$lines.Add(('Failures: {0}' -f $script:Report.Totals.FailedItems))
    $lines | Set-Content -LiteralPath $textPath -Encoding UTF8

    Write-Step "Reports saved:" -Color Green
    Write-Host "  $textPath"
    Write-Host "  $jsonPath"
}

function Show-OptimizationMenu {
    Clear-InteractiveScreen
    Write-Host ''
    Write-Host 'Optimizations' -ForegroundColor Cyan
    Write-Host '1. Scan only'
    Write-Host '2. Safe cleanup dry-run'
    Write-Host '3. Apply safe cleanup'
    Write-Host '4. Apply standard cleanup'
    Write-Host '5. Optimize drives'
    Write-Host '6. Windows health repair'
    Write-Host '7. Full maintenance dry-run'
    Write-Host '8. Full maintenance apply'
    Write-Host '0. Back'
    Write-Host ''

    $choice = Read-Host 'Choose an optimization option'
    switch ($choice) {
        '1' { $script:InteractiveAction = 'Scan'; $script:InteractivePreset = 'Safe'; $script:InteractiveApply = $false }
        '2' { $script:InteractiveAction = 'Clean'; $script:InteractivePreset = 'Safe'; $script:InteractiveApply = $false }
        '3' { $script:InteractiveAction = 'Clean'; $script:InteractivePreset = 'Safe'; $script:InteractiveApply = $true }
        '4' { $script:InteractiveAction = 'Clean'; $script:InteractivePreset = 'Standard'; $script:InteractiveApply = $true }
        '5' { $script:InteractiveAction = 'Optimize'; $script:InteractivePreset = 'Safe'; $script:InteractiveApply = $false }
        '6' { $script:InteractiveAction = 'Health'; $script:InteractivePreset = 'Safe'; $script:InteractiveApply = $false }
        '7' { $script:InteractiveAction = 'All'; $script:InteractivePreset = 'Standard'; $script:InteractiveApply = $false }
        '8' { $script:InteractiveAction = 'All'; $script:InteractivePreset = 'Standard'; $script:InteractiveApply = $true }
        '0' { Show-InteractiveMenu }
        default { throw 'Invalid menu option.' }
    }
}

function Show-WingetMenu {
    Clear-InteractiveScreen
    Write-Host ''
    Write-Host 'Winget Tools' -ForegroundColor Cyan
    Write-Host '1. Preview software upgrades'
    Write-Host '2. Upgrade all software'
    Write-Host '3. Batch install dry-run'
    Write-Host '4. Batch install apply'
    Write-Host '5. Batch uninstall dry-run'
    Write-Host '6. Batch uninstall apply'
    Write-Host '0. Back'
    Write-Host ''

    $choice = Read-Host 'Choose a Winget option'
    switch ($choice) {
        '1' { $script:InteractiveAction = 'WingetUpgrade'; $script:InteractiveApply = $false }
        '2' { $script:InteractiveAction = 'WingetUpgrade'; $script:InteractiveApply = $true }
        '3' {
            $script:InteractiveAction = 'WingetInstall'
            $script:InteractiveApply = $false
            Read-InteractiveInstallTargets
        }
        '4' {
            $script:InteractiveAction = 'WingetInstall'
            $script:InteractiveApply = $true
            Read-InteractiveInstallTargets
        }
        '5' {
            $script:InteractiveAction = 'WingetUninstall'
            $script:InteractiveApply = $false
            Read-InteractiveUninstallTargets
        }
        '6' {
            $script:InteractiveAction = 'WingetUninstall'
            $script:InteractiveApply = $true
            Read-InteractiveUninstallTargets
        }
        '0' { Show-InteractiveMenu }
        default { throw 'Invalid menu option.' }
    }
}

function Read-InteractiveInstallTargets {
    Write-Host ''
    Write-Host 'Enter Winget package IDs separated by commas, or enter a path to a text file.'
    Write-Host 'Use winstall.app to find package IDs or build a reusable list.'
    Write-Host 'Example IDs: Google.Chrome, Mozilla.Firefox, 7zip.7zip'
    $inputValue = Read-Host 'IDs or file path'

    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        throw 'No install targets were entered.'
    }

    $candidatePath = [Environment]::ExpandEnvironmentVariables($inputValue.Trim('"'))
    if (Test-Path -LiteralPath $candidatePath) {
        $script:InteractiveInstallList = $candidatePath
        $script:InteractiveInstallPackage = @()
        return
    }

    $script:InteractiveInstallList = ''
    $script:InteractiveInstallPackage = @($inputValue.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Read-InteractiveUninstallTargets {
    Write-Host ''
    Write-Host 'Enter Winget package IDs separated by commas, or enter a path to a text file.'
    Write-Host 'Example IDs: Google.Chrome, Mozilla.Firefox, 7zip.7zip'
    $inputValue = Read-Host 'IDs or file path'

    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        throw 'No uninstall targets were entered.'
    }

    $candidatePath = [Environment]::ExpandEnvironmentVariables($inputValue.Trim('"'))
    if (Test-Path -LiteralPath $candidatePath) {
        $script:InteractiveUninstallList = $candidatePath
        $script:InteractiveUninstallPackage = @()
        return
    }

    $script:InteractiveUninstallList = ''
    $script:InteractiveUninstallPackage = @($inputValue.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Read-InteractiveBackupDestination {
    Write-Host ''
    Write-Host 'Enter the destination drive or folder for the backup.'
    Write-Host 'Example: D:\CustomerBackups'
    $inputValue = Read-Host 'Backup destination'

    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        throw 'No backup destination was entered.'
    }

    $script:InteractiveBackupDestination = $inputValue.Trim()
}

function Show-BackupMenu {
    Clear-InteractiveScreen
    Write-Host ''
    Write-Host 'Backup Tools' -ForegroundColor Cyan
    Write-Host '1. Preview OneDrive + local backup'
    Write-Host '2. Run OneDrive + local backup'
    Write-Host '3. Preview local-only backup'
    Write-Host '4. Run local-only backup'
    Write-Host '0. Back'
    Write-Host ''

    $choice = Read-Host 'Choose a backup option'
    switch ($choice) {
        '1' {
            $script:InteractiveAction = 'Backup'
            $script:InteractiveApply = $false
            $script:InteractiveBackupMode = 'All'
            Read-InteractiveBackupDestination
        }
        '2' {
            $script:InteractiveAction = 'Backup'
            $script:InteractiveApply = $true
            $script:InteractiveBackupMode = 'All'
            Read-InteractiveBackupDestination
        }
        '3' {
            $script:InteractiveAction = 'Backup'
            $script:InteractiveApply = $false
            $script:InteractiveBackupMode = 'Local'
            Read-InteractiveBackupDestination
        }
        '4' {
            $script:InteractiveAction = 'Backup'
            $script:InteractiveApply = $true
            $script:InteractiveBackupMode = 'Local'
            Read-InteractiveBackupDestination
        }
        '0' { Show-InteractiveMenu }
        default { throw 'Invalid menu option.' }
    }
}

function Show-InteractiveMenu {
    Clear-InteractiveScreen
    Write-Host ''
    Write-Host 'ps1-toolkit Technician Utility' -ForegroundColor Cyan
    Write-Host '1. Optimizations'
    Write-Host '2. Winget Tools'
    Write-Host '3. Backup Tools'
    Write-Host '0. Exit'
    Write-Host ''

    $choice = Read-Host 'Choose a section'
    switch ($choice) {
        '1' { Show-OptimizationMenu }
        '2' { Show-WingetMenu }
        '3' { Show-BackupMenu }
        '0' { $script:InteractiveExitRequested = $true }
        default { throw 'Invalid menu option.' }
    }
}

try {
    $script:Report.IsAdministrator = Test-IsAdministrator

    if ($Elevate -and -not $script:Report.IsAdministrator) {
        Write-Step 'Requesting Administrator elevation...' -Color Cyan
        Start-ElevatedSelf
        $script:SuppressKeepOpenPause = $true
        return
    }

    if ($Interactive) {
        $script:InteractiveAction = 'Scan'
        $script:InteractivePreset = 'Safe'
        $script:InteractiveApply = $false
        $script:InteractiveExitRequested = $false
        $script:InteractiveInstallPackage = @()
        $script:InteractiveInstallList = ''
        $script:InteractiveUninstallPackage = @()
        $script:InteractiveUninstallList = ''
        $script:InteractiveBackupDestination = ''
        $script:InteractiveBackupMode = 'All'
        Show-InteractiveMenu
        if ($script:InteractiveExitRequested) { return }
        $Action = $script:InteractiveAction
        $Preset = $script:InteractivePreset
        if ($script:InteractiveApply) { $Apply = $true } else { $Apply = $false }
        if ($script:InteractiveInstallPackage.Count -gt 0) { $InstallPackage = $script:InteractiveInstallPackage }
        if (-not [string]::IsNullOrWhiteSpace($script:InteractiveInstallList)) { $InstallList = $script:InteractiveInstallList }
        if ($script:InteractiveUninstallPackage.Count -gt 0) { $UninstallPackage = $script:InteractiveUninstallPackage }
        if (-not [string]::IsNullOrWhiteSpace($script:InteractiveUninstallList)) { $UninstallList = $script:InteractiveUninstallList }
        if (-not [string]::IsNullOrWhiteSpace($script:InteractiveBackupDestination)) { $BackupDestination = $script:InteractiveBackupDestination }
        if (-not [string]::IsNullOrWhiteSpace($script:InteractiveBackupMode)) { $BackupMode = $script:InteractiveBackupMode }
        $script:Report.Action = $Action
        $script:Report.Preset = $Preset
        $script:Report.Apply = [bool]$Apply
    }

    Write-Step "ps1-toolkit started. Admin=$($script:Report.IsAdministrator), Action=$Action, Preset=$Preset, Apply=$([bool]$Apply)" -Color Cyan

    switch ($Action) {
        'Scan' { Invoke-Scan }
        'Clean' { Invoke-Clean }
        'Optimize' { Invoke-Optimize }
        'Health' { Invoke-Health }
        'WingetUpgrade' { Invoke-WingetUpgrade }
        'WingetInstall' { Invoke-WingetBatchInstall }
        'WingetUninstall' { Invoke-WingetBatchUninstall }
        'Backup' { Invoke-Backup }
        'All' {
            Invoke-Scan
            Invoke-Clean
            Invoke-Optimize
            Invoke-Health
        }
    }
}
catch {
    Add-ReportItem -Category 'Runtime' -Name 'Unhandled error' -Status 'Failed' -Details $_.Exception.Message
    Write-Step "Failed: $($_.Exception.Message)" -Color Red
    exit 1
}
finally {
    Save-Report
    if ($KeepOpen -and -not $script:SuppressKeepOpenPause) {
        Write-Host ''
        Read-Host 'Press Enter to close ps1-toolkit'
    }
}
