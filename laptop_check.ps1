<#
  laptop_check.ps1 - inspect a used Windows 10/11 laptop before buying it.
  No Python or installs needed. Easiest: double-click Run-LaptopCheck.bat.

  Checks CPU, RAM, disks (health / SMART), battery wear, Windows version and
  activation, a short CPU stress test with temperatures, and uptime. Prints a
  report with red flags and saves it to a text file next to the script.

  Usage:
    powershell -ExecutionPolicy Bypass -File laptop_check.ps1 [-Seconds 60] [-SkipStress]
#>
param(
    [int]$Seconds = 30,
    [switch]$SkipStress,
    [switch]$NoElevate,
    [switch]$NoPause,
    [switch]$Elevated
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- elevation

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin -and -not $NoElevate -and -not $Elevated) {
    Write-Host 'Requesting administrator rights (needed for disk SMART data and temperatures)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevated', '-Seconds', $Seconds)
    if ($SkipStress) { $argList += '-SkipStress' }
    if ($NoPause) { $argList += '-NoPause' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -ErrorAction Stop
        Write-Host 'The check continues in the new window.'
        exit 0
    } catch {
        Write-Host "Administrator rights were not granted - continuing with limited data.`n"
    }
}

# ---------------------------------------------------------------- report helpers

$script:Lines = New-Object System.Collections.Generic.List[string]
$script:Flags = New-Object System.Collections.Generic.List[object]
$script:Section = ''
$Colors = @{ RED = 'Red'; YELLOW = 'Yellow'; NOTE = 'Cyan'; OK = 'Green'; HEAD = 'White' }

function Out-Line([string]$Text = '', [string]$Style = '') {
    if ($Style -and $Colors.ContainsKey($Style)) { Write-Host $Text -ForegroundColor $Colors[$Style] }
    else { Write-Host $Text }
    $script:Lines.Add($Text)
}
function Out-Section([string]$Title, [string]$Short) {
    $script:Section = $Short
    Out-Line
    Out-Line ('=' * 72) 'HEAD'
    Out-Line (' ' + $Title) 'HEAD'
    Out-Line ('=' * 72) 'HEAD'
}
function Out-KV([string]$Key, $Value) {
    Out-Line ('  ' + ($Key + ':').PadRight(34) + [string]$Value)
}
function Add-Flag([string]$Level, [string]$Message) {
    $script:Flags.Add([pscustomobject]@{ Level = $Level; Section = $script:Section; Message = $Message })
    Out-Line "  [$Level] $Message" $Level
}
function Out-Ok([string]$Message) { Out-Line "  [OK] $Message" 'OK' }

function Clean($s) { if ($null -eq $s) { return '' } return (([string]$s) -replace '\s+', ' ').Trim() }

function Size-Str($bytes, [switch]$Binary) {
    if (-not $bytes) { return 'n/a' }
    $div = 1e9
    if ($Binary) { $div = [math]::Pow(1024, 3) }
    $v = [double]$bytes / $div
    if ($v -ge 1000) { return ('{0:N2} TB' -f ($v / 1000)) }
    if ($v -ge 100 -or $v -eq [math]::Floor($v)) { return ('{0:N0} GB' -f $v) }
    return ('{0:N1} GB' -f $v)
}

function Duration-Str([double]$sec) {
    $ts = [TimeSpan]::FromSeconds($sec)
    $s = '{0} h {1} min' -f $ts.Hours, $ts.Minutes
    if ($ts.Days -eq 1) { $s = '1 day ' + $s } elseif ($ts.Days -gt 1) { $s = '{0} days {1}' -f $ts.Days, $s }
    return $s
}

function Get-Temps {
    $list = @()
    try {
        foreach ($z in @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)) {
            $list += [pscustomobject]@{ Source = 'ACPI'; C = [math]::Round($z.CurrentTemperature / 10.0 - 273.15, 1) }
        }
    } catch {}
    try {
        foreach ($z in @(Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop)) {
            $k = [double]$z.Temperature
            if ($z.HighPrecisionTemperature -gt 0) { $k = $z.HighPrecisionTemperature / 10.0 }
            $list += [pscustomobject]@{ Source = 'Perf'; C = [math]::Round($k - 273.15, 1) }
        }
    } catch {}
    return , @($list | Where-Object { $_.C -gt 5 -and $_.C -lt 130 })
}

function Get-CpuSample {
    $s = [ordered]@{ T = 0.0; Util = $null; PerfPct = $null; BaseMHz = $null; Temps = (Get-Temps); MaxT = $null }
    try {
        $p = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
        $s.Util = [double]$p.PercentProcessorTime
        $s.PerfPct = [double]$p.PercentProcessorPerformance
        $s.BaseMHz = [double]$p.ProcessorFrequency
    } catch {}
    if ($s.Temps.Count -gt 0) { $s.MaxT = ($s.Temps | Measure-Object -Property C -Maximum).Maximum }
    [pscustomobject]$s
}

function Get-MaxTemp($samples) {
    $v = @($samples | Where-Object { $null -ne $_.MaxT } | ForEach-Object { $_.MaxT })
    if ($v.Count -eq 0) { return $null }
    return ($v | Measure-Object -Maximum).Maximum
}

function Get-Avg($values) {
    $v = @($values | Where-Object { $null -ne $_ })
    if ($v.Count -eq 0) { return $null }
    return ($v | Measure-Object -Average).Average
}

function Collect-Samples([int]$Count, [int]$IntervalMs) {
    $null = Get-CpuSample  # first reading of performance counters is not reliable
    $out = @()
    for ($i = 0; $i -lt $Count; $i++) {
        Start-Sleep -Milliseconds $IntervalMs
        $out += Get-CpuSample
    }
    return , $out
}

function TempStr($v) { if ($null -eq $v) { return 'n/a' } return ('{0:N0} C' -f $v) }

$SmbiosTypes = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 27 = 'LPDDR'; 28 = 'LPDDR2'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
function MemType($code) {
    $c = [int]$code
    if ($SmbiosTypes.ContainsKey($c)) { return $SmbiosTypes[$c] }
    return 'unknown'
}

$OutDir = $PSScriptRoot
try { [IO.File]::WriteAllText((Join-Path $OutDir '.write_test'), 'x'); Remove-Item (Join-Path $OutDir '.write_test') -Force }
catch { $OutDir = [Environment]::GetFolderPath('Desktop') }
$Stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$Facts = [ordered]@{}

Out-Line 'USED LAPTOP INSPECTION REPORT' 'HEAD'
Out-Line 'Collecting data - this takes about a minute plus the stress test...'

# ---------------------------------------------------------------- 0. system

$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$prod = Get-CimInstance Win32_ComputerSystemProduct
Out-Section '0. SYSTEM' 'System'
$model = Clean $cs.Model
$pv = Clean $prod.Version
if ($pv -and $pv -notmatch '^(none|to be filled by o\.e\.m\.)$' -and -not $model.Contains($pv)) { $model = "$model ($pv)" }
Out-KV 'Manufacturer / model' ((Clean $cs.Manufacturer) + ' ' + $model)
Out-KV 'Serial number' (Clean $bios.SerialNumber)
$biosDate = 'date n/a'
if ($bios.ReleaseDate) { $biosDate = $bios.ReleaseDate.ToString('yyyy-MM-dd') }
Out-KV 'BIOS' ((Clean $bios.SMBIOSBIOSVersion) + "  ($biosDate)")
Out-KV 'Report time' (Get-Date -Format 'yyyy-MM-dd HH:mm')
if ($IsAdmin) { Out-KV 'Running as administrator' 'yes' } else { Out-KV 'Running as administrator' 'NO (some data will be missing)' }
Out-Line '  -> Compare model and serial with the sticker under the laptop and the ad.'
$Facts['Model'] = (Clean $cs.Manufacturer) + ' ' + $model

# ---------------------------------------------------------------- 1. CPU

Out-Section '1. CPU' 'CPU'
$cpus = @(Get-CimInstance Win32_Processor)
foreach ($c in $cpus) {
    Out-KV 'Model' (Clean $c.Name)
    Out-KV 'Physical cores' $c.NumberOfCores
    Out-KV 'Logical processors (threads)' $c.NumberOfLogicalProcessors
    Out-KV 'Base clock' "$($c.MaxClockSpeed) MHz"
}
Out-Line '  -> Make sure the CPU model matches exactly what the seller advertised.'
$cpu = $cpus[0]
$Facts['CPU'] = '{0} ({1}C/{2}T)' -f (Clean $cpu.Name), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors

# ---------------------------------------------------------------- 2. RAM

Out-Section '2. MEMORY (RAM)' 'RAM'
$mods = @(Get-CimInstance Win32_PhysicalMemory)
$arrays = @(Get-CimInstance Win32_PhysicalMemoryArray)
$installed = [double](($mods | Measure-Object -Property Capacity -Sum).Sum)
$visible = [double]$cs.TotalPhysicalMemory
$total = $installed
if (-not $total) { $total = $visible }
Out-KV 'Total installed' ((Size-Str $total -Binary) + '  (' + (Size-Str $visible -Binary) + ' usable by Windows)')
$types = @($mods | ForEach-Object { MemType $_.SMBIOSMemoryType } | Sort-Object -Unique)
if ($mods.Count -gt 0) { Out-KV 'Type' ($types -join ', ') }
$slots = [int](($arrays | Measure-Object -Property MemoryDevices -Sum).Sum)
if ($slots -gt 0) { Out-KV 'Slots used' "$($mods.Count) of $slots" } else { Out-KV 'Modules detected' $mods.Count }
foreach ($m in $mods) {
    $sp = 'speed n/a'
    if ($m.Speed) { $sp = "$($m.Speed) MT/s" }
    if ($m.ConfiguredClockSpeed -and $m.Speed -and $m.ConfiguredClockSpeed -ne $m.Speed) { $sp += " (running at $($m.ConfiguredClockSpeed))" }
    Out-Line ('    - {0}: {1}, {2}, {3}, {4} {5}' -f (Clean $m.DeviceLocator), (Size-Str $m.Capacity -Binary), (MemType $m.SMBIOSMemoryType), $sp, (Clean $m.Manufacturer), (Clean $m.PartNumber))
}
Out-Line '  -> Slot counts reported by laptops are not always accurate; soldered RAM'
Out-Line '     also appears as a module.'
$gib = $total / [math]::Pow(1024, 3)
if (-not $total) { Add-Flag 'YELLOW' 'Could not read RAM size.' }
elseif ($gib -lt 3.5) { Add-Flag 'RED' ('Only {0:N0} GB RAM - too little for Windows 11.' -f $gib) }
elseif ($gib -lt 7.5) { Add-Flag 'YELLOW' ('Only {0:N0} GB RAM - will feel slow; 8 GB minimum, 16 GB recommended.' -f $gib) }
else { Out-Ok ('{0:N0} GB RAM.' -f $gib) }
if ($mods.Count -eq 1 -and $slots -ge 2) { Add-Flag 'NOTE' 'Single RAM module with a free slot: runs single-channel (slower), but upgradeable.' }
$Facts['RAM'] = (Size-Str $total -Binary) + ' ' + ($types -join '/')

# ---------------------------------------------------------------- 3. storage

Out-Section '3. STORAGE' 'Storage'
$diskSummary = @()
$pdisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
if ($pdisks.Count -eq 0) { Add-Flag 'YELLOW' 'Could not list physical disks.' }
foreach ($d in $pdisks) {
    $name = Clean $d.FriendlyName
    if (-not $name) { $name = 'Unknown disk' }
    $bus = [string]$d.BusType
    $media = [string]$d.MediaType
    if ($media -eq 'Unspecified') { if ($bus -eq 'NVMe') { $media = 'SSD?' } else { $media = '?' } }
    $letters = ''
    try {
        $letters = (@(Get-Partition -DiskNumber $d.DeviceId -ErrorAction Stop | Where-Object { [string]$_.DriveLetter -match '^[A-Z]$' } | ForEach-Object { [string]$_.DriveLetter + ':' }) -join ' ')
    } catch {}
    if (-not $letters) { $letters = '-' }
    $health = [string]$d.HealthStatus
    $status = (@($d.OperationalStatus) | ForEach-Object { [string]$_ }) -join ', '

    Out-Line
    Out-Line "  Disk $($d.DeviceId): $name"
    Out-KV '    Capacity' (Size-Str $d.Size)
    Out-KV '    Type / interface' "$media / $bus"
    Out-KV '    Drive letters' $letters
    Out-KV '    Windows health status' "$health  ($status)"

    $rel = $null
    try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
    $wear = $null; $poh = $null; $temp = $null; $rerr = 0; $werr = 0
    if ($rel) {
        $wear = $rel.Wear; $poh = $rel.PowerOnHours; $temp = $rel.Temperature
        if ($rel.ReadErrorsUncorrected) { $rerr = [double]$rel.ReadErrorsUncorrected }
        if ($rel.WriteErrorsUncorrected) { $werr = [double]$rel.WriteErrorsUncorrected }
        if ($null -ne $wear) { Out-KV '    Wear (life used)' "$wear%" } else { Out-KV '    Wear (life used)' 'not reported' }
        if ($poh) { Out-KV '    Power-on hours' $poh } else { Out-KV '    Power-on hours' 'not reported' }
        if ($temp) { Out-KV '    Temperature' "$temp C" } else { Out-KV '    Temperature' 'not reported' }
        Out-KV '    Uncorrected R/W errors' "$rerr / $werr"
    } else {
        $why = ''
        if (-not $IsAdmin) { $why = ' (run as administrator)' }
        Out-KV '    SMART counters' ('unavailable' + $why)
    }

    if ($bus -eq 'USB') { Add-Flag 'NOTE' "$name is an external USB drive - not part of the laptop." }
    if ($health -and $health -ne 'Healthy') { Add-Flag 'RED' "${name}: Windows reports health '$health'." }
    if ($null -ne $wear -and $wear -ge 90) { Add-Flag 'RED' "${name}: $wear% of rated life used - near end of life." }
    elseif ($null -ne $wear -and $wear -ge 60) { Add-Flag 'YELLOW' "${name}: $wear% of rated life used." }
    if ($rerr -or $werr) { Add-Flag 'RED' "${name}: uncorrected read/write errors ($rerr/$werr)." }
    if ($poh -gt 25000) { Add-Flag 'YELLOW' ('{0}: {1} power-on hours (~{2:N1} years non-stop).' -f $name, $poh, ($poh / 8760)) }
    if ($temp -ge 70) { Add-Flag 'YELLOW' "${name}: running hot at $temp C." }
    if ($media -eq 'HDD' -and $bus -ne 'USB') { Add-Flag 'YELLOW' "$name is a mechanical hard drive - much slower than an SSD." }
    if ($bus -ne 'USB') {
        $kind = $media
        if ($bus -eq 'NVMe') { $kind = 'NVMe' }
        $diskSummary += ((Size-Str $d.Size) + ' ' + $kind)
    }
}
try {
    foreach ($p in @(Get-CimInstance -Namespace root/wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)) {
        if ($p.PredictFailure) { Add-Flag 'RED' ('SMART predicts imminent failure: ' + (Clean $p.InstanceName)) }
    }
} catch {}

# Optional: full SMART via smartctl (smartmontools), if installed or next to this script.
$smartctl = $null
$cmd = Get-Command smartctl -ErrorAction SilentlyContinue
if ($cmd) { $smartctl = $cmd.Source }
foreach ($c in @((Join-Path $PSScriptRoot 'smartctl.exe'), 'C:\Program Files\smartmontools\bin\smartctl.exe')) {
    if (-not $smartctl -and (Test-Path $c)) { $smartctl = $c }
}
Out-Line
if ($smartctl) {
    Out-Line "  Full SMART data from ${smartctl}:"
    $scan = $null
    try { $scan = (& $smartctl --scan-open -j | Out-String) | ConvertFrom-Json } catch {}
    foreach ($dev in @($scan.devices)) {
        if (-not $dev) { continue }
        $j = $null
        try { $j = (& $smartctl -a -j -d $dev.type $dev.name | Out-String) | ConvertFrom-Json } catch {}
        if (-not $j) { continue }
        $m = Clean $j.model_name
        if (-not $m) { $m = $dev.name }
        Out-Line "  smartctl: $m"
        if ($null -ne $j.smart_status) {
            if ($j.smart_status.passed) { Out-KV '    SMART overall' 'PASSED' }
            else { Out-KV '    SMART overall' 'FAILED'; Add-Flag 'RED' "${m}: SMART self-assessment FAILED." }
        }
        if ($j.power_on_time) { Out-KV '    Power-on hours' $j.power_on_time.hours }
        if ($j.temperature) { Out-KV '    Temperature' "$($j.temperature.current) C" }
        $nv = $j.nvme_smart_health_information_log
        if ($nv) {
            Out-KV '    Life used (NVMe)' "$($nv.percentage_used)%"
            Out-KV '    Available spare' "$($nv.available_spare)% (threshold $($nv.available_spare_threshold)%)"
            Out-KV '    Media errors' $nv.media_errors
            Out-KV '    Unsafe shutdowns' $nv.unsafe_shutdowns
            if ($null -ne $nv.data_units_written) { Out-KV '    Data written' ('{0:N1} TB' -f ($nv.data_units_written * 512000 / 1e12)) }
            if ($nv.critical_warning) { Add-Flag 'RED' "${m}: NVMe critical warning = $($nv.critical_warning)." }
            if ($nv.media_errors) { Add-Flag 'RED' "${m}: $($nv.media_errors) media/data-integrity errors." }
            if ($null -ne $nv.available_spare -and $nv.available_spare -le $nv.available_spare_threshold) { Add-Flag 'RED' "${m}: spare blocks exhausted." }
        }
        $labels = @{ 5 = 'Reallocated sectors'; 187 = 'Reported uncorrectable'; 197 = 'Pending sectors'; 198 = 'Offline uncorrectable' }
        if ($j.ata_smart_attributes) {
            foreach ($a in @($j.ata_smart_attributes.table)) {
                if ($labels.ContainsKey([int]$a.id)) {
                    $raw = $a.raw.value
                    Out-KV ('    ' + $labels[[int]$a.id]) $raw
                    if ($raw) { Add-Flag 'RED' ("${m}: " + $labels[[int]$a.id] + " = $raw (surface/flash damage).") }
                }
            }
        }
    }
} else {
    Out-Line '  (Optional: install smartmontools or put smartctl.exe next to this script'
    Out-Line '   for full SMART attributes.)'
}
$Facts['Storage'] = $diskSummary -join ', '

# ---------------------------------------------------------------- 4. battery

Out-Section '4. BATTERY' 'Battery'
$batts = @()
$xmlPath = Join-Path $env:TEMP "laptop_check_battery_$PID.xml"
$null = & powercfg /batteryreport /xml /output $xmlPath 2>&1
if (Test-Path $xmlPath) {
    try {
        [xml]$bx = Get-Content $xmlPath -Raw
        foreach ($b in @($bx.BatteryReport.Batteries.Battery)) {
            if ($b) {
                $batts += [pscustomobject]@{
                    Name = ((Clean $b.Manufacturer) + ' ' + (Clean $b.Id)).Trim(); Chemistry = Clean $b.Chemistry
                    ManufactureDate = Clean $b.ManufactureDate
                    Design = [double]$b.DesignCapacity; Full = [double]$b.FullChargeCapacity; Cycles = [double]$b.CycleCount
                }
            }
        }
    } catch {}
    Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
}
if ($batts.Count -eq 0) {
    # Fallback: battery data straight from WMI
    $design = @(); $full = @(); $cyc = @()
    try { $design = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction Stop | ForEach-Object { $_.DesignedCapacity }) } catch {}
    try { $full = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | ForEach-Object { $_.FullChargedCapacity }) } catch {}
    try { $cyc = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryCycleCount -ErrorAction Stop | ForEach-Object { $_.CycleCount }) } catch {}
    for ($i = 0; $i -lt [math]::Max($design.Count, $full.Count); $i++) {
        $batts += [pscustomobject]@{ Name = ''; Chemistry = ''; ManufactureDate = ''; Design = [double]$design[$i]; Full = [double]$full[$i]; Cycles = [double]$cyc[$i] }
    }
}
$w32b = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$minHealth = $null
if ($batts.Count -eq 0 -and $w32b.Count -eq 0) {
    Add-Flag 'RED' 'No battery detected! (removed, dead, or disconnected)'
} else {
    $n = 0
    foreach ($b in $batts) {
        $n++
        if ($batts.Count -gt 1) { Out-Line "  Battery ${n}:" }
        if ($b.Name) {
            $label = $b.Name
            if ($b.Chemistry) { $label += " ($($b.Chemistry))" }
            Out-KV 'Battery' $label
        }
        if ($b.ManufactureDate) { Out-KV 'Manufacture date' $b.ManufactureDate }
        if ($b.Design) { Out-KV 'Design capacity' ('{0:N0} mWh' -f $b.Design) } else { Out-KV 'Design capacity' 'n/a' }
        if ($b.Full) { Out-KV 'Current full-charge capacity' ('{0:N0} mWh' -f $b.Full) } else { Out-KV 'Current full-charge capacity' 'n/a' }
        if ($b.Design -and $b.Full) {
            $h = $b.Full / $b.Design * 100
            if ($null -eq $minHealth -or $h -lt $minHealth) { $minHealth = $h }
            Out-KV 'Battery health' ('{0:N0}%  (wear {1:N0}%)' -f $h, [math]::Max(0, 100 - $h))
            if ($h -lt 60) { Add-Flag 'RED' ('Battery health {0:N0}% - plan on replacing the battery.' -f $h) }
            elseif ($h -lt 80) { Add-Flag 'YELLOW' ('Battery health {0:N0}% - noticeably reduced runtime.' -f $h) }
            else { Out-Ok ('Battery health {0:N0}%.' -f $h) }
            if ($h -gt 105) { Add-Flag 'NOTE' 'Capacity above design value - battery may be new or poorly calibrated.' }
        } else {
            Add-Flag 'YELLOW' 'Battery capacity not reported - cannot calculate health.'
        }
        if ($b.Cycles) {
            Out-KV 'Charge cycles' $b.Cycles
            if ($b.Cycles -gt 800) { Add-Flag 'RED' "$($b.Cycles) charge cycles - battery is near end of life." }
            elseif ($b.Cycles -gt 500) { Add-Flag 'YELLOW' "$($b.Cycles) charge cycles - battery is well used." }
        } else {
            Out-KV 'Charge cycles' 'not reported by the battery'
        }
    }
    foreach ($w in $w32b) {
        $src = 'charger connected'
        if ($w.BatteryStatus -eq 1) { $src = 'on battery' }
        Out-KV 'Current charge' "$($w.EstimatedChargeRemaining)%  ($src)"
    }
    $html = Join-Path $OutDir "battery-report_$Stamp.html"
    $null = & powercfg /batteryreport /output $html 2>&1
    if (Test-Path $html) { Out-Line "  Detailed battery history saved to: $html" }
}
if ($null -ne $minHealth) { $Facts['Battery health'] = '{0:N0}%' -f $minHealth } else { $Facts['Battery health'] = 'n/a' }

# ---------------------------------------------------------------- 5. Windows

Out-Section '5. WINDOWS' 'Windows'
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$build = [int]$os.BuildNumber
Out-KV 'Edition' (Clean $os.Caption)
Out-KV 'Version' ('{0} (build {1}.{2}), {3}' -f $cv.DisplayVersion, $build, $cv.UBR, $os.OSArchitecture)
if ($build -lt 22000) { Add-Flag 'NOTE' 'This is Windows 10, not Windows 11.' }
Out-KV 'Installed / last major update' ('{0} ({1:N0} days ago)' -f $os.InstallDate.ToString('yyyy-MM-dd'), ((Get-Date) - $os.InstallDate).TotalDays)

$licStatus = @{ 0 = 'Unlicensed'; 1 = 'Licensed (activated)'; 2 = 'Initial grace period'; 3 = 'Additional grace period'; 4 = 'Non-genuine grace period'; 5 = 'Notification mode (NOT activated)'; 6 = 'Extended grace period' }
$lic = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue)
$activated = $null
if ($lic.Count -gt 0) {
    $main = @($lic | Sort-Object { $_.LicenseStatus -ne 1 })[0]
    $st = [int]$main.LicenseStatus
    $activated = ($st -eq 1)
    if ($licStatus.ContainsKey($st)) { Out-KV 'Activation' $licStatus[$st] } else { Out-KV 'Activation' "status $st" }
    $channel = Clean $main.ProductKeyChannel
    if (-not $channel) { $channel = Clean $main.Description }
    Out-KV 'License channel' $channel
    if ($activated) { Out-Ok 'Windows is activated.' } else { Add-Flag 'RED' 'Windows is NOT activated.' }
    if ((([string]$main.Description) + ([string]$main.ProductKeyChannel)).ToUpper().Contains('KMS') -and -not $cs.PartOfDomain) {
        Add-Flag 'YELLOW' 'Activated via KMS (volume license). On a home laptop this usually means an unofficial activator; it may stop being activated.'
    }
} else {
    Add-Flag 'YELLOW' 'Could not determine activation status (try running slmgr /xpr).'
}
$svc = Get-CimInstance SoftwareLicensingService -ErrorAction SilentlyContinue
if ($svc.OA3xOriginalProductKey) { Out-KV 'Factory license key in BIOS' ('yes - ' + (Clean $svc.OA3xOriginalProductKeyDescription)) }
else { Out-KV 'Factory license key in BIOS' 'no' }

# Is the device owned/managed by an organisation? (company / stolen laptops)
$managed = @()
$dsreg = (& dsregcmd /status 2>$null | Out-String)
if ($cs.PartOfDomain -or $dsreg -match '(?m)^\s*DomainJoined\s*:\s*YES') { $managed += "joined to domain '$(Clean $cs.Domain)'" }
if ($dsreg -match '(?m)^\s*AzureAdJoined\s*:\s*YES') { $managed += 'joined to Microsoft Entra ID (Azure AD)' }
if ($dsreg -match '(?m)^\s*EnterpriseJoined\s*:\s*YES') { $managed += 'enterprise joined' }
$mdm = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | Get-ItemProperty -ErrorAction SilentlyContinue | Where-Object { $_.ProviderID -eq 'MS DM Server' } | ForEach-Object { [string]$_.UPN })
if ($mdm.Count -gt 0) { $managed += ('enrolled in MDM (e.g. Intune): ' + ($mdm -join ', ')) }
$ap = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot' -ErrorAction SilentlyContinue
if ($ap.CloudAssignedTenantDomain) { $managed += "registered in Windows Autopilot to '$($ap.CloudAssignedTenantDomain)'" }
if ($managed.Count -gt 0) {
    Out-KV 'Organisation management' ($managed -join '; ')
    Add-Flag 'RED' ('Laptop is managed by an organisation (' + ($managed -join '; ') + '). It may be company property and can be locked remotely or after a reset - ask for proof.')
} else {
    Out-KV 'Organisation management' 'none detected'
}
$actText = 'activation unknown'
if ($activated -eq $true) { $actText = 'activated' } elseif ($activated -eq $false) { $actText = 'NOT activated' }
$Facts['Windows'] = (Clean $os.Caption) + ' - ' + $actText

# ---------------------------------------------------------------- 6. stress test

if (-not $SkipStress) {
    if ($Seconds -lt 5) { $Seconds = 5 }
    Out-Section "6. CPU STRESS TEST ($Seconds s) + TEMPERATURES" 'Stress test'
    Out-Line '  Tip: connect the charger and close other programs for a fair result.'
    Out-Line '  Measuring idle state...'
    $idle = Collect-Samples 3 1000

    $threads = [int]$cpu.NumberOfLogicalProcessors
    if ($threads -lt 1) { $threads = [Environment]::ProcessorCount }
    Out-Line "  Loading all $threads threads for $Seconds s..."
    $endTicks = [DateTime]::UtcNow.AddSeconds($Seconds).Ticks
    $pool = [runspacefactory]::CreateRunspacePool(1, $threads)
    $pool.Open()
    $jobs = @()
    $burn = {
        param($stopTicks)
        $x = 1.0
        while ([DateTime]::UtcNow.Ticks -lt $stopTicks) {
            for ($j = 0; $j -lt 20000; $j++) { $x = [math]::Sqrt($x + $j) }
        }
    }
    for ($i = 0; $i -lt $threads; $i++) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($burn).AddArgument($endTicks)
        $jobs += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    $load = @()
    $start = Get-Date
    $null = Get-CpuSample
    while ([DateTime]::UtcNow.Ticks -lt $endTicks) {
        Start-Sleep -Milliseconds 2000
        $s = Get-CpuSample
        $s.T = ((Get-Date) - $start).TotalSeconds
        $load += $s
        $mhz = 'clock n/a'
        if ($s.PerfPct -and $s.BaseMHz) { $mhz = '~{0:N2} GHz' -f ($s.BaseMHz * $s.PerfPct / 100 / 1000) }
        Out-Line ('    t={0,5:N1}s  CPU {1,5:N1}%  {2}  temp {3}' -f $s.T, $s.Util, $mhz, (TempStr $s.MaxT))
    }
    foreach ($j in $jobs) {
        try { [void]$j.PS.EndInvoke($j.Handle) } catch {}
        $j.PS.Dispose()
    }
    $pool.Close()

    Out-Line '  Cooling down for 10 s...'
    Start-Sleep -Seconds 8
    $after = Collect-Samples 2 1000

    $steady = $load
    if ($load.Count -gt 4) { $steady = $load[2..($load.Count - 1)] }
    $util = Get-Avg ($steady | ForEach-Object { $_.Util })
    $perf = Get-Avg ($steady | ForEach-Object { $_.PerfPct })
    $base = Get-Avg ($steady | ForEach-Object { $_.BaseMHz })
    if (-not $base) { $base = [double]$cpu.MaxClockSpeed }
    $tIdle = Get-MaxTemp $idle
    $tPeak = Get-MaxTemp $load
    $tEnd = $null
    if ($load.Count -gt 0) { $tEnd = $load[-1].MaxT }
    $tAfter = Get-MaxTemp $after

    Out-Line
    Out-KV 'Temperature before (idle)' (TempStr $tIdle)
    Out-KV 'Temperature peak under load' (TempStr $tPeak)
    Out-KV 'Temperature at end of load' (TempStr $tEnd)
    Out-KV 'Temperature after 10 s cooldown' (TempStr $tAfter)
    if ($null -ne $util) { Out-KV 'Average CPU load' ('{0:N0}%' -f $util) }
    if ($perf -and $base) { Out-KV 'Average clock under load' ('~{0:N0} MHz ({1:N0}% of base {2:N0} MHz)' -f ($base * $perf / 100), $perf, $base) }

    $allTemps = @(@($idle) + @($load) + @($after) | ForEach-Object { $_.Temps } | ForEach-Object { $_.C } | Sort-Object -Unique)
    if ($null -eq $tPeak) {
        Add-Flag 'NOTE' 'This laptop does not expose a temperature sensor to Windows. For exact CPU temperatures use HWiNFO or LibreHardwareMonitor (portable).'
    } elseif ($allTemps.Count -eq 1) {
        Add-Flag 'NOTE' ('Temperature sensor stays fixed at {0:N0} C - it is an ACPI zone, not the real CPU temperature. Use HWiNFO for real values.' -f $tPeak)
    } elseif ($tPeak -ge 95) {
        Add-Flag 'RED' ('CPU reached {0:N0} C - overheating (dust, dried thermal paste or fan problem).' -f $tPeak)
    } elseif ($tPeak -ge 88) {
        Add-Flag 'YELLOW' ('CPU reached {0:N0} C - running hot; cooling may need cleaning.' -f $tPeak)
    } else {
        Out-Ok ('Peak temperature {0:N0} C.' -f $tPeak)
    }
    if ($perf) {
        if ($perf -lt 50) { Add-Flag 'RED' ('CPU ran at only {0:N0}% of base clock under load - heavy throttling (overheating, failing fan, worn battery/charger or power-saving mode).' -f $perf) }
        elseif ($perf -lt 80) { Add-Flag 'YELLOW' ("CPU ran at {0:N0}% of base clock under load - some throttling. Check that the charger is connected and power mode is 'Best performance'." -f $perf) }
        else { Out-Ok 'No significant throttling detected.' }
    }
    if ($null -ne $util -and $util -lt 80) { Add-Flag 'NOTE' ('CPU load only reached {0:N0}% - the result may be less reliable.' -f $util) }
    if ($null -ne $tPeak) { $Facts['Peak CPU temperature'] = TempStr $tPeak }
}

# ---------------------------------------------------------------- 7. uptime

Out-Section '7. UPTIME' 'Uptime'
Out-KV 'Last boot' $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')
Out-KV 'Uptime' (Duration-Str ((Get-Date) - $os.LastBootUpTime).TotalSeconds)
$pw = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue
if ($pw.HiberbootEnabled -eq 1) { Out-Line "  -> Fast Startup is ON: 'Shut down' does not reset uptime, only 'Restart' does." }

# ---------------------------------------------------------------- summary

Out-Section 'SUMMARY' 'Summary'
foreach ($k in $Facts.Keys) { Out-KV $k $Facts[$k] }
$reds = @($script:Flags | Where-Object { $_.Level -eq 'RED' })
$yellows = @($script:Flags | Where-Object { $_.Level -eq 'YELLOW' })
$notes = @($script:Flags | Where-Object { $_.Level -eq 'NOTE' })
Out-Line
if ($reds.Count -gt 0) {
    Out-Line "  RED FLAGS ($($reds.Count)):" 'RED'
    foreach ($f in $reds) { Out-Line "   ! [$($f.Section)] $($f.Message)" 'RED' }
} else {
    Out-Line '  No red flags found.' 'OK'
}
if ($yellows.Count -gt 0) {
    Out-Line "  WARNINGS ($($yellows.Count)):" 'YELLOW'
    foreach ($f in $yellows) { Out-Line "   - [$($f.Section)] $($f.Message)" 'YELLOW' }
}
if ($notes.Count -gt 0) {
    Out-Line "  NOTES ($($notes.Count)):" 'NOTE'
    foreach ($f in $notes) { Out-Line "   * [$($f.Section)] $($f.Message)" 'NOTE' }
}
Out-Line
if ($reds.Count -gt 0) { Out-Line '  VERDICT: serious problems found - negotiate the price down or walk away.' 'RED' }
elseif ($yellows.Count -gt 0) { Out-Line '  VERDICT: usable, but take the warnings into account in the price.' 'YELLOW' }
else { Out-Line '  VERDICT: hardware looks healthy. Finish the manual checks below.' 'OK' }
Out-Line
Out-Line '  MANUAL CHECKS (the script cannot test these):'
Out-Line '  [ ] Screen: open a full-screen white, black, red, green and blue image - look for dead pixels,'
Out-Line '      bright spots and backlight bleed. Tilt the lid - no flicker or lines.'
Out-Line '  [ ] Keyboard & touchpad: type every key (e.g. keyboard-test website / Notepad), test clicks.'
Out-Line '  [ ] Ports: try every USB port, HDMI, headphone jack, SD reader; charge via USB-C if supported.'
Out-Line '  [ ] Webcam, microphone and speakers (Camera app, Voice Recorder, a YouTube video).'
Out-Line '  [ ] Wi-Fi and Bluetooth connect; hinges are firm; no cracks, swollen battery (lifted touchpad/case).'
Out-Line '  [ ] Charger: original wattage; unplug and replug - Windows should switch to charging.'
Out-Line '  [ ] BIOS: reboot and enter BIOS setup (F2/Del/F1/Esc) - it must NOT ask for a password.'
Out-Line '  [ ] Ask the seller to remove their Microsoft account / reset Windows in front of you.'

$reportPath = Join-Path $OutDir ("laptop_report_{0}_{1}.txt" -f $env:COMPUTERNAME, $Stamp)
try {
    [IO.File]::WriteAllLines($reportPath, $script:Lines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "`nReport saved to: $reportPath"
} catch {
    Write-Host "`nCould not save report: $_"
}

if (-not $NoPause) { [void](Read-Host "`nPress Enter to exit") }
