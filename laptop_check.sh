#!/usr/bin/env bash
#
# laptop_check.sh - inspect a used Windows 10/11 laptop before buying it.
#
# This is the bash port of laptop_check.py / laptop_check.ps1: it runs the same
# checks (CPU, RAM, disks/SMART, battery wear, Windows activation and
# management, a CPU stress test that verifies every calculation, uptime, the
# crash/hardware error history and a quick RAM test) and prints the same style
# of report with red flags, warnings and a verdict.
#
# It is meant to run from Git Bash / MSYS2 / Cygwin on Windows. All hardware
# data comes from tools built into Windows (PowerShell / CIM, powercfg,
# dsregcmd); bash only holds the decision logic and the report.
#
# Usage:
#   ./laptop_check.sh                       full check, 30 s stress test
#   ./laptop_check.sh --seconds 60          longer stress test
#   ./laptop_check.sh --skip-stress         no stress test
#   ./laptop_check.sh --skip-memtest        no RAM test
#
# Run as administrator for full disk SMART data and temperatures.

export LC_ALL=C

# --------------------------------------------------------------------------
# Environment detection
# --------------------------------------------------------------------------

detect_powershell() {
    POWERSHELL=""
    local c
    for c in powershell.exe pwsh.exe powershell pwsh; do
        if command -v "$c" >/dev/null 2>&1; then
            POWERSHELL="$c"
            break
        fi
    done
    if [ -n "$POWERSHELL" ]; then HAVE_PS=1; else HAVE_PS=0; fi
}

detect_timeout() {
    TIMEOUT_CMD=""
    if command -v timeout >/dev/null 2>&1; then TIMEOUT_CMD="timeout"; fi
}

detect_powershell
detect_timeout

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd || printf '%s' "$PWD")

# The tool needs Windows (a Windows shell or a reachable powershell.exe).
is_windows() {
    case "$(uname -s 2>/dev/null)" in
        MINGW* | MSYS* | CYGWIN* | Windows_NT) return 0 ;;
    esac
    [ "${HAVE_PS:-0}" = "1" ]
}

# --------------------------------------------------------------------------
# Lookup tables (identical to laptop_check.py)
# --------------------------------------------------------------------------

WINDOWS_APP_ID="55c92734-d682-4d71-983e-d6ec3f16059f"

memtype() {
    case "${1:-}" in
        20) printf 'DDR' ;;
        21) printf 'DDR2' ;;
        24) printf 'DDR3' ;;
        26) printf 'DDR4' ;;
        27) printf 'LPDDR' ;;
        28) printf 'LPDDR2' ;;
        29) printf 'LPDDR3' ;;
        30) printf 'LPDDR4' ;;
        34) printf 'DDR5' ;;
        35) printf 'LPDDR5' ;;
        *) printf 'unknown' ;;
    esac
}

license_status() {
    case "${1:-}" in
        0) printf 'Unlicensed' ;;
        1) printf 'Licensed (activated)' ;;
        2) printf 'Initial grace period' ;;
        3) printf 'Additional grace period' ;;
        4) printf 'Non-genuine grace period' ;;
        5) printf 'Notification mode (NOT activated)' ;;
        6) printf 'Extended grace period' ;;
        *) printf 'status %s' "${1:-}" ;;
    esac
}

# bugcheck_info <code> -> "code|name|cause|level"
bugcheck_info() {
    local code="${1:-0}"
    case "$code" in
        '' | *[!0-9]*) code=0 ;;
    esac
    if [ "$code" -ge 268435456 ]; then # 0x10000000, e.g. 0x1000007E == 0x7E
        code=$((code & 0xFFFFFF))
    fi
    local name cause level
    case "$code" in
        10) name=IRQL_NOT_LESS_OR_EQUAL; cause="driver or RAM"; level=YELLOW ;;
        26) name=MEMORY_MANAGEMENT; cause="RAM"; level=RED ;;
        30) name=KMODE_EXCEPTION_NOT_HANDLED; cause="driver"; level=NOTE ;;
        59) name=SYSTEM_SERVICE_EXCEPTION; cause="driver"; level=NOTE ;;
        80) name=PAGE_FAULT_IN_NONPAGED_AREA; cause="RAM or driver"; level=YELLOW ;;
        119) name=KERNEL_STACK_INPAGE_ERROR; cause="disk"; level=RED ;;
        122) name=KERNEL_DATA_INPAGE_ERROR; cause="disk"; level=RED ;;
        126) name=SYSTEM_THREAD_EXCEPTION_NOT_HANDLED; cause="driver"; level=NOTE ;;
        156) name=MACHINE_CHECK_EXCEPTION; cause="CPU"; level=RED ;;
        159) name=DRIVER_POWER_STATE_FAILURE; cause="driver"; level=NOTE ;;
        209) name=DRIVER_IRQL_NOT_LESS_OR_EQUAL; cause="driver"; level=NOTE ;;
        239) name=CRITICAL_PROCESS_DIED; cause="software or disk"; level=YELLOW ;;
        244) name=CRITICAL_OBJECT_TERMINATION; cause="disk"; level=RED ;;
        257) name=CLOCK_WATCHDOG_TIMEOUT; cause="CPU"; level=RED ;;
        278) name=VIDEO_TDR_FAILURE; cause="GPU or graphics driver"; level=YELLOW ;;
        281) name=VIDEO_SCHEDULER_INTERNAL_ERROR; cause="GPU or graphics driver"; level=YELLOW ;;
        292) name=WHEA_UNCORRECTABLE_ERROR; cause="CPU/RAM hardware or overheating"; level=RED ;;
        299) name=FAULTY_HARDWARE_CORRUPTED_PAGE; cause="RAM"; level=RED ;;
        307) name=DPC_WATCHDOG_VIOLATION; cause="driver or SSD firmware"; level=YELLOW ;;
        313) name=KERNEL_SECURITY_CHECK_FAILURE; cause="driver or RAM"; level=YELLOW ;;
        340) name=UNEXPECTED_STORE_EXCEPTION; cause="disk"; level=RED ;;
        *) name=unknown; cause=unknown; level=NOTE ;;
    esac
    printf '%s|%s|%s|%s' "$code" "$name" "$cause" "$level"
}

bugcheck_name() {
    local info
    info=$(bugcheck_info "${1:-}")
    printf '%s' "${info#*|}"; :
}
bugcheck_cause() {
    local info
    info=$(bugcheck_info "${1:-}")
    info=${info#*|}
    printf '%s' "${info#*|}"
}
bugcheck_level() {
    local info
    info=$(bugcheck_info "${1:-}")
    printf '%s' "${info##*|}"
}

# --------------------------------------------------------------------------
# Formatting helpers
# --------------------------------------------------------------------------

# size_str <bytes> [binary] - same rounding as laptop_check.py
size_str() {
    awk -v n="${1-}" -v binary="${2-}" 'BEGIN{
        if (n == "" || n + 0 == 0) { print "n/a"; exit }
        div = 1000000000
        if (binary == "binary" || binary == "1" || binary == "true") div = 1024 * 1024 * 1024
        v = n / div
        if (v >= 1000) printf "%.2f TB\n", v / 1000
        else if (v >= 100 || v == int(v)) printf "%.0f GB\n", v
        else printf "%.1f GB\n", v
    }'
}

duration_str() {
    awk -v s="${1:-0}" 'BEGIN{
        s = int(s); if (s < 0) s = 0
        d = int(s / 86400); rem = s % 86400
        h = int(rem / 3600); m = int((rem % 3600) / 60)
        out = ""
        if (d == 1) out = "1 day "
        else if (d > 1) out = d " days "
        printf "%s%d h %d min\n", out, h, m
    }'
}

clean() {
    printf '%s' "${1-}" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# fmt <value> <printf-format>
fmt() { awk -v x="${1-0}" -v f="$2" 'BEGIN{printf f "\n", x + 0}'; }

# thousands <value> - integer with thousand separators
thousands() {
    awk -v x="${1-0}" 'BEGIN{
        n = sprintf("%.0f", x + 0)
        sign = ""
        if (substr(n, 1, 1) == "-") { sign = "-"; n = substr(n, 2) }
        s = n; out = ""
        while (length(s) > 3) {
            out = "," substr(s, length(s) - 2) out
            s = substr(s, 1, length(s) - 3)
        }
        print sign s out
    }'
}

lt() { awk -v a="${1-0}" -v b="${2-0}" 'BEGIN{exit !(a + 0 < b + 0)}'; }
le() { awk -v a="${1-0}" -v b="${2-0}" 'BEGIN{exit !(a + 0 <= b + 0)}'; }
gt() { awk -v a="${1-0}" -v b="${2-0}" 'BEGIN{exit !(a + 0 > b + 0)}'; }
ge() { awk -v a="${1-0}" -v b="${2-0}" 'BEGIN{exit !(a + 0 >= b + 0)}'; }

verdict_for() { # reds yellows notes
    local reds="${1:-0}" yellows="${2:-0}"
    if [ "$reds" -gt 0 ]; then
        printf 'RED'
    elif [ "$yellows" -gt 0 ]; then
        printf 'YELLOW'
    else
        printf 'OK'
    fi
}

# --------------------------------------------------------------------------
# Report output (writes to stdout and keeps every line for the text file)
# --------------------------------------------------------------------------

REPORT_LINES=()
FLAG_LEVELS=()
FLAG_SECTIONS=()
FLAG_MSGS=()
SECTION_NAME=""
USE_COLOR=0

paint() {
    local text="$1" style="${2-}"
    if [ "$USE_COLOR" = "1" ]; then
        case "$style" in
            RED) printf '\033[91m%s\033[0m' "$text" ;;
            YELLOW) printf '\033[93m%s\033[0m' "$text" ;;
            NOTE) printf '\033[96m%s\033[0m' "$text" ;;
            OK) printf '\033[92m%s\033[0m' "$text" ;;
            HEAD) printf '\033[1m%s\033[0m' "$text" ;;
            *) printf '%s' "$text" ;;
        esac
    else
        printf '%s' "$text"
    fi
}

rep_line() {
    local text="${1-}" style="${2-}"
    if [ -n "$style" ]; then
        printf '%s\n' "$(paint "$text" "$style")"
    else
        printf '%s\n' "$text"
    fi
    REPORT_LINES+=("$text")
}

rep_section() {
    SECTION_NAME="$2"
    local bar
    printf -v bar '%*s' 72 ''
    bar=${bar// /=}
    rep_line ""
    rep_line "$bar" HEAD
    rep_line " $1" HEAD
    rep_line "$bar" HEAD
}

rep_kv() {
    local key="$1" value="${2-}" k
    printf -v k '%-34s' "${key}:"
    rep_line "  ${k}${value}"
}

rep_flag() {
    local level="$1" msg="$2"
    FLAG_LEVELS+=("$level")
    FLAG_SECTIONS+=("$SECTION_NAME")
    FLAG_MSGS+=("$msg")
    rep_line "  [$level] $msg" "$level"
}

rep_ok() { rep_line "  [OK] $1" "OK"; }

# --------------------------------------------------------------------------
# PowerShell bridge
# --------------------------------------------------------------------------

PS_PREFIX="\$ProgressPreference='SilentlyContinue';\$WarningPreference='SilentlyContinue';[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;"

ps_run() {
    local script="$1" t="${2:-120}" enc
    [ "${HAVE_PS:-0}" = "1" ] || return 1
    enc=$(printf '%s\n' "${PS_PREFIX}${script}" | iconv -f UTF-8 -t UTF-16LE 2>/dev/null | base64 | tr -d '\r\n')
    [ -n "$enc" ] || return 1
    if [ -n "${TIMEOUT_CMD:-}" ]; then
        "$TIMEOUT_CMD" "$t" "$POWERSHELL" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
            -EncodedCommand "$enc" 2>/dev/null
    else
        "$POWERSHELL" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
            -EncodedCommand "$enc" 2>/dev/null
    fi
}

# Read "key<TAB>value" lines from stdin into the associative array named by $1.
load_kv() {
    local -n __arr="$1"
    local line k v
    while IFS= read -r line; do
        line=${line%$'\r'}
        [ -n "$line" ] || continue
        case "$line" in
            *$'\t'*) ;;
            *) continue ;;
        esac
        k=${line%%$'\t'*}
        v=${line#*$'\t'}
        __arr["$k"]="$v"
    done
}

read -r -d '' PS_SYSTEM <<'PSEOF_SYSTEM' || true
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$prod = Get-CimInstance Win32_ComputerSystemProduct
$biosDate = ''
if ($bios.ReleaseDate) { $biosDate = $bios.ReleaseDate.ToString('yyyy-MM-dd') }
"Manufacturer`t$($cs.Manufacturer)"
"Model`t$($cs.Model)"
"ProductVersion`t$($prod.Version)"
"Serial`t$($bios.SerialNumber)"
"BiosVersion`t$($bios.SMBIOSBIOSVersion)"
"BiosDate`t$biosDate"
"PartOfDomain`t$($cs.PartOfDomain)"
"Domain`t$($cs.Domain)"
"ComputerName`t$env:COMPUTERNAME"
PSEOF_SYSTEM

read -r -d '' PS_CPU <<'PSEOF_CPU' || true
Get-CimInstance Win32_Processor | ForEach-Object {
  "CPU|$($_.Name)|$($_.NumberOfCores)|$($_.NumberOfLogicalProcessors)|$($_.MaxClockSpeed)"
}
PSEOF_CPU

read -r -d '' PS_RAM <<'PSEOF_RAM' || true
$cs = Get-CimInstance Win32_ComputerSystem
Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
  "MOD|$($_.Capacity)|$($_.Speed)|$($_.ConfiguredClockSpeed)|$($_.SMBIOSMemoryType)|$($_.Manufacturer)|$($_.PartNumber)|$($_.DeviceLocator)|x"
}
Get-CimInstance Win32_PhysicalMemoryArray | ForEach-Object { "ARR|$($_.MemoryDevices)|x" }
"VISIBLE|$($cs.TotalPhysicalMemory)|x"
PSEOF_RAM

read -r -d '' PS_DISKS <<'PSEOF_DISKS' || true
foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
  $rel = $null
  try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
  $letters = ''
  try { $letters = (@(Get-Partition -DiskNumber $d.DeviceId -ErrorAction Stop | Where-Object { [string]$_.DriveLetter -match '^[A-Z]$' } | ForEach-Object { [string]$_.DriveLetter + ':' }) -join ' ') } catch {}
  $status = (@($d.OperationalStatus) | ForEach-Object { [string]$_ }) -join ', '
  $wear = ''; $poh = ''; $temp = ''; $rerr = ''; $werr = ''
  if ($rel) {
    $wear = $rel.Wear; $poh = $rel.PowerOnHours; $temp = $rel.Temperature
    $rerr = $rel.ReadErrorsUncorrected; $werr = $rel.WriteErrorsUncorrected
  }
  "DISK|$($d.DeviceId)|$($d.FriendlyName)|$($d.Size)|$([string]$d.MediaType)|$([string]$d.BusType)|$([string]$d.HealthStatus)|$status|$letters|$wear|$poh|$temp|$rerr|$werr|x"
}
try {
  foreach ($p in @(Get-CimInstance -Namespace root/wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)) {
    if ($p.PredictFailure) { "PRED|$($p.InstanceName)|x" }
  }
} catch {}
PSEOF_DISKS

read -r -d '' PS_BATTERY <<'PSEOF_BATTERY' || true
$path = Join-Path $env:TEMP "laptop_check_battery_$PID.xml"
& powercfg /batteryreport /xml /output $path 2>$null | Out-Null
$bat = @()
if (Test-Path $path) {
  try {
    [xml]$x = Get-Content $path -Raw
    foreach ($b in @($x.BatteryReport.Batteries.Battery)) { if ($b) { $bat += $b } }
  } catch {}
  Remove-Item $path -Force -ErrorAction SilentlyContinue
}
if ($bat.Count -gt 0) {
  foreach ($b in $bat) {
    "BAT|$($b.Manufacturer)|$($b.Id)|$($b.Chemistry)|$($b.ManufactureDate)|$($b.DesignCapacity)|$($b.FullChargeCapacity)|$($b.CycleCount)|x"
  }
} else {
  try { $dn = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction Stop | ForEach-Object { $_.DesignedCapacity }) } catch { $dn = @() }
  try { $fl = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | ForEach-Object { $_.FullChargedCapacity }) } catch { $fl = @() }
  try { $cy = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryCycleCount -ErrorAction Stop | ForEach-Object { $_.CycleCount }) } catch { $cy = @() }
  $n = [math]::Max($dn.Count, $fl.Count)
  for ($i = 0; $i -lt $n; $i++) { "FALL|$($dn[$i])|$($fl[$i])|$($cy[$i])|x" }
}
foreach ($w in @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)) {
  "W32|$($w.Name)|$($w.EstimatedChargeRemaining)|$($w.BatteryStatus)|$($w.DesignVoltage)|x"
}
try {
  foreach ($s in @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop)) { "VOLT|$($s.Voltage)|x" }
} catch {}
PSEOF_BATTERY

read -r -d '' PS_WINDOWS <<'PSEOF_WINDOWS' || true
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$pw = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue
$svc = Get-CimInstance SoftwareLicensingService -ErrorAction SilentlyContinue
$ap = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot' -ErrorAction SilentlyContinue
"W|caption|$($os.Caption)|x"
"W|displayversion|$($cv.DisplayVersion)|x"
"W|build|$($os.BuildNumber)|x"
"W|ubr|$($cv.UBR)|x"
"W|arch|$($os.OSArchitecture)|x"
"W|installdate|$($os.InstallDate.ToString('yyyy-MM-dd'))|x"
"W|installdays|$([math]::Round(((Get-Date) - $os.InstallDate).TotalDays, 1))|x"
"W|lastboot|$($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))|x"
"W|uptimesec|$([math]::Round(((Get-Date) - $os.LastBootUpTime).TotalSeconds))|x"
"W|faststartup|$($pw.HiberbootEnabled)|x"
"W|hasoemkey|$([bool]$svc.OA3xOriginalProductKey)|x"
"W|oemdesc|$($svc.OA3xOriginalProductKeyDescription)|x"
"W|autopilot|$($ap.CloudAssignedTenantDomain)|x"
foreach ($l in @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='__APPID__' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue)) {
  "LIC|$($l.LicenseStatus)|$($l.ProductKeyChannel)|$($l.Description)|x"
}
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | Get-ItemProperty -ErrorAction SilentlyContinue | Where-Object { $_.ProviderID -eq 'MS DM Server' } | ForEach-Object { "MDM|$($_.UPN)|x" }
PSEOF_WINDOWS

read -r -d '' PS_SAMPLE <<'PSEOF_SAMPLE' || true
function Get-Temps {
  $list = @()
  try {
    foreach ($z in @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)) {
      $list += [pscustomobject]@{ C = [math]::Round($z.CurrentTemperature / 10.0 - 273.15, 1) }
    }
  } catch {}
  try {
    foreach ($z in @(Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop)) {
      $k = [double]$z.Temperature
      if ($z.HighPrecisionTemperature -gt 0) { $k = $z.HighPrecisionTemperature / 10.0 }
      $list += [pscustomobject]@{ C = [math]::Round($k - 273.15, 1) }
    }
  } catch {}
  return ,@($list | Where-Object { $_.C -gt 5 -and $_.C -lt 130 })
}
$util = ''; $perf = ''; $base = ''
try {
  $p = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
  $util = $p.PercentProcessorTime; $perf = $p.PercentProcessorPerformance; $base = $p.ProcessorFrequency
} catch {}
$mt = ''
$ts = @(Get-Temps)
if ($ts.Count -gt 0) { $mt = ($ts | Measure-Object -Property C -Maximum).Maximum }
"S|$util|$perf|$base|$mt|x"
PSEOF_SAMPLE

read -r -d '' PS_HISTORY <<'PSEOF_HISTORY' || true
$since = (Get-Date).AddDays(-__DAYS__)
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
  foreach ($e in $found) {
    $vals = @($e.Properties | ForEach-Object { $_.Value })
    $code = ''; $button = ''
    if ($e.Id -eq 41) {
      if ($vals.Count -gt 0) { $code = [int64]$vals[0] }
      if ($vals.Count -gt 6) { $button = ([int64]$vals[6] -ne 0) }
    } elseif ($e.Id -eq 1001) {
      $m = [regex]::Match((($vals -join ' ') + ' ' + $e.Message), '0x([0-9a-fA-F]{1,8})\b')
      if ($m.Success) { $code = [Convert]::ToInt64($m.Groups[1].Value, 16) }
    }
    "EV|$($e.TimeCreated.ToString('yyyy-MM-dd HH:mm'))|$($e.ProviderName)|$($e.Id)|$([int]$e.Level)|$code|$button|x"
  }
}
$oldest = ''
try { $oldest = (Get-WinEvent -LogName System -MaxEvents 1 -Oldest -ErrorAction Stop).TimeCreated.ToString('yyyy-MM-dd') } catch {}
"OLDEST|$oldest|x"
try {
  Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" -ErrorAction Stop | Sort-Object LastWriteTime -Descending | ForEach-Object { "DUMP|$($_.LastWriteTime.ToString('yyyy-MM-dd'))|x" }
} catch {}
PSEOF_HISTORY

read -r -d '' PS_MEMTEST_CSHARP <<'PSEOF_MEMCS' || true
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
PSEOF_MEMCS

# Build a full PowerShell program for the RAM test with the C# helper embedded.
build_memtest_ps() {
    local seconds="$1"
    printf '%s\n' "\$__cs = @'"
    printf '%s\n' "$PS_MEMTEST_CSHARP"
    printf '%s\n' "'@"
    cat <<PSEOF_MEMRUN
if (-not ('LaptopMemTest' -as [type])) { Add-Type -TypeDefinition \$__cs -Language CSharp -ReferencedAssemblies 'System.Core' -ErrorAction Stop }
\$totalPhys = [double][LaptopMemTest]::TotalPhysical()
\$avail = [double][LaptopMemTest]::AvailablePhysical()
\$target = [math]::Min(\$avail * 0.6, 8GB)
\$chunks = [LaptopMemTest]::Allocate([int64]\$target, 64MB)
if (\$chunks.Length -eq 0) { "MT|\$totalPhys|0|0|0"; "NORAM"; exit 0 }
\$tested = [double]\$chunks.Length * 64MB
\$patternNames = @('zeros', 'ones', '0x55', '0xAA', 'random')
\$badBlocks = [int64]0
\$pass = 0
\$sw = [Diagnostics.Stopwatch]::StartNew()
\$finished = \$false
while (-not \$finished) {
  for (\$mode = 0; \$mode -lt 5; \$mode++) {
    \$pass++
    \$t0 = \$sw.Elapsed.TotalSeconds
    \$errs = [LaptopMemTest]::Pass(\$chunks, \$mode, \$pass)
    \$badBlocks += \$errs
    "PASS|\$pass|\$(\$patternNames[\$mode])|\$errs|\$([math]::Round(\$sw.Elapsed.TotalSeconds - \$t0, 1))"
    if (\$pass -ge 5 -and \$sw.Elapsed.TotalSeconds -ge $seconds) { \$finished = \$true; break }
  }
}
\$chunks = \$null
"MT|\$totalPhys|\$tested|\$pass|\$badBlocks"
PSEOF_MEMRUN
}

# --------------------------------------------------------------------------
# Section 0 - system
# --------------------------------------------------------------------------

declare -gA SYS=()

section_system() {
    local admin="$1" out model pv mfg
    SYS=()
    out=$(ps_run "$PS_SYSTEM" 90)
    load_kv SYS <<< "$out"
    rep_section "0. SYSTEM" "System"
    model=$(clean "${SYS[Model]:-}")
    pv=$(clean "${SYS[ProductVersion]:-}")
    case "${pv,,}" in
        none | 'to be filled by o.e.m.') pv="" ;;
    esac
    if [ -n "$pv" ] && [[ "$model" != *"$pv"* ]]; then
        model="$model ($pv)"
    fi
    mfg=$(clean "${SYS[Manufacturer]:-}")
    rep_kv "Manufacturer / model" "$(clean "$mfg $model")"
    rep_kv "Serial number" "$(clean "${SYS[Serial]:-}")"
    rep_kv "BIOS" "$(clean "${SYS[BiosVersion]:-}")  (${SYS[BiosDate]:-date n/a})"
    rep_kv "Report time" "$(date '+%Y-%m-%d %H:%M')"
    if [ "$admin" = "1" ]; then
        rep_kv "Running as administrator" "yes"
    else
        rep_kv "Running as administrator" "NO (some data will be missing)"
    fi
    rep_line "  -> Compare model and serial with the sticker under the laptop and the ad."
}

# --------------------------------------------------------------------------
# Section 1 - CPU
# --------------------------------------------------------------------------

declare -ga CPU_NAMES=() CPU_CORES=() CPU_THREADS=() CPU_MHZ=()

section_cpu() {
    local out line count=0
    local -a f
    CPU_NAMES=(); CPU_CORES=(); CPU_THREADS=(); CPU_MHZ=()
    out=$(ps_run "$PS_CPU" 90)
    rep_section "1. CPU" "CPU"
    while IFS= read -r line; do
        line=${line%$'\r'}
        case "$line" in CPU\|*) ;; *) continue ;; esac
        IFS='|' read -r -a f <<< "$line"
        if [ "$count" -gt 0 ]; then
            rep_line "  Socket $count:"
        fi
        rep_kv "Model" "$(clean "${f[1]:-}")"
        rep_kv "Physical cores" "${f[2]:-}"
        rep_kv "Logical processors (threads)" "${f[3]:-}"
        rep_kv "Base clock" "${f[4]:-} MHz"
        CPU_NAMES+=("${f[1]:-}")
        CPU_CORES+=("${f[2]:-}")
        CPU_THREADS+=("${f[3]:-}")
        CPU_MHZ+=("${f[4]:-}")
        count=$((count + 1))
    done <<< "$out"
    if [ "$count" -eq 0 ]; then
        rep_flag YELLOW "Could not read CPU information."
        return
    fi
    rep_line "  -> Make sure the CPU model matches exactly what the seller advertised."
}

# --------------------------------------------------------------------------
# Section 2 - RAM
# --------------------------------------------------------------------------

declare -ga RAM_TOTAL=() RAM_TYPES=()

section_ram() {
    local out line i n total=0 visible=0 slots=0 installed=0
    local -a f
    local -a mod_cap=() mod_speed=() mod_conf=() mod_type=() mod_mfg=() mod_part=() mod_loc=()
    rep_section "2. MEMORY (RAM)" "RAM"
    out=$(ps_run "$PS_RAM" 90)
    while IFS= read -r line; do
        line=${line%$'\r'}
        [ -n "$line" ] || continue
        IFS='|' read -r -a f <<< "$line"
        case "${f[0]:-}" in
            MOD)
                mod_cap+=("${f[1]:-0}"); mod_speed+=("${f[2]:-}"); mod_conf+=("${f[3]:-}")
                mod_type+=("${f[4]:-}"); mod_mfg+=("${f[5]:-}"); mod_part+=("${f[6]:-}"); mod_loc+=("${f[7]:-}")
                ;;
            ARR) slots=$((slots + ${f[1]:-0})) ;;
            VISIBLE) visible=${f[1]:-0} ;;
        esac
    done <<< "$out"

    n=${#mod_cap[@]}
    for ((i = 0; i < n; i++)); do
        installed=$((installed + ${mod_cap[i]:-0}))
    done
    total=$installed
    if [ "$total" -eq 0 ]; then total=$visible; fi

    local usable=""
    if [ "$visible" -gt 0 ]; then
        usable="  ($(size_str "$visible" binary) usable by Windows)"
    fi
    rep_kv "Total installed" "$(size_str "$total" binary)$usable"

    local types="" t
    local -A seen=()
    for ((i = 0; i < n; i++)); do
        t=$(memtype "${mod_type[i]:-}")
        if [ -z "${seen[$t]:-}" ]; then
            seen[$t]=1
            types="${types:+$types, }$t"
        fi
    done
    if [ "$n" -gt 0 ]; then
        rep_kv "Type" "$types"
    fi
    if [ "$slots" -gt 0 ]; then
        rep_kv "Slots used" "$n of $slots"
    else
        rep_kv "Modules detected" "$n"
    fi
    for ((i = 0; i < n; i++)); do
        local sp="speed n/a"
        local speed="${mod_speed[i]:-}" conf="${mod_conf[i]:-}"
        if [ -n "$speed" ] && [ "$speed" != "0" ]; then sp="$(fmt "$speed" '%.0f') MT/s"; fi
        if [ -n "$conf" ] && [ -n "$speed" ] && [ "$conf" != "$speed" ]; then
            sp="$sp (running at $(fmt "$conf" '%.0f'))"
        fi
        rep_line "    - $(clean "${mod_loc[i]:-}")$( [ -n "$(clean "${mod_loc[i]:-}")" ] || printf 'slot ?'): $(size_str "${mod_cap[i]:-}" binary), $(memtype "${mod_type[i]:-}"), $sp, $(clean "${mod_mfg[i]:-}") $(clean "${mod_part[i]:-}")"
    done
    rep_line "  -> Slot counts reported by laptops are not always accurate; soldered RAM"
    rep_line "     also appears as a module."

    if [ "$total" -eq 0 ]; then
        rep_flag YELLOW "Could not read RAM size."
    else
        local gib
        gib=$(awk -v b="$total" 'BEGIN{printf "%.4f", b/(1024*1024*1024)}')
        if lt "$gib" 3.5; then
            rep_flag RED "Only $(fmt "$gib" '%.0f') GB RAM - too little for Windows 11."
        elif lt "$gib" 7.5; then
            rep_flag YELLOW "Only $(fmt "$gib" '%.0f') GB RAM - will feel slow; 8 GB minimum, 16 GB recommended."
        else
            rep_ok "$(fmt "$gib" '%.0f') GB RAM."
        fi
    fi
    if [ "$n" -eq 1 ] && [ "$slots" -ge 2 ]; then
        rep_flag NOTE "Single RAM module with a free slot: runs single-channel (slower), but upgradeable."
    fi
    RAM_TOTAL=("$total")
    RAM_TYPES=("$types")
}

# --------------------------------------------------------------------------
# Section 3 - storage
# --------------------------------------------------------------------------

find_smartctl() {
    if command -v smartctl >/dev/null 2>&1; then
        command -v smartctl
        return
    fi
    local c
    for c in "$SCRIPT_DIR/smartctl.exe" "/c/Program Files/smartmontools/bin/smartctl.exe" \
        "/c/Program Files (x86)/smartmontools/bin/smartctl.exe"; do
        if [ -x "$c" ]; then
            printf '%s' "$c"
            return
        fi
    done
}

section_disks() {
    local admin="$1" out line
    local -a f summary=()
    local any=0
    rep_section "3. STORAGE" "Storage"
    out=$(ps_run "$PS_DISKS" 180)
    while IFS= read -r line; do
        line=${line%$'\r'}
        [ -n "$line" ] || continue
        IFS='|' read -r -a f <<< "$line"
        case "${f[0]:-}" in
            PRED) rep_flag RED "SMART predicts imminent failure: $(clean "${f[1]:-}")" ;;
            DISK)
                any=1
                local num="${f[1]:-}" model size media bus health status letters
                local wear="${f[9]:-}" poh="${f[10]:-}" temp="${f[11]:-}" rerr="${f[12]:-}" werr="${f[13]:-}"
                model=$(clean "${f[2]:-}"); [ -n "$model" ] || model="Unknown disk"
                size="${f[3]:-}"; media="${f[4]:-}"; bus="${f[5]:-}"; health=$(clean "${f[6]:-}"); status="${f[7]:-}"
                letters="${f[8]:-}"; [ -n "$letters" ] || letters="-"
                [ -n "$bus" ] || bus="?"
                [ -n "$media" ] || media="?"
                if [ "$bus" = "RAID" ] && [[ "${model^^}" == *NVME* ]]; then
                    bus="NVMe (via Intel RST/VMD)"
                fi
                if [ "$media" = "Unspecified" ]; then
                    case "$bus" in
                        NVMe*) media="SSD?" ;;
                        *) media="?" ;;
                    esac
                fi
                rep_line ""
                rep_line "  Disk $num: $model"
                rep_kv "    Capacity" "$(size_str "$size")"
                rep_kv "    Type / interface" "$media / $bus"
                rep_kv "    Drive letters" "$letters"
                rep_kv "    Windows health status" "$health  ($status)"
                if [ -n "$wear$poh$temp$rerr$werr" ]; then
                    if [ -n "$wear" ]; then rep_kv "    Wear (life used)" "$(fmt "$wear" '%.0f')%"; else rep_kv "    Wear (life used)" "not reported"; fi
                    if [ -n "$poh" ]; then rep_kv "    Power-on hours" "$(fmt "$poh" '%.0f')"; else rep_kv "    Power-on hours" "not reported"; fi
                    if [ -n "$temp" ]; then rep_kv "    Temperature" "$(fmt "$temp" '%.0f') C"; else rep_kv "    Temperature" "not reported"; fi
                    rep_kv "    Uncorrected R/W errors" "$(fmt "${rerr:-0}" '%.0f') / $(fmt "${werr:-0}" '%.0f')"
                else
                    local why=""
                    [ "$admin" = "1" ] || why=" (run as administrator)"
                    rep_kv "    SMART counters" "unavailable$why"
                fi

                if [ "$bus" = "USB" ]; then
                    rep_flag NOTE "$model is an external USB drive - not part of the laptop."
                fi
                if [ -n "$health" ] && [ "$health" != "Healthy" ]; then
                    rep_flag RED "$model: Windows reports health '$health'."
                fi
                if [ -n "$wear" ]; then
                    if ge "$wear" 90; then
                        rep_flag RED "$model: $(fmt "$wear" '%.0f')% of rated life used - near end of life."
                    elif ge "$wear" 60; then
                        rep_flag YELLOW "$model: $(fmt "$wear" '%.0f')% of rated life used."
                    fi
                fi
                if { [ -n "$rerr" ] && [ "$rerr" != "0" ]; } || { [ -n "$werr" ] && [ "$werr" != "0" ]; }; then
                    rep_flag RED "$model: uncorrected read/write errors ($(fmt "${rerr:-0}" '%.0f')/$(fmt "${werr:-0}" '%.0f'))."
                fi
                if [ -n "$poh" ] && gt "$poh" 25000; then
                    local years
                    years=$(awk -v p="$poh" 'BEGIN{printf "%.1f", p/8760}')
                    rep_flag YELLOW "$model: $(fmt "$poh" '%.0f') power-on hours (~$years years non-stop)."
                fi
                if [ -n "$temp" ] && ge "$temp" 70; then
                    rep_flag YELLOW "$model: running hot at $(fmt "$temp" '%.0f') C."
                fi
                if [ "$media" = "HDD" ] && [ "$bus" != "USB" ]; then
                    rep_flag YELLOW "$model is a mechanical hard drive - much slower than an SSD."
                fi
                if [ "$bus" != "USB" ]; then
                    local kind="$media"
                    case "$bus" in NVMe*) kind="NVMe" ;; esac
                    summary+=("$(size_str "$size") $kind")
                fi
                ;;
        esac
    done <<< "$out"

    if [ "$any" -eq 0 ]; then
        rep_flag YELLOW "Could not list physical disks."
    fi

    local exe
    exe=$(find_smartctl)
    rep_line ""
    if [ -n "$exe" ]; then
        rep_line "  Full SMART data from $exe:"
        report_smartctl "$exe"
    else
        rep_line "  (Optional: install smartmontools or put smartctl.exe next to this script"
        rep_line "   for full SMART attributes.)"
    fi
    DISK_SUMMARY="$(
        local s=""
        local d
        for d in "${summary[@]:-}"; do [ -n "$d" ] || continue; s="${s:+$s, }$d"; done
        printf '%s' "$s"
    )"
}

report_smartctl() {
    local exe="$1" dev model out
    while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        out=$("$exe" -a "$dev" 2>/dev/null)
        [ -n "$out" ] || continue
        model=$(printf '%s\n' "$out" | sed -n 's/^Model Number:[[:space:]]*//p' | head -1)
        [ -n "$model" ] || model="$dev"
        rep_line "  smartctl: $model"
        local health
        health=$(printf '%s\n' "$out" | sed -n 's/^SMART overall-health self-assessment test result:[[:space:]]*//p' | head -1)
        if [ -n "$health" ]; then
            rep_kv "    SMART overall" "$health"
            if [ "$health" != "PASSED" ]; then rep_flag RED "$model: SMART self-assessment FAILED."; fi
        fi
        local poh
        poh=$(printf '%s\n' "$out" | awk -F: '/Power_On_Hours/{gsub(/[^0-9]/,"",$2); print $2; exit}')
        [ -n "$poh" ] && rep_kv "    Power-on hours" "$poh"
        local tid label raw
        for tid in 5:Reallocated_Sector_Ct 187:Reported_Uncorrect 197:Current_Pending_Sector 198:Offline_Uncorrectable; do
            label=${tid#*:}
            raw=$(printf '%s\n' "$out" | awk -v n="$label" '$1==n {print $10; exit}')
            if [ -n "$raw" ]; then
                rep_kv "    $label" "$raw"
                if [ "$raw" != "0" ]; then rep_flag RED "$model: $label = $raw (surface/flash damage)."; fi
            fi
        done
    done < <("$exe" --scan-open 2>/dev/null | awk '{print $1}')
}

# --------------------------------------------------------------------------
# Section 4 - battery
# --------------------------------------------------------------------------

BATT_VOLTS=""
BATT_SUMMARY="n/a"

cap_str() {
    local mwh="$1" s
    s="$(thousands "$mwh") mWh"
    if [ -n "$BATT_VOLTS" ]; then
        s="$s (~$(thousands "$(awk -v m="$mwh" -v v="$BATT_VOLTS" 'BEGIN{printf "%.0f", m/v}')") mAh)"
    fi
    printf '%s' "$s"
}

section_battery() {
    local outdir="$1" stamp="$2" out line
    local -a f
    local -a bat_name=() bat_chem=() bat_date=() bat_design=() bat_full=() bat_cycles=()
    local -a w32_name=() w32_charge=() w32_status=() volt_list=()
    rep_section "4. BATTERY" "Battery"
    out=$(ps_run "$PS_BATTERY" 120)
    while IFS= read -r line; do
        line=${line%$'\r'}
        [ -n "$line" ] || continue
        IFS='|' read -r -a f <<< "$line"
        case "${f[0]:-}" in
            BAT)
                bat_name+=("$(clean "${f[1]:-} ${f[2]:-}")")
                bat_chem+=("$(clean "${f[3]:-}")")
                bat_date+=("$(clean "${f[4]:-}")")
                bat_design+=("${f[5]:-}")
                bat_full+=("${f[6]:-}")
                bat_cycles+=("${f[7]:-}")
                ;;
            FALL)
                bat_name+=("")
                bat_chem+=("")
                bat_date+=("")
                bat_design+=("${f[1]:-}")
                bat_full+=("${f[2]:-}")
                bat_cycles+=("${f[3]:-}")
                ;;
            W32)
                w32_name+=("$(clean "${f[1]:-}")")
                w32_charge+=("${f[2]:-}")
                w32_status+=("${f[3]:-}")
                volt_list+=("${f[4]:-}")
                ;;
            VOLT) volt_list+=("${f[1]:-}") ;;
        esac
    done <<< "$out"

    BATT_VOLTS=""
    local mv
    for mv in "${volt_list[@]:-}"; do
        [ -n "$mv" ] || continue
        if ge "$mv" 5000 && le "$mv" 25000; then
            BATT_VOLTS=$(awk -v v="$mv" 'BEGIN{printf "%.2f", v/1000}')
            break
        fi
    done

    if [ "${#bat_name[@]}" -eq 0 ] && [ "${#w32_name[@]}" -eq 0 ]; then
        rep_flag RED "No battery detected! (removed, dead, or disconnected)"
        BATT_SUMMARY="n/a"
        return
    fi

    local i n=${#bat_name[@]}
    local min_health=""
    for ((i = 0; i < n; i++)); do
        if [ "$n" -gt 1 ]; then rep_line "  Battery $((i + 1)):"; fi
        local design="${bat_design[i]:-}" full="${bat_full[i]:-}" cycles="${bat_cycles[i]:-}"
        if [ -n "${bat_name[i]:-}" ]; then
            local label="${bat_name[i]}"
            [ -n "${bat_chem[i]:-}" ] && label="$label (${bat_chem[i]})"
            rep_kv "Battery" "$label"
        fi
        [ -n "${bat_date[i]:-}" ] && rep_kv "Manufacture date" "${bat_date[i]}"
        if [ -n "$design" ] && [ "$design" != "0" ]; then rep_kv "Original capacity (when new)" "$(cap_str "$design")"; else rep_kv "Original capacity (when new)" "n/a"; fi
        if [ -n "$full" ] && [ "$full" != "0" ]; then rep_kv "Capacity left (full charge)" "$(cap_str "$full")"; else rep_kv "Capacity left (full charge)" "n/a"; fi
        if [ -n "$design" ] && [ "$design" != "0" ] && [ -n "$full" ] && [ "$full" != "0" ]; then
            local health left lost
            health=$(awk -v f="$full" -v d="$design" 'BEGIN{printf "%.0f", f/d*100}')
            if [ -n "$BATT_VOLTS" ]; then
                left="$(thousands "$(awk -v f="$full" -v v="$BATT_VOLTS" 'BEGIN{printf "%.0f", f/v}')") mAh of $(thousands "$(awk -v d="$design" -v v="$BATT_VOLTS" 'BEGIN{printf "%.0f", d/v}')") mAh"
            else
                left="$(thousands "$full") mWh of $(thousands "$design") mWh"
            fi
            lost=$(awk -v h="$health" 'BEGIN{v=100-h; if(v<0)v=0; printf "%.0f", v}')
            rep_kv "Remaining from original" "$(fmt "$health" '%.0f')%  = $left  (lost $lost%)"
            if [ -z "$min_health" ] || lt "$health" "$min_health"; then
                min_health="$health"
                BATT_SUMMARY="$(fmt "$health" '%.0f')% of original ($left)"
            fi
            if lt "$health" 60; then
                rep_flag RED "Battery health $(fmt "$health" '%.0f')% - plan on replacing the battery."
            elif lt "$health" 80; then
                rep_flag YELLOW "Battery health $(fmt "$health" '%.0f')% - noticeably reduced runtime."
            else
                rep_ok "Battery health $(fmt "$health" '%.0f')%."
            fi
            if gt "$health" 105; then
                rep_flag NOTE "Capacity above design value - battery may be new or poorly calibrated."
            fi
        else
            rep_flag YELLOW "Battery capacity not reported - cannot calculate health."
        fi
        if [ -n "$cycles" ] && [ "$cycles" != "0" ]; then
            rep_kv "Charge cycles" "$(fmt "$cycles" '%.0f')"
            if gt "$cycles" 800; then
                rep_flag RED "$(fmt "$cycles" '%.0f') charge cycles - battery is near end of life."
            elif gt "$cycles" 500; then
                rep_flag YELLOW "$(fmt "$cycles" '%.0f') charge cycles - battery is well used."
            fi
        else
            rep_kv "Charge cycles" "not reported by the battery"
        fi
        if [ -n "$design" ] && [ "$design" != "0" ] && [ -n "$full" ] && [ "$full" != "0" ] && lt "$(awk -v f="$full" -v d="$design" 'BEGIN{print f/d}')" 0.8 && [ -n "$cycles" ] && [ "$cycles" != "0" ] && lt "$cycles" 100; then
            local lostpct
            lostpct=$(awk -v f="$full" -v d="$design" 'BEGIN{printf "%.0f", 100 - f/d*100}')
            rep_flag NOTE "Only $(fmt "$cycles" '%.0f') cycles but $lostpct% capacity lost - the cycle counter may be unreliable, or the battery aged from time and heat."
        fi
    done
    if [ -n "$BATT_VOLTS" ]; then
        rep_line "  -> mAh calculated from mWh at the battery's ${BATT_VOLTS} V."
    fi
    for ((i = 0; i < ${#w32_name[@]}; i++)); do
        local src="charger connected"
        [ "${w32_status[i]:-}" = "1" ] && src="on battery"
        rep_kv "Charge level right now" "${w32_charge[i]:-}%  ($src) - not battery health"
    done

    local html="$outdir/battery-report_$stamp.html"
    powercfg /batteryreport /output "$html" >/dev/null 2>&1 || true
    if [ -f "$html" ]; then
        rep_line "  Detailed battery history saved to: $html"
    fi
}

# --------------------------------------------------------------------------
# Section 5 - Windows
# --------------------------------------------------------------------------

declare -gA WIN=()
WIN_ACTIVATED="unknown"

section_windows() {
    local part_of_domain="$1" out line
    local -a f
    local -a lic_status=() lic_channel=() lic_desc=() mdm=()
    WIN=()
    WIN_ACTIVATED="unknown"
    rep_section "5. WINDOWS" "Windows"
    out=$(ps_run "${PS_WINDOWS//__APPID__/$WINDOWS_APP_ID}" 120)
    while IFS= read -r line; do
        line=${line%$'\r'}
        [ -n "$line" ] || continue
        IFS='|' read -r -a f <<< "$line"
        case "${f[0]:-}" in
            W) WIN["${f[1]:-}"]="${f[2]:-}" ;;
            LIC)
                lic_status+=("${f[1]:-}")
                lic_channel+=("$(clean "${f[2]:-}")")
                lic_desc+=("$(clean "${f[3]:-}")")
                ;;
            MDM) mdm+=("$(clean "${f[1]:-}")") ;;
        esac
    done <<< "$out"

    local build="${WIN[build]:-0}"
    rep_kv "Edition" "$(clean "${WIN[caption]:-}")"
    rep_kv "Version" "$(clean "${WIN[displayversion]:-}") (build ${build}.${WIN[ubr]:-0}), ${WIN[arch]:-}"
    if [ -n "$build" ] && [ "$build" != "0" ] && lt "$build" 22000; then
        rep_flag NOTE "This is Windows 10, not Windows 11."
    fi
    rep_kv "Installed / last major update" "${WIN[installdate]:-} ($(fmt "${WIN[installdays]:-0}" '%.0f') days ago)"

    if [ "${#lic_status[@]}" -gt 0 ]; then
        # prefer an activated license, exactly like the Python version
        local idx=0 st="${lic_status[0]}"
        local i
        for ((i = 0; i < ${#lic_status[@]}; i++)); do
            if [ "${lic_status[i]}" = "1" ]; then idx=$i; st="1"; fi
        done
        st="${lic_status[idx]}"
        rep_kv "Activation" "$(license_status "$st")"
        local channel="${lic_channel[idx]:-}"
        [ -n "$channel" ] || channel="${lic_desc[idx]:-}"
        rep_kv "License channel" "$channel"
        if [ "$st" = "1" ]; then
            WIN_ACTIVATED="activated"
            rep_ok "Windows is activated."
        else
            WIN_ACTIVATED="NOT activated"
            rep_flag RED "Windows is NOT activated."
        fi
        local licstr="${lic_desc[idx]:-} ${lic_channel[idx]:-}"
        if [[ "${licstr^^}" == *KMS* ]] && [ "$part_of_domain" != "True" ]; then
            rep_flag YELLOW "Activated via KMS (volume license). On a home laptop this usually means an unofficial activator; it may stop being activated."
        fi
    else
        rep_flag YELLOW "Could not determine activation status (try running slmgr /xpr)."
    fi
    if [ "${WIN[hasoemkey]:-}" = "True" ]; then
        rep_kv "Factory license key in BIOS" "yes - $(clean "${WIN[oemdesc]:-}")"
    else
        rep_kv "Factory license key in BIOS" "no"
    fi

    # Is the device owned/managed by an organisation? (company / stolen laptops)
    local dsreg="" managed=()
    if [ "${HAVE_PS:-0}" = "1" ]; then
        dsreg=$(dsregcmd /status 2>/dev/null)
    fi
    if [ "$part_of_domain" = "True" ] || printf '%s' "$dsreg" | grep -qiE '^[[:space:]]*DomainJoined[[:space:]]*:[[:space:]]*YES'; then
        managed+=("joined to domain '$(clean "${SYS[Domain]:-}")'")
    fi
    if printf '%s' "$dsreg" | grep -qiE '^[[:space:]]*AzureAdJoined[[:space:]]*:[[:space:]]*YES'; then
        managed+=("joined to Microsoft Entra ID (Azure AD)")
    fi
    if printf '%s' "$dsreg" | grep -qiE '^[[:space:]]*EnterpriseJoined[[:space:]]*:[[:space:]]*YES'; then
        managed+=("enterprise joined")
    fi
    if [ "${#mdm[@]}" -gt 0 ]; then
        managed+=("enrolled in MDM (e.g. Intune): $(IFS=', '; printf '%s' "${mdm[*]}")")
    fi
    if [ -n "${WIN[autopilot]:-}" ]; then
        managed+=("registered in Windows Autopilot to '$(clean "${WIN[autopilot]}")'")
    fi
    if [ "${#managed[@]}" -gt 0 ]; then
        rep_kv "Organisation management" "$(IFS='; '; printf '%s' "${managed[*]}")"
        rep_flag RED "Laptop is managed by an organisation ($(IFS='; '; printf '%s' "${managed[*]}")). It may be company property and can be locked remotely or after a reset - ask for proof."
    else
        rep_kv "Organisation management" "none detected"
    fi
}

# --------------------------------------------------------------------------
# Section 6 - CPU stress test with verified calculations
# --------------------------------------------------------------------------

# Deterministic calculation with a known answer (the bash equivalent of the
# SHA-256 chain in laptop_check.py). Every worker repeats it and compares the
# result with the answer computed on a cool CPU before the load started.
stress_work() {
    local i acc=0
    for ((i = 1; i <= 20000; i++)); do
        acc=$(((acc * 1103515245 + 12345 + i) & 0x7FFFFFFF))
    done
    printf '%s' "$acc"
}

stress_worker() {
    local end="$1" expected="$2" progress="$3"
    local cnt=0 err=0 w
    while [ "$(date +%s)" -lt "$end" ]; do
        w=$(stress_work)
        [ "$w" = "$expected" ] || err=$((err + 1))
        cnt=$((cnt + 1))
        if [ $((cnt % 20)) -eq 0 ]; then
            printf '%s %s\n' "$cnt" "$err" > "$progress" 2>/dev/null
        fi
    done
    printf '%s %s\n' "$cnt" "$err" > "$progress" 2>/dev/null
}

now() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        printf '%s' "${EPOCHREALTIME/,/.}"
    else
        date +%s
    fi
}

sample_cpu() { # prints "util perf base temp" (empty field allowed)
    local out line
    local -a f
    out=$(ps_run "$PS_SAMPLE" 30)
    while IFS= read -r line; do
        line=${line%$'\r'}
        case "$line" in S\|*) ;; *) continue ;; esac
        IFS='|' read -r -a f <<< "$line"
        printf '%s %s %s %s' "${f[1]:-}" "${f[2]:-}" "${f[3]:-}" "${f[4]:-}"
        return
    done <<< "$out"
    printf '   '
}

sum_progress() { # dir -> "count errors"
    local dir="$1" fp line c=0 e=0
    for fp in "$dir"/w*; do
        [ -f "$fp" ] || continue
        line=$(cat "$fp" 2>/dev/null)
        [ -n "$line" ] || continue
        c=$((c + ${line%% *}))
        e=$((e + ${line##* }))
    done
    printf '%s %s' "$c" "$e"
}

section_stress() {
    local seconds="$1" threads="$2"
    [ "$seconds" -ge 5 ] || seconds=5
    rep_section "6. CPU STRESS TEST ($seconds s) + TEMPERATURES" "Stress test"
    rep_line "  Tip: connect the charger and close other programs for a fair result."
    rep_line "  Measuring idle state..."

    local -a idle_temps=()
    local i s util perf base temp
    for ((i = 0; i < 3; i++)); do
        sleep 1
        read -r util perf base temp < <(sample_cpu)
        [ -n "$temp" ] && idle_temps+=("$temp")
    done

    [ "$threads" -ge 1 ] 2>/dev/null || threads=2
    rep_line "  Loading all $threads threads for $seconds s, verifying every calculation..."
    local expected
    expected=$(stress_work)

    local progdir
    progdir=$(mktemp -d "${TMPDIR:-/tmp}/laptop_stress.XXXXXX") || progdir="/tmp/laptop_stress.$$"
    mkdir -p "$progdir"
    local end
    end=$(( $(date +%s) + seconds ))
    local -a pids=()
    local w
    for ((i = 0; i < threads; i++)); do
        stress_worker "$end" "$expected" "$progdir/w$i" &
        pids+=("$!")
    done

    local -a rates=() load_util=() load_perf=() load_base=() load_temp=()
    local prev_n=0 prev_t t n e dt rate
    prev_t=$(now)
    local start_ts
    start_ts=$(date +%s)
    while [ "$(date +%s)" -lt $((end + 1)) ]; do
        sleep 2
        read -r util perf base temp < <(sample_cpu)
        t=$(( $(date +%s) - start_ts ))
        n=0; e=0
        read -r n e < <(sum_progress "$progdir")
        dt=$(awk -v a="$(now)" -v b="$prev_t" 'BEGIN{print a-b}')
        rate=$(awk -v dn="$((n - prev_n))" -v dt="$dt" 'BEGIN{ if (dt <= 0) dt = 0.001; printf "%.1f", dn/dt }')
        prev_n=$n; prev_t=$(now)
        rate=$(awk -v x="$rate" 'BEGIN{printf "%s", (x==""?"0":x)}')
        rates+=("$rate")
        load_util+=("$util"); load_perf+=("$perf"); load_base+=("$base"); load_temp+=("$temp")
        rep_line "    t=$(fmt "$t" '%5.1f')s  CPU $(fmt "$util" '%5.1f')%  $([ -n "$base" ] && [ -n "$perf" ] && awk -v b="$base" -v p="$perf" 'BEGIN{printf "~%.2f GHz", b*p/100/1000}' || printf 'clock n/a')  temp $([ -n "$temp" ] && printf '%s C' "$(fmt "$temp" '%.0f')" || printf 'n/a')  $(fmt "$rate" '%6.1f') calc/s  errors $e"
    done

    for i in "${pids[@]:-}"; do
        [ -n "$i" ] && wait "$i" 2>/dev/null
    done
    local total wrong
    read -r total wrong < <(sum_progress "$progdir")
    rm -rf "$progdir" 2>/dev/null || true

    rep_line "  Cooling down for 10 s..."
    sleep 8
    local -a after_temps=()
    for ((i = 0; i < 2; i++)); do
        sleep 1
        read -r util perf base temp < <(sample_cpu)
        [ -n "$temp" ] && after_temps+=("$temp")
    done

    # averages over the load samples (skip the first two, like the Python version)
    local avg_util avg_perf avg_base t_peak t_idle t_end t_after
    avg_util=$(avg_of "${load_util[@]:-}")
    avg_perf=$(avg_of "${load_perf[@]:-}")
    avg_base=$(avg_of "${load_base[@]:-}")
    t_idle=$(max_of "${idle_temps[@]:-}")
    t_peak=$(max_of "${load_temp[@]:-}")
    t_after=$(max_of "${after_temps[@]:-}")
    if [ "${#load_temp[@]}" -gt 0 ]; then t_end="${load_temp[${#load_temp[@]}-1]}"; else t_end=""; fi

    rep_line ""
    rep_kv "Temperature before (idle)" "$(temp_str "$t_idle")"
    rep_kv "Temperature peak under load" "$(temp_str "$t_peak")"
    rep_kv "Temperature at end of load" "$(temp_str "$t_end")"
    rep_kv "Temperature after 10 s cooldown" "$(temp_str "$t_after")"
    [ -n "$avg_util" ] && rep_kv "Average CPU load" "$(fmt "$avg_util" '%.0f')%"
    if [ -n "$avg_perf" ] && [ -n "$avg_base" ]; then
        rep_kv "Average clock under load" "~$(awk -v b="$avg_base" -v p="$avg_perf" 'BEGIN{printf "%.0f", b*p/100}') MHz ($(fmt "$avg_perf" '%.0f')% of base $(fmt "$avg_base" '%.0f') MHz)"
    fi

    local all_unique
    all_unique=$(printf '%s\n' "${idle_temps[@]:-}" "${load_temp[@]:-}" "${after_temps[@]:-}" | sed '/^$/d' | sort -u | grep -c .)
    if [ -z "$t_peak" ]; then
        rep_flag NOTE "This laptop does not expose a temperature sensor to Windows. For exact CPU temperatures use HWiNFO or LibreHardwareMonitor (portable)."
    elif [ "$all_unique" = "1" ]; then
        rep_flag NOTE "Temperature sensor stays fixed at $(fmt "$t_peak" '%.0f') C - it is an ACPI zone, not the real CPU temperature. Use HWiNFO for real values."
    elif ge "$t_peak" 95; then
        rep_flag RED "CPU reached $(fmt "$t_peak" '%.0f') C - overheating (dust, dried thermal paste or fan problem)."
    elif ge "$t_peak" 88; then
        rep_flag YELLOW "CPU reached $(fmt "$t_peak" '%.0f') C - running hot; cooling may need cleaning."
    else
        rep_ok "Peak temperature $(fmt "$t_peak" '%.0f') C."
    fi

    if [ -n "$avg_perf" ]; then
        if lt "$avg_perf" 50; then
            rep_flag RED "CPU ran at only $(fmt "$avg_perf" '%.0f')% of base clock under load - heavy throttling (overheating, failing fan, worn battery/charger or power-saving mode)."
        elif lt "$avg_perf" 80; then
            rep_flag YELLOW "CPU ran at $(fmt "$avg_perf" '%.0f')% of base clock under load - some throttling. Check that the charger is connected and power mode is 'Best performance'."
        else
            rep_ok "No significant throttling detected."
        fi
    fi
    if [ -n "$avg_util" ] && lt "$avg_util" 80; then
        rep_flag NOTE "CPU load only reached $(fmt "$avg_util" '%.0f')% - the result may be less reliable."
    fi

    rep_kv "Calculations verified" "$(thousands "$total") ($wrong wrong)"
    local drop=""
    if [ "${#rates[@]}" -ge 5 ]; then
        local start_rate end_rate
        start_rate=$(avg_of "${rates[1]}" "${rates[2]}")
        end_rate=$(avg_of "${rates[${#rates[@]}-2]}" "${rates[${#rates[@]}-1]}")
        drop=$(awk -v a="$start_rate" -v b="$end_rate" 'BEGIN{ if (a>0) printf "%.0f", (1-b/a)*100; else print "" }')
        rep_kv "Speed start -> end of test" "$(fmt "$start_rate" '%.1f') -> $(fmt "$end_rate" '%.1f') calc/s ($(printf '%+d' "$(fmt "$drop" '%.0f')"))%"
    fi
    if [ -n "$wrong" ] && [ "$wrong" -gt 0 ] 2>/dev/null; then
        rep_flag RED "CPU produced $wrong wrong results under load - unstable (overheating, undervolting/overclocking, or faulty CPU/RAM)."
    elif [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
        rep_ok "All $(thousands "$total") calculations under load were correct."
    else
        rep_flag YELLOW "The verified stress test did not run - result unknown."
    fi
    if [ -n "$drop" ] && ge "$drop" 50; then
        rep_flag YELLOW "Speed fell $(fmt "$drop" '%.0f')% during the test - strong thermal/power throttling. (A drop of up to ~30% is normal when turbo boost ends.)"
    fi
    STRESS_PEAK="$t_peak"
    STRESS_CALC="$(thousands "$total") verified, $wrong wrong"
}

avg_of() {
    local x sum=0 n=0
    for x in "$@"; do
        [ -n "$x" ] || continue
        sum=$(awk -v s="$sum" -v v="$x" 'BEGIN{print s+v}')
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] && awk -v s="$sum" -v n="$n" 'BEGIN{print s/n}'
}

max_of() {
    local x max=""
    for x in "$@"; do
        [ -n "$x" ] || continue
        if [ -z "$max" ] || gt "$x" "$max"; then max="$x"; fi
    done
    printf '%s' "$max"
}

temp_str() {
    local v="$1"
    if [ -n "$v" ]; then printf '%s C' "$(fmt "$v" '%.0f')"; else printf 'n/a'; fi
}

# --------------------------------------------------------------------------
# Section 7 - uptime
# --------------------------------------------------------------------------

section_uptime() {
    rep_section "7. UPTIME" "Uptime"
    rep_kv "Last boot" "${WIN[lastboot]:-n/a}"
    rep_kv "Uptime" "$(duration_str "${WIN[uptimesec]:-0}")"
    if [ "${WIN[faststartup]:-}" = "1" ]; then
        rep_line "  -> Fast Startup is ON: 'Shut down' does not reset uptime, only 'Restart' does."
    fi
}

# --------------------------------------------------------------------------
# Section 8 - crash & hardware error history
# --------------------------------------------------------------------------

WHEA_KINDS_17="corrected PCIe/bus error"
WHEA_KINDS_18="fatal CPU error"
WHEA_KINDS_19="corrected CPU error"
WHEA_KINDS_47="corrected memory error"

whea_kind() {
    case "$1" in
        17) printf '%s' "$WHEA_KINDS_17" ;;
        18) printf '%s' "$WHEA_KINDS_18" ;;
        19) printf '%s' "$WHEA_KINDS_19" ;;
        47) printf '%s' "$WHEA_KINDS_47" ;;
        *) printf 'hardware error (event %s)' "$1" ;;
    esac
}

epoch_of() { # "YYYY-MM-DD [HH:MM]" -> seconds since the epoch
    local s="$1"
    date -d "$s" +%s 2>/dev/null || printf '0'
}

section_history() {
    local days="$1"
    [ "$days" -ge 1 ] 2>/dev/null || days=1
    rep_section "8. CRASH & HARDWARE ERROR HISTORY (last $days days)" "Error history"
    local out line
    local -a f
    local -a ev_time=() ev_provider=() ev_id=() ev_level=() ev_code=() ev_button=()
    local oldest="" dumps=0 latest_dump=""
    out=$(ps_run "${PS_HISTORY//__DAYS__/$days}" 240)
    while IFS= read -r line; do
        line=${line%$'\r'}
        [ -n "$line" ] || continue
        IFS='|' read -r -a f <<< "$line"
        case "${f[0]:-}" in
            EV)
                ev_time+=("${f[1]:-}"); ev_provider+=("${f[2]:-}"); ev_id+=("${f[3]:-}")
                ev_level+=("${f[4]:-}"); ev_code+=("${f[5]:-}"); ev_button+=("${f[6]:-}")
                ;;
            OLDEST) oldest="${f[1]:-}" ;;
            DUMP) dumps=$((dumps + 1)); [ -n "$latest_dump" ] || latest_dump="${f[1]:-}" ;;
        esac
    done <<< "$out"

    local i n=${#ev_time[@]}
    if [ "$n" -eq 0 ] && [ -z "$oldest" ] && [ "$dumps" -eq 0 ]; then
        rep_flag YELLOW "Could not read the Windows event log."
        HISTORY_SUMMARY=""
        return
    fi

    if [ -n "$oldest" ]; then
        local covered
        covered=$(awk -v a="$(date +%s)" -v b="$(epoch_of "$oldest 00:00")" 'BEGIN{printf "%.0f", (a-b)/86400}')
        rep_kv "Event log goes back to" "$oldest ($covered days)"
        if lt "$covered" 30; then
            rep_flag NOTE "The event log only goes back $covered days - older problems are not visible."
        fi
    fi

    # Blue screens: BugCheck 1001 events plus Kernel-Power 41 with a bugcheck code
    local -a bsod_code=() bsod_date=()
    local provider
    for ((i = 0; i < n; i++)); do
        provider="${ev_provider[i]}"
        if [ "$provider" = "Microsoft-Windows-WER-SystemErrorReporting" ] && [ -n "${ev_code[i]}" ]; then
            bsod_code+=("${ev_code[i]}"); bsod_date+=("${ev_time[i]% *}")
        fi
    done
    for ((i = 0; i < n; i++)); do
        [ "${ev_provider[i]}" = "Microsoft-Windows-Kernel-Power" ] || continue
        [ "${ev_id[i]}" = "41" ] || continue
        [ -n "${ev_code[i]}" ] || continue
        local dup=0 j
        for ((j = 0; j < ${#bsod_date[@]}; j++)); do
            local ta tb
            ta=$(( $(epoch_of "${ev_time[i]}") ))
            tb=$(( $(epoch_of "${bsod_date[j]} 00:00") ))
            if [ "$ta" -gt 0 ] && [ "$tb" -gt 0 ]; then
                local diff=$((ta - tb))
                [ "$diff" -lt 0 ] && diff=$((0 - diff))
                [ "$diff" -lt 900 ] && dup=1 && break
            fi
        done
        if [ "$dup" -eq 0 ]; then
            bsod_code+=("${ev_code[i]}"); bsod_date+=("${ev_time[i]% *}")
        fi
    done

    rep_kv "Blue screens (BSOD)" "${#bsod_code[@]}"
    # group by normalised bugcheck code, preserving first-seen order
    local -a g_codes=() 
    local -A g_count=() g_last=()
    for ((i = 0; i < ${#bsod_code[@]}; i++)); do
        local info code
        info=$(bugcheck_info "${bsod_code[i]}")
        code=${info%%|*}
        if [ -z "${g_count[$code]:-}" ]; then g_codes+=("$code"); g_count[$code]=0; fi
        g_count[$code]=$((g_count[$code] + 1))
        g_last[$code]="${bsod_date[i]}"
    done
    local c name cause level
    for c in "${g_codes[@]:-}"; do
        [ -n "$c" ] || continue
        local info
        info=$(bugcheck_info "$c")
        name=$(printf '%s' "$info" | cut -d'|' -f2)
        cause=$(printf '%s' "$info" | cut -d'|' -f3)
        level=$(printf '%s' "$info" | cut -d'|' -f4)
        rep_line "    - 0x$(printf '%X' "$c") $name x${g_count[$c]} (last ${g_last[$c]}) -> likely cause: $cause"
        if [ "$level" = "RED" ]; then
            rep_flag RED "Blue screen 0x$(printf '%X' "$c") $name x${g_count[$c]} - points to a $cause problem."
        elif [ "$level" = "YELLOW" ] || [ "${g_count[$c]}" -ge 3 ]; then
            rep_flag YELLOW "Blue screen 0x$(printf '%X' "$c") $name x${g_count[$c]} - possible $cause problem."
        else
            rep_flag NOTE "Blue screen 0x$(printf '%X' "$c") $name x${g_count[$c]} - usually a $cause issue."
        fi
    done

    local unexpected=0 forced=0
    for ((i = 0; i < n; i++)); do
        [ "${ev_provider[i]}" = "Microsoft-Windows-Kernel-Power" ] || continue
        [ "${ev_id[i]}" = "41" ] || continue
        if [ -z "${ev_code[i]}" ]; then
            if [ "${ev_button[i]:-}" = "True" ]; then forced=$((forced + 1)); else unexpected=$((unexpected + 1)); fi
        fi
    done
    rep_kv "Unexpected shutdowns" "$unexpected  (+$forced forced off with the power button)"
    if [ "$unexpected" -ge 3 ]; then
        rep_flag YELLOW "$unexpected unexpected shutdowns - possible overheating, power or battery problem."
    elif [ "$unexpected" -gt 0 ]; then
        rep_flag NOTE "$unexpected unexpected shutdown(s) - can also be a dead battery or a power cut."
    fi
    if [ "$forced" -ge 3 ]; then
        rep_flag NOTE "Forced off with the power button $forced times - the laptop may freeze."
    fi

    # WHEA hardware errors grouped by (event id, level)
    local whea=0
    local -a w_keys=()
    local -A w_count=() w_last=() w_level=() w_id=()
    for ((i = 0; i < n; i++)); do
        [ "${ev_provider[i]}" = "Microsoft-Windows-WHEA-Logger" ] || continue
        whea=$((whea + 1))
        local key="${ev_id[i]}|${ev_level[i]}"
        if [ -z "${w_count[$key]:-}" ]; then w_keys+=("$key"); w_count[$key]=0; w_id[$key]="${ev_id[i]}"; w_level[$key]="${ev_level[i]}"; fi
        w_count[$key]=$((w_count[$key] + 1))
        w_last[$key]="${ev_time[i]% *}"
    done
    rep_kv "Hardware errors (WHEA)" "$whea"
    local key
    for key in "${w_keys[@]:-}"; do
        [ -n "$key" ] || continue
        local eid="${w_id[$key]}" lvl="${w_level[$key]}"
        local kind
        kind=$(whea_kind "$eid")
        local fatal=""
        if [ "$lvl" = "1" ] || [ "$lvl" = "2" ]; then fatal=" (FATAL)"; fi
        rep_line "    - $kind$fatal x${w_count[$key]} (last ${w_last[$key]})"
        if [ -n "$fatal" ]; then
            rep_flag RED "Fatal hardware error logged x${w_count[$key]}: $kind."
        elif [ "$eid" = "19" ] || [ "$eid" = "47" ]; then
            rep_flag YELLOW "$kind x${w_count[$key]} - the CPU/RAM reported errors it had to correct."
        else
            rep_flag NOTE "$kind x${w_count[$key]} - often harmless, but worth noting."
        fi
    done

    local disk=0
    for ((i = 0; i < n; i++)); do
        [ "${ev_provider[i]}" = "disk" ] && disk=$((disk + 1))
    done
    rep_kv "Disk errors in log" "$disk"
    report_disk_event "$n" 7 "bad block on disk" RED
    report_disk_event "$n" 51 "disk paging error" YELLOW
    report_disk_event "$n" 153 "disk I/O retried" YELLOW

    local memdiag=0 memfail=0 last_mem=""
    for ((i = 0; i < n; i++)); do
        [ "${ev_provider[i]}" = "Microsoft-Windows-MemoryDiagnostics-Results" ] || continue
        memdiag=$((memdiag + 1))
        [ -n "$last_mem" ] || last_mem="${ev_time[i]% *}"
        case "${ev_level[i]:-4}" in 1 | 2 | 3) memfail=$((memfail + 1)) ;; esac
    done
    if [ "$memdiag" -gt 0 ]; then
        if [ "$memfail" -gt 0 ]; then
            rep_kv "Windows Memory Diagnostic" "run $memdiag time(s), last $last_mem - ERRORS FOUND $memfail time(s)"
            rep_flag RED "Windows Memory Diagnostic found RAM errors in the past."
        else
            rep_kv "Windows Memory Diagnostic" "run $memdiag time(s), last $last_mem - no errors"
        fi
    else
        rep_kv "Windows Memory Diagnostic" "never run in this period"
    fi

    if [ "$dumps" -gt 0 ]; then
        rep_kv "Crash dump files" "$dumps (latest $latest_dump)"
        if [ "${#bsod_code[@]}" -eq 0 ]; then
            rep_flag NOTE "$dumps crash dump file(s) exist (latest $latest_dump) - there were blue screens earlier than the event log shows."
        fi
    else
        rep_kv "Crash dump files" "none"
    fi

    local cleared_dates=""
    for ((i = 0; i < n; i++)); do
        if [ "${ev_provider[i]}" = "Microsoft-Windows-Eventlog" ] && [ "${ev_id[i]}" = "104" ]; then
            cleared_dates="${cleared_dates:+$cleared_dates, }${ev_time[i]% *}"
        fi
    done
    if [ -n "$cleared_dates" ]; then
        rep_kv "Event log cleared" "$cleared_dates"
        rep_flag YELLOW "The System event log was cleared ($cleared_dates) - earlier history is gone. Can be innocent (cleanup tools), but ask why."
    fi

    if [ "${#bsod_code[@]}" -eq 0 ] && [ "$unexpected" -eq 0 ] && [ "$whea" -eq 0 ] && [ "$disk" -eq 0 ] && [ -z "$cleared_dates" ]; then
        rep_ok "No crashes or hardware errors logged."
    fi
    HISTORY_SUMMARY="${#bsod_code[@]} BSOD, $whea hardware errors, $unexpected unexpected shutdowns"
}

report_disk_event() {
    local n="$1" want="$2" label="$3" level="$4"
    local i hits=0 last=""
    for ((i = 0; i < n; i++)); do
        if [ "${ev_provider[i]}" = "disk" ] && [ "${ev_id[i]}" = "$want" ]; then
            hits=$((hits + 1))
            last="${ev_time[i]% *}"
        fi
    done
    if [ "$hits" -gt 0 ]; then
        rep_line "    - $label x$hits (last $last)"
        rep_flag "$level" "Event log shows '$label' x$hits."
    fi
}

# --------------------------------------------------------------------------
# Section 9 - quick RAM test
# --------------------------------------------------------------------------

MEMTEST_SUMMARY=""

section_memtest() {
    local budget="$1"
    [ "$budget" -ge 5 ] 2>/dev/null || budget=5
    rep_section "9. QUICK MEMORY (RAM) TEST" "Memory test"

    local ps out line
    local -a f
    ps=$(build_memtest_ps "$budget")
    out=$(ps_run "$ps" "$((budget + 300))")
    local total=0 tested=0 passes=0 bad=0 noram=0
    while IFS= read -r line; do
        line=${line%$'\r'}
        [ -n "$line" ] || continue
        IFS='|' read -r -a f <<< "$line"
        case "${f[0]:-}" in
            PASS)
                local res="OK"
                [ "${f[3]:-0}" != "0" ] && res="${f[3]} corrupted 4 KB blocks"
                rep_line "    pass ${f[1]} (${f[2]}): $res  [${f[4]} s]"
                ;;
            NORAM) noram=1 ;;
            MT) total="${f[1]:-0}"; tested="${f[2]:-0}"; passes="${f[3]:-0}"; bad="${f[4]:-0}" ;;
        esac
    done <<< "$out"

    if [ "$noram" = "1" ] || [ "$tested" = "0" ] || [ -z "$tested" ]; then
        rep_flag YELLOW "Not enough free memory for the RAM test."
        MEMTEST_SUMMARY=""
        return
    fi
    local pct
    pct=$(awk -v t="$tested" -v tot="$total" 'BEGIN{ if (tot>0) printf "%.0f", t/tot*100; else print 0 }')
    rep_kv "Memory tested" "$(size_str "$tested" binary) of $(size_str "$total" binary) ($pct% - the part that was free)"
    rep_line "  Writing and verifying patterns for about $budget s..."

    if [ "$bad" != "0" ] && [ -n "$bad" ]; then
        rep_flag RED "RAM test found $bad corrupted 4 KB blocks - faulty memory. Confirm with MemTest86 before buying."
        MEMTEST_SUMMARY="ERRORS FOUND ($(size_str "$tested" binary) tested, $passes passes)"
    else
        rep_ok "No errors in $(size_str "$tested" binary) over $passes passes."
        MEMTEST_SUMMARY="OK ($(size_str "$tested" binary) tested, $passes passes)"
    fi
    rep_line "  -> Quick test of the free memory only. A full test: MemTest86 from a USB stick"
    rep_line "     (1+ hour) or Windows Memory Diagnostic (mdsched.exe, needs a restart)."
}

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------

MANUAL_CHECKS=(
    "Screen: open a full-screen white, black, red, green and blue image - look for dead pixels,"
    "  bright spots and backlight bleed. Tilt the lid - no flicker or lines."
    "Keyboard & touchpad: type every key (e.g. keyboard-test website / Notepad), test clicks."
    "Ports: try every USB port, HDMI, headphone jack, SD reader; charge via USB-C if supported."
    "Webcam, microphone and speakers (Camera app, Voice Recorder, a YouTube video)."
    "Wi-Fi and Bluetooth connect; hinges are firm; no cracks, swollen battery (lifted touchpad/case)."
    "Charger: original wattage; unplug and replug - Windows should switch to charging."
    "BIOS: reboot and enter BIOS setup (F2/Del/F1/Esc) - it must NOT ask for a password."
    "Ask the seller to remove their Microsoft account / reset Windows in front of you."
)

declare -ga FACTS=()

section_summary() {
    rep_section "SUMMARY" "Summary"
    local kv
    for kv in "${FACTS[@]:-}"; do
        [ -n "$kv" ] || continue
        rep_kv "${kv%%|*}" "${kv#*|}"
    done
    local i reds=0 yellows=0 notes=0
    for ((i = 0; i < ${#FLAG_LEVELS[@]}; i++)); do
        case "${FLAG_LEVELS[i]}" in
            RED) reds=$((reds + 1)) ;;
            YELLOW) yellows=$((yellows + 1)) ;;
            NOTE) notes=$((notes + 1)) ;;
        esac
    done
    rep_line ""
    if [ "$reds" -gt 0 ]; then
        rep_line "  RED FLAGS ($reds):" RED
        for ((i = 0; i < ${#FLAG_LEVELS[@]}; i++)); do
            [ "${FLAG_LEVELS[i]}" = "RED" ] && rep_line "   ! [${FLAG_SECTIONS[i]}] ${FLAG_MSGS[i]}" RED
        done
    else
        rep_line "  No red flags found." OK
    fi
    if [ "$yellows" -gt 0 ]; then
        rep_line "  WARNINGS ($yellows):" YELLOW
        for ((i = 0; i < ${#FLAG_LEVELS[@]}; i++)); do
            [ "${FLAG_LEVELS[i]}" = "YELLOW" ] && rep_line "   - [${FLAG_SECTIONS[i]}] ${FLAG_MSGS[i]}" YELLOW
        done
    fi
    if [ "$notes" -gt 0 ]; then
        rep_line "  NOTES ($notes):" NOTE
        for ((i = 0; i < ${#FLAG_LEVELS[@]}; i++)); do
            [ "${FLAG_LEVELS[i]}" = "NOTE" ] && rep_line "   * [${FLAG_SECTIONS[i]}] ${FLAG_MSGS[i]}" NOTE
        done
    fi
    rep_line ""
    case "$(verdict_for "$reds" "$yellows" "$notes")" in
        RED) rep_line "  VERDICT: serious problems found - negotiate the price down or walk away." RED ;;
        YELLOW) rep_line "  VERDICT: usable, but take the warnings into account in the price." YELLOW ;;
        *) rep_line "  VERDICT: hardware looks healthy. Finish the manual checks below." OK ;;
    esac
    rep_line ""
    rep_line "  MANUAL CHECKS (the script cannot test these):"
    local item
    for item in "${MANUAL_CHECKS[@]}"; do
        if [[ "$item" == "  "* ]]; then
            rep_line "      ${item#  }"
        else
            rep_line "  [ ] $item"
        fi
    done
}

# --------------------------------------------------------------------------
# Helpers used by main
# --------------------------------------------------------------------------

is_admin() {
    if [ "${HAVE_PS:-0}" = "1" ]; then
        local r
        r=$("$POWERSHELL" -NoProfile -Command "([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)" 2>/dev/null | tr -d '\r')
        [ "$r" = "True" ] && return 0
        return 1
    fi
    [ "$(id -u 2>/dev/null)" = "0" ]
}

relaunch_as_admin() {
    [ "${HAVE_PS:-0}" = "1" ] || return 1
    local bash_exe
    bash_exe=$(command -v bash 2>/dev/null) || return 1
    local args=""
    local a
    for a in "$@"; do
        args="$args '${a//\'/\'\'}'"
    done
    "$POWERSHELL" -NoProfile -Command "Start-Process -FilePath '${bash_exe//\'/\'\'}' -ArgumentList @('$SCRIPT_PATH'$args) -Verb RunAs" >/dev/null 2>&1
}

output_dir() {
    local d
    for d in "$SCRIPT_DIR" "$HOME/Desktop" "${TMPDIR:-/tmp}"; do
        if [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ]; then
            printf '%s' "$d"
            return 0
        fi
    done
    printf '%s' "$PWD"
}

usage() {
    cat <<'USAGE'
Usage: laptop_check.sh [options]

Inspect a used Windows 10/11 laptop before buying it.

Options:
  --seconds N          stress test length in seconds (default 30)
  --skip-stress        skip the CPU stress test
  --skip-memtest       skip the quick RAM test
  --memtest-seconds N  RAM test length in seconds (default 45)
  --history-days N     days of error history to read (default 90)
  --no-admin           do not ask for administrator rights
  --no-pause           do not wait for Enter at the end
  -h, --help           show this help
USAGE
}

OPT_SECONDS=30
OPT_SKIP_STRESS=0
OPT_SKIP_MEMTEST=0
OPT_MEMTEST_SECONDS=45
OPT_HISTORY_DAYS=90
OPT_NO_ADMIN=0
OPT_NO_PAUSE=0
OPT_ELEVATED=0
OPT_HELP=0

parse_args() {
    OPT_SECONDS=30
    OPT_SKIP_STRESS=0
    OPT_SKIP_MEMTEST=0
    OPT_MEMTEST_SECONDS=45
    OPT_HISTORY_DAYS=90
    OPT_NO_ADMIN=0
    OPT_NO_PAUSE=0
    OPT_ELEVATED=0
    OPT_HELP=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --seconds)
                [ $# -ge 2 ] || return 2
                OPT_SECONDS="$2"; shift 2 ;;
            --memtest-seconds)
                [ $# -ge 2 ] || return 2
                OPT_MEMTEST_SECONDS="$2"; shift 2 ;;
            --history-days)
                [ $# -ge 2 ] || return 2
                OPT_HISTORY_DAYS="$2"; shift 2 ;;
            --skip-stress) OPT_SKIP_STRESS=1; shift ;;
            --skip-memtest) OPT_SKIP_MEMTEST=1; shift ;;
            --no-admin) OPT_NO_ADMIN=1; shift ;;
            --no-pause) OPT_NO_PAUSE=1; shift ;;
            --elevated) OPT_ELEVATED=1; shift ;;
            -h | --help) OPT_HELP=1; shift ;;
            *)
                printf 'laptop_check.sh: unknown option: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done
    return 0
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
    parse_args "$@" || return $?
    if [ "$OPT_HELP" = "1" ]; then
        usage
        return 0
    fi

    if ! is_windows; then
        printf 'This script only runs on Windows 10/11 (from Git Bash / MSYS2 / Cygwin).\n'
        return 1
    fi

    local admin=0
    is_admin && admin=1
    if [ "$admin" = "0" ] && [ "$OPT_NO_ADMIN" = "0" ] && [ "$OPT_ELEVATED" = "0" ]; then
        printf 'Requesting administrator rights (needed for disk SMART data and temperatures)...\n'
        local -a passthrough=()
        local a
        for a in "$@"; do [ "$a" = "--elevated" ] || passthrough+=("$a"); done
        if relaunch_as_admin "${passthrough[@]:-}"; then
            printf 'The check continues in the new window.\n'
            return 0
        fi
        printf 'Administrator rights were not granted - continuing with limited data.\n\n'
    fi

    if [ -t 1 ]; then USE_COLOR=1; fi
    REPORT_LINES=()
    FLAG_LEVELS=()
    FLAG_SECTIONS=()
    FLAG_MSGS=()
    FACTS=()
    rep_line "USED LAPTOP INSPECTION REPORT" HEAD
    rep_line "Collecting data - this takes about 3 minutes..."

    local outdir stamp
    outdir=$(output_dir)
    stamp=$(date '+%Y%m%d_%H%M')

    section_system "$admin"
    section_cpu
    section_ram
    section_disks "$admin"
    section_battery "$outdir" "$stamp"
    section_windows "${SYS[PartOfDomain]:-}"
    STRESS_PEAK=""
    STRESS_CALC=""
    if [ "$OPT_SKIP_STRESS" = "0" ]; then
        section_stress "$OPT_SECONDS" "${CPU_THREADS[0]:-2}"
    fi
    section_uptime
    HISTORY_SUMMARY=""
    section_history "$OPT_HISTORY_DAYS"
    if [ "$OPT_SKIP_MEMTEST" = "0" ]; then
        section_memtest "$OPT_MEMTEST_SECONDS"
    fi

    FACTS+=("Model|$(clean "${SYS[Manufacturer]:-} ${SYS[Model]:-}")")
    FACTS+=("CPU|$(clean "${CPU_NAMES[0]:-}") (${CPU_CORES[0]:-0}C/${CPU_THREADS[0]:-0}T)")
    FACTS+=("RAM|$(size_str "${RAM_TOTAL[0]:-0}" binary) ${RAM_TYPES[0]:-}")
    FACTS+=("Storage|${DISK_SUMMARY:-n/a}")
    FACTS+=("Battery health|${BATT_SUMMARY:-n/a}")
    FACTS+=("Windows|$(clean "${WIN[caption]:-}") - $WIN_ACTIVATED")
    if [ -n "$STRESS_PEAK" ]; then FACTS+=("Peak CPU temperature|$(fmt "$STRESS_PEAK" '%.0f') C"); fi
    if [ -n "$STRESS_CALC" ]; then FACTS+=("CPU calculations|$STRESS_CALC"); fi
    if [ -n "$HISTORY_SUMMARY" ]; then FACTS+=("Last $OPT_HISTORY_DAYS days|$HISTORY_SUMMARY"); fi
    if [ -n "$MEMTEST_SUMMARY" ]; then FACTS+=("RAM test|$MEMTEST_SUMMARY"); fi
    section_summary

    local name
    name=$(clean "${SYS[ComputerName]:-}")
    [ -n "$name" ] || name="laptop"
    local path="$outdir/laptop_report_${name}_${stamp}.txt"
    if printf '%s\n' "${REPORT_LINES[@]}" > "$path" 2>/dev/null; then
        printf '\nReport saved to: %s\n' "$path"
    else
        printf '\nCould not save report: %s\n' "$path"
    fi

    if [ "$OPT_NO_PAUSE" = "0" ]; then
        printf '\nPress Enter to exit...'
        read -r _ 2>/dev/null || true
    fi
    return 0
}

# Run only when executed directly (so the test suite can source this file).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
