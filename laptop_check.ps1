<#
  laptop_check.ps1 - inspect a used Windows 10/11 laptop before buying it.
  No Python or installs needed. Easiest: double-click Run-LaptopCheck.bat.

  Checks CPU, RAM, disks (health / SMART), battery wear, Windows version and
  activation, a short CPU stress test with temperatures, uptime, the crash /
  hardware error history and a quick RAM test. Prints a report with red flags
  and saves it to a text file next to the script.

  Usage:
    powershell -ExecutionPolicy Bypass -File laptop_check.ps1 [-Seconds 60] [-SkipStress] [-SkipMemTest]
#>
param(
    [int]$Seconds = 30,
    [switch]$SkipStress,
    [switch]$SkipMemTest,
    [int]$MemTestSeconds = 45,
    [int]$HistoryDays = 90,
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
    $argList += @('-MemTestSeconds', $MemTestSeconds, '-HistoryDays', $HistoryDays)
    if ($SkipStress) { $argList += '-SkipStress' }
    if ($SkipMemTest) { $argList += '-SkipMemTest' }
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
Out-Line 'Collecting data - this takes about 3 minutes...'

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
    if ($bus -eq 'RAID' -and $name.ToUpper().Contains('NVME')) { $bus = 'NVMe (via Intel RST/VMD)' }  # Windows reports these NVMe drives as RAID
    $media = [string]$d.MediaType
    if ($media -eq 'Unspecified') { if ($bus.StartsWith('NVMe')) { $media = 'SSD?' } else { $media = '?' } }
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
        if ($bus.StartsWith('NVMe')) { $kind = 'NVMe' }
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
# Windows reports capacity in mWh; mAh = mWh / volts. Prefer the design (nominal)
# voltage, fall back to the voltage measured right now.
$volts = $null
$mvList = @($w32b | ForEach-Object { $_.DesignVoltage })
try { $mvList += @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop | ForEach-Object { $_.Voltage }) } catch {}
foreach ($mv in $mvList) {
    if (-not $volts -and $mv -ge 5000 -and $mv -le 25000) { $volts = $mv / 1000.0 }
}
function Cap-Str([double]$mwh) {
    $t = '{0:N0} mWh' -f $mwh
    if ($volts) { $t += ' (~{0:N0} mAh)' -f ($mwh / $volts) }
    return $t
}
$minHealth = $null
$battSummary = 'n/a'
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
        if ($b.Design) { Out-KV 'Original capacity (when new)' (Cap-Str $b.Design) } else { Out-KV 'Original capacity (when new)' 'n/a' }
        if ($b.Full) { Out-KV 'Capacity left (full charge)' (Cap-Str $b.Full) } else { Out-KV 'Capacity left (full charge)' 'n/a' }
        if ($b.Design -and $b.Full) {
            $h = $b.Full / $b.Design * 100
            $unit = 'mWh'; $scale = 1.0
            if ($volts) { $unit = 'mAh'; $scale = $volts }
            $left = '{0:N0} {2} of {1:N0} {2}' -f ($b.Full / $scale), ($b.Design / $scale), $unit
            Out-KV 'Remaining from original' ('{0:N0}%  = {1}  (lost {2:N0}%)' -f $h, $left, [math]::Max(0, 100 - $h))
            if ($null -eq $minHealth -or $h -lt $minHealth) {
                $minHealth = $h
                $battSummary = '{0:N0}% of original ({1})' -f $h, $left
            }
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
        if ($b.Design -and $b.Full -and ($b.Full / $b.Design) -lt 0.8 -and $b.Cycles -and $b.Cycles -lt 100) {
            Add-Flag 'NOTE' ('Only {0:N0} cycles but {1:N0}% capacity lost - the cycle counter may be unreliable, or the battery aged from time and heat.' -f $b.Cycles, (100 - $b.Full / $b.Design * 100))
        }
    }
    if ($volts) { Out-Line ("  -> mAh calculated from mWh at the battery's {0:N2} V." -f $volts) }
    foreach ($w in $w32b) {
        $src = 'charger connected'
        if ($w.BatteryStatus -eq 1) { $src = 'on battery' }
        Out-KV 'Charge level right now' "$($w.EstimatedChargeRemaining)%  ($src) - not battery health"
    }
    $html = Join-Path $OutDir "battery-report_$Stamp.html"
    $null = & powercfg /batteryreport /output $html 2>&1
    if (Test-Path $html) { Out-Line "  Detailed battery history saved to: $html" }
}
$Facts['Battery health'] = $battSummary

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

# ---------------------------------------------------------------- 8. error history

Out-Section "8. CRASH & HARDWARE ERROR HISTORY (last $HistoryDays days)" 'Error history'
# Bugcheck (blue screen) code -> name, likely cause, severity
$Bugchecks = @{
    0x0A = @('IRQL_NOT_LESS_OR_EQUAL', 'driver or RAM', 'YELLOW')
    0x1A = @('MEMORY_MANAGEMENT', 'RAM', 'RED')
    0x1E = @('KMODE_EXCEPTION_NOT_HANDLED', 'driver', 'NOTE')
    0x3B = @('SYSTEM_SERVICE_EXCEPTION', 'driver', 'NOTE')
    0x50 = @('PAGE_FAULT_IN_NONPAGED_AREA', 'RAM or driver', 'YELLOW')
    0x77 = @('KERNEL_STACK_INPAGE_ERROR', 'disk', 'RED')
    0x7A = @('KERNEL_DATA_INPAGE_ERROR', 'disk', 'RED')
    0x7E = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'driver', 'NOTE')
    0x9C = @('MACHINE_CHECK_EXCEPTION', 'CPU', 'RED')
    0x9F = @('DRIVER_POWER_STATE_FAILURE', 'driver', 'NOTE')
    0xD1 = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'driver', 'NOTE')
    0xEF = @('CRITICAL_PROCESS_DIED', 'software or disk', 'YELLOW')
    0xF4 = @('CRITICAL_OBJECT_TERMINATION', 'disk', 'RED')
    0x101 = @('CLOCK_WATCHDOG_TIMEOUT', 'CPU', 'RED')
    0x116 = @('VIDEO_TDR_FAILURE', 'GPU or graphics driver', 'YELLOW')
    0x119 = @('VIDEO_SCHEDULER_INTERNAL_ERROR', 'GPU or graphics driver', 'YELLOW')
    0x124 = @('WHEA_UNCORRECTABLE_ERROR', 'CPU/RAM hardware or overheating', 'RED')
    0x12B = @('FAULTY_HARDWARE_CORRUPTED_PAGE', 'RAM', 'RED')
    0x133 = @('DPC_WATCHDOG_VIOLATION', 'driver or SSD firmware', 'YELLOW')
    0x139 = @('KERNEL_SECURITY_CHECK_FAILURE', 'driver or RAM', 'YELLOW')
    0x154 = @('UNEXPECTED_STORE_EXCEPTION', 'disk', 'RED')
}
function Get-BugcheckInfo($code) {
    $c = [int64]$code
    if ($c -ge 0x10000000) { $c = $c -band 0xFFFFFF }  # e.g. 0x1000007E is the same crash as 0x7E
    $info = @('unknown', 'unknown', 'NOTE')
    if ($Bugchecks.ContainsKey([int]$c)) { $info = $Bugchecks[[int]$c] }
    return [pscustomobject]@{ Code = $c; Name = $info[0]; Cause = $info[1]; Level = $info[2] }
}

$since = (Get-Date).AddDays(-$HistoryDays)
$hist = @()
$queries = @(
    @{ ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 },
    @{ ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 },
    @{ ProviderName = 'Microsoft-Windows-WHEA-Logger' },
    @{ ProviderName = 'disk'; Id = @(7, 51, 153) },
    @{ ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' },
    @{ ProviderName = 'Microsoft-Windows-Eventlog'; Id = 104 }
)
foreach ($q in $queries) {
    $q.LogName = 'System'; $q.StartTime = $since
    $found = @()
    try { $found = @(Get-WinEvent -FilterHashtable $q -MaxEvents 300 -ErrorAction Stop) } catch {}
    foreach ($ev in $found) {
        $vals = @($ev.Properties | ForEach-Object { $_.Value })
        $code = $null; $button = $false
        if ($ev.Id -eq 41) {
            if ($vals.Count -gt 0) { $code = [int64]$vals[0] }
            if ($vals.Count -gt 6) { $button = ([int64]$vals[6] -ne 0) }
        } elseif ($ev.Id -eq 1001) {
            $m = [regex]::Match((($vals -join ' ') + ' ' + $ev.Message), '0x([0-9a-fA-F]{1,8})\b')
            if ($m.Success) { $code = [Convert]::ToInt64($m.Groups[1].Value, 16) }
        }
        $hist += [pscustomobject]@{ Time = $ev.TimeCreated; Provider = $ev.ProviderName; Id = $ev.Id; Level = [int]$ev.Level; Code = $code; Button = $button }
    }
}

$oldest = $null
try { $oldest = (Get-WinEvent -LogName System -MaxEvents 1 -Oldest -ErrorAction Stop).TimeCreated } catch {}
if ($oldest) {
    $covered = [int]((Get-Date) - $oldest).TotalDays
    Out-KV 'Event log goes back to' ('{0} ({1} days)' -f $oldest.ToString('yyyy-MM-dd'), $covered)
    if ($covered -lt 30) { Add-Flag 'NOTE' "The event log only goes back $covered days - older problems are not visible." }
}

# Blue screens: BugCheck 1001 events, plus Kernel-Power 41 with a bugcheck code
# that has no matching 1001 event (both are logged for the same crash).
$bsods = @($hist | Where-Object { $_.Provider -eq 'Microsoft-Windows-WER-SystemErrorReporting' -and $_.Code })
$power = @($hist | Where-Object { $_.Provider -eq 'Microsoft-Windows-Kernel-Power' })
foreach ($ev in $power) {
    if ($ev.Code) {
        $t = $ev.Time
        $dup = @($bsods | Where-Object { [math]::Abs(($_.Time - $t).TotalSeconds) -lt 900 })
        if ($dup.Count -eq 0) { $bsods += $ev }
    }
}
Out-KV 'Blue screens (BSOD)' $bsods.Count
$bsodRows = @($bsods | Sort-Object Time | ForEach-Object {
    $i = Get-BugcheckInfo $_.Code
    [pscustomobject]@{ Code = $i.Code; Name = $i.Name; Cause = $i.Cause; Level = $i.Level; Date = $_.Time.ToString('yyyy-MM-dd') }
})
foreach ($g in @($bsodRows | Group-Object Code)) {
    $f = $g.Group[0]
    $n = $g.Count
    Out-Line ('    - 0x{0:X} {1} x{2} (last {3}) -> likely cause: {4}' -f $f.Code, $f.Name, $n, @($g.Group)[-1].Date, $f.Cause)
    if ($f.Level -eq 'RED') { Add-Flag 'RED' ('Blue screen 0x{0:X} {1} x{2} - points to a {3} problem.' -f $f.Code, $f.Name, $n, $f.Cause) }
    elseif ($f.Level -eq 'YELLOW' -or $n -ge 3) { Add-Flag 'YELLOW' ('Blue screen 0x{0:X} {1} x{2} - possible {3} problem.' -f $f.Code, $f.Name, $n, $f.Cause) }
    else { Add-Flag 'NOTE' ('Blue screen 0x{0:X} {1} x{2} - usually a {3} issue.' -f $f.Code, $f.Name, $n, $f.Cause) }
}

$unexpected = @($power | Where-Object { -not $_.Code -and -not $_.Button })
$forced = @($power | Where-Object { -not $_.Code -and $_.Button })
Out-KV 'Unexpected shutdowns' "$($unexpected.Count)  (+$($forced.Count) forced off with the power button)"
if ($unexpected.Count -ge 3) { Add-Flag 'YELLOW' "$($unexpected.Count) unexpected shutdowns - possible overheating, power or battery problem." }
elseif ($unexpected.Count -gt 0) { Add-Flag 'NOTE' "$($unexpected.Count) unexpected shutdown(s) - can also be a dead battery or a power cut." }
if ($forced.Count -ge 3) { Add-Flag 'NOTE' "Forced off with the power button $($forced.Count) times - the laptop may freeze." }

$whea = @($hist | Where-Object { $_.Provider -eq 'Microsoft-Windows-WHEA-Logger' })
$wheaKinds = @{ 17 = 'corrected PCIe/bus error'; 18 = 'fatal CPU error'; 19 = 'corrected CPU error'; 47 = 'corrected memory error' }
Out-KV 'Hardware errors (WHEA)' $whea.Count
foreach ($g in @($whea | Group-Object Id, Level)) {
    $f = $g.Group[0]
    $kind = "hardware error (event $($f.Id))"
    if ($wheaKinds.ContainsKey([int]$f.Id)) { $kind = $wheaKinds[[int]$f.Id] }
    $fatal = ($f.Level -eq 1 -or $f.Level -eq 2)
    $last = (@($g.Group | Sort-Object Time)[-1]).Time.ToString('yyyy-MM-dd')
    $fatalText = ''
    if ($fatal) { $fatalText = ' (FATAL)' }
    Out-Line "    - $kind$fatalText x$($g.Count) (last $last)"
    if ($fatal) { Add-Flag 'RED' "Fatal hardware error logged x$($g.Count): $kind." }
    elseif ($f.Id -eq 19 -or $f.Id -eq 47) { Add-Flag 'YELLOW' "$kind x$($g.Count) - the CPU/RAM reported errors it had to correct." }
    else { Add-Flag 'NOTE' "$kind x$($g.Count) - often harmless, but worth noting." }
}

$diskEv = @($hist | Where-Object { $_.Provider -eq 'disk' })
Out-KV 'Disk errors in log' $diskEv.Count
foreach ($d in @(@(7, 'bad block on disk', 'RED'), @(51, 'disk paging error', 'YELLOW'), @(153, 'disk I/O retried', 'YELLOW'))) {
    $hits = @($diskEv | Where-Object { $_.Id -eq $d[0] } | Sort-Object Time)
    if ($hits.Count -gt 0) {
        Out-Line ('    - {0} x{1} (last {2})' -f $d[1], $hits.Count, $hits[-1].Time.ToString('yyyy-MM-dd'))
        Add-Flag $d[2] "Event log shows '$($d[1])' x$($hits.Count)."
    }
}

$memdiag = @($hist | Where-Object { $_.Provider -eq 'Microsoft-Windows-MemoryDiagnostics-Results' } | Sort-Object Time)
if ($memdiag.Count -gt 0) {
    $failed = @($memdiag | Where-Object { $_.Level -ge 1 -and $_.Level -le 3 })
    $txt = 'run {0} time(s), last {1}' -f $memdiag.Count, $memdiag[-1].Time.ToString('yyyy-MM-dd')
    if ($failed.Count -gt 0) { $txt += " - ERRORS FOUND $($failed.Count) time(s)" } else { $txt += ' - no errors' }
    Out-KV 'Windows Memory Diagnostic' $txt
    if ($failed.Count -gt 0) { Add-Flag 'RED' 'Windows Memory Diagnostic found RAM errors in the past.' }
} else {
    Out-KV 'Windows Memory Diagnostic' 'never run in this period'
}

$dumps = @()
try { $dumps = @(Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" -ErrorAction Stop | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.LastWriteTime.ToString('yyyy-MM-dd') }) } catch {}
if ($dumps.Count -gt 0) {
    Out-KV 'Crash dump files' "$($dumps.Count) (latest $($dumps[0]))"
    if ($bsods.Count -eq 0) { Add-Flag 'NOTE' "$($dumps.Count) crash dump file(s) exist (latest $($dumps[0])) - there were blue screens earlier than the event log shows." }
} else {
    Out-KV 'Crash dump files' 'none'
}

$cleared = @($hist | Where-Object { $_.Provider -eq 'Microsoft-Windows-Eventlog' -and $_.Id -eq 104 })
if ($cleared.Count -gt 0) {
    $dates = (@($cleared | ForEach-Object { $_.Time.ToString('yyyy-MM-dd') } | Sort-Object -Unique)) -join ', '
    Out-KV 'Event log cleared' $dates
    Add-Flag 'YELLOW' "The System event log was cleared ($dates) - earlier history is gone. Can be innocent (cleanup tools), but ask why."
}
if ($bsods.Count + $unexpected.Count + $whea.Count + $diskEv.Count + $cleared.Count -eq 0) { Out-Ok 'No crashes or hardware errors logged.' }
$Facts["Last $HistoryDays days"] = '{0} BSOD, {1} hardware errors, {2} unexpected shutdowns' -f $bsods.Count, $whea.Count, $unexpected.Count

# ---------------------------------------------------------------- 9. quick RAM test

$MemTestCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class LaptopMemTest {
    [StructLayout(LayoutKind.Sequential)]
    private class MemStatus {
        public uint Length = 64; public uint Load;
        public ulong TotalPhys; public ulong AvailPhys; public ulong TotalPage; public ulong AvailPage;
        public ulong TotalVirtual; public ulong AvailVirtual; public ulong AvailExtended;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx([In, Out] MemStatus status);

    public static ulong TotalPhysical() { MemStatus s = new MemStatus(); GlobalMemoryStatusEx(s); return s.TotalPhys; }
    public static ulong AvailablePhysical() { MemStatus s = new MemStatus(); GlobalMemoryStatusEx(s); return s.AvailPhys; }

    public static byte[][] Allocate(long target, int chunkSize) {
        List<byte[]> list = new List<byte[]>();
        try {
            while ((long)(list.Count + 1) * chunkSize <= target) list.Add(new byte[chunkSize]);
        } catch (OutOfMemoryException) {
            if (list.Count > 0) list.RemoveAt(list.Count - 1);
        }
        return list.ToArray();
    }

    // Writes every chunk first, then verifies all of them, so a write that
    // corrupts another address is caught too. Returns corrupted 4 KB blocks.
    public static long Pass(byte[][] chunks, int mode, int pass) {
        for (int c = 0; c < chunks.Length; c++) Fill(chunks[c], mode, Seed(c, pass));
        long bad = 0;
        for (int c = 0; c < chunks.Length; c++) bad += Verify(chunks[c], mode, Seed(c, pass));
        return bad;
    }

    private static uint Seed(int chunk, int pass) {
        uint s = ((uint)(chunk + 1) * 2654435761u) ^ ((uint)pass * 40503u);
        return s == 0 ? 1u : s;
    }

    private static byte Fixed(int mode) {
        switch (mode) { case 0: return 0x00; case 1: return 0xFF; case 2: return 0x55; default: return 0xAA; }
    }

    private static void Fill(byte[] b, int mode, uint x) {
        if (mode < 4) { byte v = Fixed(mode); for (int i = 0; i < b.Length; i++) b[i] = v; return; }
        for (int i = 0; i < b.Length; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; b[i] = (byte)x; }
    }

    private static long Verify(byte[] b, int mode, uint x) {
        long bad = 0;
        bool blockBad = false;
        byte v = Fixed(mode);
        for (int i = 0; i < b.Length; i++) {
            byte expect = v;
            if (mode == 4) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; expect = (byte)x; }
            if (b[i] != expect) blockBad = true;
            if ((i & 4095) == 4095) { if (blockBad) bad++; blockBad = false; }
        }
        if (blockBad) bad++;
        return bad;
    }
}
'@

if (-not $SkipMemTest) {
    if ($MemTestSeconds -lt 5) { $MemTestSeconds = 5 }
    Out-Section '9. QUICK MEMORY (RAM) TEST' 'Memory test'
    $memReady = $true
    try { if (-not ('LaptopMemTest' -as [type])) { Add-Type -TypeDefinition $MemTestCode -Language CSharp -ErrorAction Stop } }
    catch { $memReady = $false; Add-Flag 'YELLOW' "Could not start the RAM test: $($_.Exception.Message)" }
    if ($memReady) {
        $totalPhys = [double][LaptopMemTest]::TotalPhysical()
        # Use 60% of the free RAM (max 8 GB) so Windows and open apps keep running normally.
        $target = [math]::Min([double][LaptopMemTest]::AvailablePhysical() * 0.6, 8GB)
        $chunks = [LaptopMemTest]::Allocate([int64]$target, 64MB)
        if ($chunks.Length -eq 0) {
            Add-Flag 'YELLOW' 'Not enough free memory for the RAM test.'
        } else {
            $tested = [double]$chunks.Length * 64MB
            Out-KV 'Memory tested' ('{0} of {1} ({2:N0}% - the part that was free)' -f (Size-Str $tested -Binary), (Size-Str $totalPhys -Binary), ($tested / $totalPhys * 100))
            Out-Line "  Writing and verifying patterns for about $MemTestSeconds s..."
            $patternNames = @('zeros', 'ones', '0x55', '0xAA', 'random')
            $badBlocks = [int64]0
            $pass = 0
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $finished = $false
            while (-not $finished) {
                for ($mode = 0; $mode -lt 5; $mode++) {
                    $pass++
                    $t0 = $sw.Elapsed.TotalSeconds
                    $errs = [LaptopMemTest]::Pass($chunks, $mode, $pass)
                    $badBlocks += $errs
                    $res = 'OK'
                    if ($errs -gt 0) { $res = "$errs corrupted 4 KB blocks" }
                    Out-Line ('    pass {0} ({1}): {2}  [{3:N1} s]' -f $pass, $patternNames[$mode], $res, ($sw.Elapsed.TotalSeconds - $t0))
                    if ($pass -ge 5 -and $sw.Elapsed.TotalSeconds -ge $MemTestSeconds) { $finished = $true; break }
                }
            }
            $chunks = $null
            [GC]::Collect()
            if ($badBlocks -gt 0) {
                Add-Flag 'RED' "RAM test found $badBlocks corrupted 4 KB blocks - faulty memory. Confirm with MemTest86 before buying."
                $Facts['RAM test'] = 'ERRORS FOUND ({0} tested, {1} passes)' -f (Size-Str $tested -Binary), $pass
            } else {
                Out-Ok ('No errors in {0} over {1} passes.' -f (Size-Str $tested -Binary), $pass)
                $Facts['RAM test'] = 'OK ({0} tested, {1} passes)' -f (Size-Str $tested -Binary), $pass
            }
            Out-Line '  -> Quick test of the free memory only. A full test: MemTest86 from a USB stick'
            Out-Line '     (1+ hour) or Windows Memory Diagnostic (mdsched.exe, needs a restart).'
        }
    }
}

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
