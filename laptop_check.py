#!/usr/bin/env python3
"""
laptop_check.py - inspect a used Windows 10/11 laptop before buying it.

Checks CPU, RAM, disks (health / SMART), battery wear, Windows version and
activation, runs a short CPU stress test that verifies every calculation and
measures temperatures, reports uptime,
reads the crash / hardware error history and runs a quick RAM test.
Prints a readable report with red flags and saves it to a text file.

No third-party packages are needed: all data comes from tools built into
Windows (PowerShell / CIM, powercfg, dsregcmd). Run it as administrator for
full disk and temperature data - the script asks for elevation by itself.

Optional: if smartctl.exe (smartmontools) is installed or placed next to this
script, full SMART attributes are read as well.

Usage:
    python laptop_check.py                 full check, 30 s stress test
    python laptop_check.py --seconds 60    longer stress test
    python laptop_check.py --skip-stress   no stress test
    python laptop_check.py --skip-memtest  no RAM test
"""

import argparse
import base64
import ctypes
import datetime as dt
import hashlib
import json
import math
import multiprocessing
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

IS_WINDOWS = os.name == "nt"
NO_WINDOW = 0x08000000 if IS_WINDOWS else 0  # CREATE_NO_WINDOW

RED, YELLOW, NOTE, OK = "RED", "YELLOW", "NOTE", "OK"
ANSI = {RED: "\033[91m", YELLOW: "\033[93m", NOTE: "\033[96m", OK: "\033[92m", "HEAD": "\033[1m"}
RESET = "\033[0m"

SMBIOS_MEMORY_TYPES = {
    20: "DDR", 21: "DDR2", 24: "DDR3", 26: "DDR4", 27: "LPDDR", 28: "LPDDR2",
    29: "LPDDR3", 30: "LPDDR4", 34: "DDR5", 35: "LPDDR5",
}
LICENSE_STATUS = {
    0: "Unlicensed", 1: "Licensed (activated)", 2: "Initial grace period",
    3: "Additional grace period", 4: "Non-genuine grace period",
    5: "Notification mode (NOT activated)", 6: "Extended grace period",
}
WINDOWS_APP_ID = "55c92734-d682-4d71-983e-d6ec3f16059f"


# --------------------------------------------------------------------------
# Report output
# --------------------------------------------------------------------------

class Report:
    def __init__(self, use_color):
        self.use_color = use_color
        self.lines = []
        self.flags = []  # (level, section, message)
        self.section_name = ""

    def _paint(self, text, style):
        if self.use_color and style in ANSI:
            return ANSI[style] + text + RESET
        return text

    def line(self, text="", style=None):
        print(self._paint(text, style), flush=True)
        self.lines.append(text)

    def section(self, title, short):
        self.section_name = short
        self.line()
        self.line("=" * 72, "HEAD")
        self.line(" " + title, "HEAD")
        self.line("=" * 72, "HEAD")

    def kv(self, key, value):
        self.line(f"  {key + ':':<34}{value}")

    def flag(self, level, message):
        self.flags.append((level, self.section_name, message))
        self.line(f"  [{level}] {message}", level)

    def ok(self, message):
        self.line(f"  [OK] {message}", OK)


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

PS_PREFIX = (
    "$ProgressPreference='SilentlyContinue';"
    "$WarningPreference='SilentlyContinue';"
    "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;\n"
)

# PowerShell helpers shared by the temperature / CPU samplers.
PS_SAMPLE_FUNCS = r"""
function Get-Temps {
  $list = @()
  try {
    foreach ($z in @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)) {
      $list += [pscustomobject]@{ Source = 'ACPI'; Name = [string]$z.InstanceName; C = [math]::Round($z.CurrentTemperature / 10.0 - 273.15, 1) }
    }
  } catch {}
  try {
    foreach ($z in @(Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop)) {
      $k = [double]$z.Temperature
      if ($z.HighPrecisionTemperature -gt 0) { $k = $z.HighPrecisionTemperature / 10.0 }
      $list += [pscustomobject]@{ Source = 'Perf'; Name = [string]$z.Name; C = [math]::Round($k - 273.15, 1) }
    }
  } catch {}
  return ,@($list | Where-Object { $_.C -gt 5 -and $_.C -lt 130 })
}
function Get-CpuSample {
  $s = [ordered]@{ Util = $null; PerfPct = $null; BaseMHz = $null; Temps = (Get-Temps) }
  try {
    $p = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
    $s.Util = [double]$p.PercentProcessorTime
    $s.PerfPct = [double]$p.PercentProcessorPerformance
    $s.BaseMHz = [double]$p.ProcessorFrequency
  } catch {}
  [pscustomobject]$s
}
"""


def ps_command(script):
    encoded = base64.b64encode((PS_PREFIX + script).encode("utf-16-le")).decode("ascii")
    return ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-EncodedCommand", encoded]


def run_ps(script, timeout=120):
    try:
        r = subprocess.run(ps_command(script), capture_output=True, timeout=timeout,
                           creationflags=NO_WINDOW)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.decode("utf-8", errors="replace").strip()


def parse_json_line(text):
    for line in reversed((text or "").splitlines()):
        line = line.strip().lstrip("\ufeff")
        if line.startswith("{") or line.startswith("["):
            try:
                return json.loads(line)
            except ValueError:
                pass
    return None


def ps_json(script, timeout=120):
    """Run a PowerShell script and return its output object as parsed JSON."""
    wrapped = ("$__r = & {\n" + script + "\n}\n"
               "if ($null -ne $__r) { ConvertTo-Json -InputObject $__r -Depth 6 -Compress }")
    return parse_json_line(run_ps(wrapped, timeout))


def as_list(x):
    if x is None:
        return []
    # Windows PowerShell 5.1 sometimes serialises arrays as {"value": [...], "Count": n}
    if isinstance(x, dict) and set(x) == {"value", "Count"}:
        return as_list(x["value"])
    return x if isinstance(x, list) else [x]


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def size_str(n, binary=False):
    n = num(n)
    if not n:
        return "n/a"
    v = n / (1024 ** 3 if binary else 1000 ** 3)
    if v >= 1000:
        return f"{v / 1000:.2f} TB"
    return f"{v:.0f} GB" if v >= 100 or v == int(v) else f"{v:.1f} GB"


def duration_str(seconds):
    seconds = int(seconds or 0)
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    parts = ([f"{d} day" + ("s" if d != 1 else "")] if d else []) + [f"{h} h", f"{m} min"]
    return " ".join(parts)


def clean(s):
    return re.sub(r"\s+", " ", str(s or "")).strip()


def run_cmd(args, timeout=60):
    try:
        r = subprocess.run(args, capture_output=True, timeout=timeout, creationflags=NO_WINDOW)
        return r.returncode, r.stdout.decode("utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return None, ""


def is_admin():
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def relaunch_as_admin(argv):
    script = os.path.abspath(sys.argv[0])
    params = subprocess.list2cmdline([script] + argv + ["--elevated"])
    rc = ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, params,
                                             os.path.dirname(script), 1)
    return rc > 32


def output_dir():
    candidates = [os.path.dirname(os.path.abspath(sys.argv[0])),
                  os.path.join(os.path.expanduser("~"), "Desktop"),
                  tempfile.gettempdir()]
    for d in candidates:
        try:
            test = os.path.join(d, ".laptop_check_write_test")
            with open(test, "w") as f:
                f.write("x")
            os.remove(test)
            return d
        except OSError:
            continue
    return os.getcwd()


# --------------------------------------------------------------------------
# Data collection
# --------------------------------------------------------------------------

def get_system():
    return ps_json(r"""
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$prod = Get-CimInstance Win32_ComputerSystemProduct
$biosDate = $null
if ($bios.ReleaseDate) { $biosDate = $bios.ReleaseDate.ToString('yyyy-MM-dd') }
[pscustomobject]@{
  Manufacturer = $cs.Manufacturer; Model = $cs.Model; ProductVersion = $prod.Version
  Serial = $bios.SerialNumber; BiosVersion = $bios.SMBIOSBIOSVersion; BiosDate = $biosDate
  PartOfDomain = [bool]$cs.PartOfDomain; Domain = $cs.Domain; ComputerName = $env:COMPUTERNAME
}
""") or {}


def section_system(rep, admin):
    s = get_system()
    rep.section("0. SYSTEM", "System")
    model = clean(s.get("Model"))
    pv = clean(s.get("ProductVersion"))
    if pv and pv.lower() not in ("none", "to be filled by o.e.m.") and pv not in model:
        model = f"{model} ({pv})"
    rep.kv("Manufacturer / model", f"{clean(s.get('Manufacturer'))} {model}".strip())
    rep.kv("Serial number", clean(s.get("Serial")) or "n/a")
    rep.kv("BIOS", f"{clean(s.get('BiosVersion'))}  ({s.get('BiosDate') or 'date n/a'})")
    rep.kv("Report time", dt.datetime.now().strftime("%Y-%m-%d %H:%M"))
    rep.kv("Running as administrator", "yes" if admin else "NO (some data will be missing)")
    rep.line("  -> Compare model and serial with the sticker under the laptop and the ad.")
    return s


def section_cpu(rep):
    rep.section("1. CPU", "CPU")
    cpus = as_list(ps_json(
        "Get-CimInstance Win32_Processor | Select-Object Name, Manufacturer, NumberOfCores, "
        "NumberOfLogicalProcessors, MaxClockSpeed"))
    if not cpus:
        rep.flag(YELLOW, "Could not read CPU information.")
        return {}
    for i, c in enumerate(cpus):
        if len(cpus) > 1:
            rep.line(f"  Socket {i}:")
        rep.kv("Model", clean(c.get("Name")))
        rep.kv("Physical cores", c.get("NumberOfCores"))
        rep.kv("Logical processors (threads)", c.get("NumberOfLogicalProcessors"))
        rep.kv("Base clock", f"{c.get('MaxClockSpeed')} MHz")
    rep.line("  -> Make sure the CPU model matches exactly what the seller advertised.")
    return cpus[0]


def section_ram(rep):
    rep.section("2. MEMORY (RAM)", "RAM")
    data = ps_json(r"""
$m = @(Get-CimInstance Win32_PhysicalMemory | Select-Object Capacity, Speed, ConfiguredClockSpeed, SMBIOSMemoryType, Manufacturer, PartNumber, DeviceLocator, FormFactor)
$a = @(Get-CimInstance Win32_PhysicalMemoryArray | Select-Object MemoryDevices, MaxCapacityEx)
$cs = Get-CimInstance Win32_ComputerSystem
[pscustomobject]@{ Modules = $m; Arrays = $a; Visible = [double]$cs.TotalPhysicalMemory }
""") or {}
    modules = as_list(data.get("Modules"))
    arrays = as_list(data.get("Arrays"))
    installed = sum(num(m.get("Capacity")) or 0 for m in modules)
    visible = num(data.get("Visible"))
    total = installed or visible or 0

    rep.kv("Total installed", f"{size_str(total, True)}"
           + (f"  ({size_str(visible, True)} usable by Windows)" if visible else ""))
    types = sorted({SMBIOS_MEMORY_TYPES.get(int(num(m.get("SMBIOSMemoryType")) or 0), "unknown")
                    for m in modules})
    if modules:
        rep.kv("Type", ", ".join(types))
    slots = sum(int(num(a.get("MemoryDevices")) or 0) for a in arrays)
    if slots:
        rep.kv("Slots used", f"{len(modules)} of {slots}")
    else:
        rep.kv("Modules detected", len(modules))
    for m in modules:
        speed = num(m.get("Speed"))
        conf = num(m.get("ConfiguredClockSpeed"))
        sp = f"{speed:.0f} MT/s" if speed else "speed n/a"
        if conf and speed and conf != speed:
            sp += f" (running at {conf:.0f})"
        rep.line(f"    - {clean(m.get('DeviceLocator')) or 'slot ?'}: {size_str(m.get('Capacity'), True)}, "
                 f"{SMBIOS_MEMORY_TYPES.get(int(num(m.get('SMBIOSMemoryType')) or 0), '?')}, {sp}, "
                 f"{clean(m.get('Manufacturer'))} {clean(m.get('PartNumber'))}".rstrip())
    rep.line("  -> Slot counts reported by laptops are not always accurate; soldered RAM")
    rep.line("     also appears as a module.")

    gib = total / 1024 ** 3 if total else 0
    if not total:
        rep.flag(YELLOW, "Could not read RAM size.")
    elif gib < 3.5:
        rep.flag(RED, f"Only {gib:.0f} GB RAM - too little for Windows 11.")
    elif gib < 7.5:
        rep.flag(YELLOW, f"Only {gib:.0f} GB RAM - will feel slow; 8 GB minimum, 16 GB recommended.")
    else:
        rep.ok(f"{gib:.0f} GB RAM.")
    if len(modules) == 1 and slots >= 2:
        rep.flag(NOTE, "Single RAM module with a free slot: runs single-channel (slower), but upgradeable.")
    return {"total": total, "types": types}


def find_smartctl():
    found = shutil.which("smartctl")
    if found:
        return found
    here = os.path.dirname(os.path.abspath(sys.argv[0]))
    for c in (os.path.join(here, "smartctl.exe"),
              r"C:\Program Files\smartmontools\bin\smartctl.exe",
              r"C:\Program Files (x86)\smartmontools\bin\smartctl.exe"):
        if os.path.exists(c):
            return c
    return None


def smartctl_devices(exe):
    _, out = run_cmd([exe, "--scan-open", "-j"])
    devs = []
    try:
        for d in json.loads(out).get("devices", []):
            _, info = run_cmd([exe, "-a", "-j", "-d", d.get("type", "auto"), d["name"]])
            devs.append(json.loads(info))
    except (ValueError, KeyError, TypeError):
        pass
    return devs


def report_smartctl(rep, d):
    model = clean(d.get("model_name")) or clean((d.get("device") or {}).get("name"))
    rep.line(f"  smartctl: {model}")
    passed = (d.get("smart_status") or {}).get("passed")
    if passed is not None:
        rep.kv("    SMART overall", "PASSED" if passed else "FAILED")
        if not passed:
            rep.flag(RED, f"{model}: SMART self-assessment FAILED.")
    poh = (d.get("power_on_time") or {}).get("hours")
    if poh is not None:
        rep.kv("    Power-on hours", poh)
    temp = (d.get("temperature") or {}).get("current")
    if temp is not None:
        rep.kv("    Temperature", f"{temp} C")
    nv = d.get("nvme_smart_health_information_log")
    if nv:
        used = nv.get("percentage_used")
        spare, thr = nv.get("available_spare"), nv.get("available_spare_threshold")
        rep.kv("    Life used (NVMe)", f"{used}%")
        rep.kv("    Available spare", f"{spare}% (threshold {thr}%)")
        rep.kv("    Media errors", nv.get("media_errors"))
        rep.kv("    Unsafe shutdowns", nv.get("unsafe_shutdowns"))
        if nv.get("data_units_written") is not None:
            rep.kv("    Data written", f"{nv['data_units_written'] * 512000 / 1e12:.1f} TB")
        if nv.get("critical_warning"):
            rep.flag(RED, f"{model}: NVMe critical warning = {nv['critical_warning']}.")
        if nv.get("media_errors"):
            rep.flag(RED, f"{model}: {nv['media_errors']} media/data-integrity errors.")
        if spare is not None and thr is not None and spare <= thr:
            rep.flag(RED, f"{model}: spare blocks exhausted ({spare}%).")
    attrs = {a.get("id"): a for a in (d.get("ata_smart_attributes") or {}).get("table", [])}
    for aid, label in ((5, "Reallocated sectors"), (187, "Reported uncorrectable"),
                       (197, "Pending sectors"), (198, "Offline uncorrectable")):
        if aid in attrs:
            raw = (attrs[aid].get("raw") or {}).get("value", 0)
            rep.kv(f"    {label}", raw)
            if raw:
                rep.flag(RED, f"{model}: {label} = {raw} (surface/flash damage).")


def section_disks(rep, admin):
    rep.section("3. STORAGE", "Storage")
    data = ps_json(r"""
$disks = @()
foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
  $rel = $null
  try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop | Select-Object Temperature, TemperatureMax, Wear, PowerOnHours, ReadErrorsUncorrected, WriteErrorsUncorrected } catch {}
  $letters = ''
  try { $letters = (@(Get-Partition -DiskNumber $d.DeviceId -ErrorAction Stop | Where-Object { [string]$_.DriveLetter -match '^[A-Z]$' } | ForEach-Object { [string]$_.DriveLetter + ':' }) -join ' ') } catch {}
  $disks += [pscustomobject]@{
    Number = $d.DeviceId; Model = $d.FriendlyName; Serial = ([string]$d.SerialNumber).Trim()
    Size = [double]$d.Size; MediaType = [string]$d.MediaType; BusType = [string]$d.BusType
    Health = [string]$d.HealthStatus; Status = ((@($d.OperationalStatus) | ForEach-Object { [string]$_ }) -join ', ')
    Letters = $letters; Rel = $rel
  }
}
$pred = @()
try { $pred = @(Get-CimInstance -Namespace root/wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Select-Object InstanceName, PredictFailure) } catch {}
[pscustomobject]@{ Disks = $disks; Predict = $pred }
""") or {}
    disks = as_list(data.get("Disks"))
    if not disks:
        rep.flag(YELLOW, "Could not list physical disks.")
    summary = []
    for d in disks:
        model = clean(d.get("Model")) or "Unknown disk"
        bus, media = d.get("BusType") or "?", d.get("MediaType") or "?"
        if bus == "RAID" and "NVME" in model.upper():
            bus = "NVMe (via Intel RST/VMD)"  # Windows reports these NVMe drives as RAID
        if media == "Unspecified":
            media = "SSD?" if bus.startswith("NVMe") else "?"
        rep.line()
        rep.line(f"  Disk {d.get('Number')}: {model}")
        rep.kv("    Capacity", size_str(d.get("Size")))
        rep.kv("    Type / interface", f"{media} / {bus}")
        rep.kv("    Drive letters", d.get("Letters") or "-")
        rep.kv("    Windows health status", f"{d.get('Health')}  ({d.get('Status')})")
        rel = d.get("Rel") or {}
        wear, poh, temp = num(rel.get("Wear")), num(rel.get("PowerOnHours")), num(rel.get("Temperature"))
        rerr = num(rel.get("ReadErrorsUncorrected")) or 0
        werr = num(rel.get("WriteErrorsUncorrected")) or 0
        if rel:
            rep.kv("    Wear (life used)", f"{wear:.0f}%" if wear is not None else "not reported")
            rep.kv("    Power-on hours", f"{poh:.0f}" if poh else "not reported")
            rep.kv("    Temperature", f"{temp:.0f} C" if temp else "not reported")
            rep.kv("    Uncorrected R/W errors", f"{rerr:.0f} / {werr:.0f}")
        else:
            rep.kv("    SMART counters", "unavailable" + ("" if admin else " (run as administrator)"))

        if bus == "USB":
            rep.flag(NOTE, f"{model} is an external USB drive - not part of the laptop.")
        if d.get("Health") not in ("Healthy", None, ""):
            rep.flag(RED, f"{model}: Windows reports health '{d.get('Health')}'.")
        if wear is not None and wear >= 90:
            rep.flag(RED, f"{model}: {wear:.0f}% of rated life used - near end of life.")
        elif wear is not None and wear >= 60:
            rep.flag(YELLOW, f"{model}: {wear:.0f}% of rated life used.")
        if rerr or werr:
            rep.flag(RED, f"{model}: uncorrected read/write errors ({rerr:.0f}/{werr:.0f}).")
        if poh and poh > 25000:
            rep.flag(YELLOW, f"{model}: {poh:.0f} power-on hours (~{poh / 8760:.1f} years non-stop).")
        if temp and temp >= 70:
            rep.flag(YELLOW, f"{model}: running hot at {temp:.0f} C.")
        if media == "HDD" and bus != "USB":
            rep.flag(YELLOW, f"{model} is a mechanical hard drive - much slower than an SSD.")
        if bus != "USB":
            summary.append(f"{size_str(d.get('Size'))} {'NVMe' if bus.startswith('NVMe') else media}")

    for p in as_list(data.get("Predict")):
        if p.get("PredictFailure"):
            rep.flag(RED, f"SMART predicts imminent failure: {clean(p.get('InstanceName'))}")

    exe = find_smartctl()
    if exe:
        rep.line()
        rep.line(f"  Full SMART data from {exe}:")
        devs = smartctl_devices(exe)
        if not devs:
            rep.line("  smartctl returned no data" + ("" if admin else " (needs administrator)."))
        for d in devs:
            report_smartctl(rep, d)
    else:
        rep.line()
        rep.line("  (Optional: install smartmontools or put smartctl.exe next to this script")
        rep.line("   for full SMART attributes.)")
    return summary


def section_battery(rep, outdir, stamp):
    rep.section("4. BATTERY", "Battery")
    batteries = []
    xml_path = os.path.join(tempfile.gettempdir(), f"laptop_check_battery_{os.getpid()}.xml")
    run_cmd(["powercfg", "/batteryreport", "/xml", "/output", xml_path])
    try:
        for el in ET.parse(xml_path).iter():
            if el.tag.split("}")[-1] == "Battery":
                batteries.append({c.tag.split("}")[-1]: (c.text or "").strip() for c in el})
        os.remove(xml_path)
    except (OSError, ET.ParseError):
        pass

    wmi = ps_json(r"""
$r = [ordered]@{ Design = @(); Full = @(); Cycles = @(); VoltageNow = @(); Win32 = @() }
try { $r.Design = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction Stop | ForEach-Object { $_.DesignedCapacity }) } catch {}
try { $r.Full = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | ForEach-Object { $_.FullChargedCapacity }) } catch {}
try { $r.Cycles = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryCycleCount -ErrorAction Stop | ForEach-Object { $_.CycleCount }) } catch {}
try { $r.VoltageNow = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop | ForEach-Object { $_.Voltage }) } catch {}
$r.Win32 = @(Get-CimInstance Win32_Battery | Select-Object Name, EstimatedChargeRemaining, BatteryStatus, DesignVoltage)
[pscustomobject]$r
""") or {}
    win32 = as_list(wmi.get("Win32"))

    # Windows reports capacity in mWh; mAh = mWh / volts. Prefer the design (nominal)
    # voltage, fall back to the voltage measured right now.
    volts = None
    for mv in [w.get("DesignVoltage") for w in win32] + as_list(wmi.get("VoltageNow")):
        if num(mv) and 5000 <= num(mv) <= 25000:
            volts = num(mv) / 1000
            break

    def cap(mwh):
        text = f"{mwh:,.0f} mWh"
        return text + (f" (~{mwh / volts:,.0f} mAh)" if volts else "")

    if not batteries:
        design, full, cycles = as_list(wmi.get("Design")), as_list(wmi.get("Full")), as_list(wmi.get("Cycles"))
        for i in range(max(len(design), len(full))):
            batteries.append({
                "DesignCapacity": design[i] if i < len(design) else None,
                "FullChargeCapacity": full[i] if i < len(full) else None,
                "CycleCount": cycles[i] if i < len(cycles) else None,
            })

    if not batteries and not win32:
        rep.flag(RED, "No battery detected! (removed, dead, or disconnected)")
        return None

    summary = None
    for i, b in enumerate(batteries):
        if len(batteries) > 1:
            rep.line(f"  Battery {i + 1}:")
        design, full, cycles = num(b.get("DesignCapacity")), num(b.get("FullChargeCapacity")), num(b.get("CycleCount"))
        name = " ".join(x for x in (clean(b.get("Manufacturer")), clean(b.get("Id"))) if x)
        if name:
            rep.kv("Battery", name + (f" ({clean(b.get('Chemistry'))})" if b.get("Chemistry") else ""))
        if b.get("ManufactureDate"):
            rep.kv("Manufacture date", clean(b.get("ManufactureDate")))
        rep.kv("Original capacity (when new)", cap(design) if design else "n/a")
        rep.kv("Capacity left (full charge)", cap(full) if full else "n/a")
        if design and full:
            health = full / design * 100
            unit, scale = ("mAh", volts) if volts else ("mWh", 1)
            left = f"{full / scale:,.0f} {unit} of {design / scale:,.0f} {unit}"
            rep.kv("Remaining from original", f"{health:.0f}%  = {left}  (lost {max(0, 100 - health):.0f}%)")
            if summary is None or health < summary[0]:
                summary = (health, f"{health:.0f}% of original ({left})")
            if health < 60:
                rep.flag(RED, f"Battery health {health:.0f}% - plan on replacing the battery.")
            elif health < 80:
                rep.flag(YELLOW, f"Battery health {health:.0f}% - noticeably reduced runtime.")
            else:
                rep.ok(f"Battery health {health:.0f}%.")
            if health > 105:
                rep.flag(NOTE, "Capacity above design value - battery may be new or poorly calibrated.")
        else:
            rep.flag(YELLOW, "Battery capacity not reported - cannot calculate health.")
        if cycles:
            rep.kv("Charge cycles", f"{cycles:.0f}")
            if cycles > 800:
                rep.flag(RED, f"{cycles:.0f} charge cycles - battery is near end of life.")
            elif cycles > 500:
                rep.flag(YELLOW, f"{cycles:.0f} charge cycles - battery is well used.")
        else:
            rep.kv("Charge cycles", "not reported by the battery")
        if design and full and full / design < 0.8 and cycles and cycles < 100:
            rep.flag(NOTE, f"Only {cycles:.0f} cycles but {100 - full / design * 100:.0f}% capacity lost - the "
                           "cycle counter may be unreliable, or the battery aged from time and heat.")
    if volts:
        rep.line(f"  -> mAh calculated from mWh at the battery's {volts:.2f} V.")
    for w in win32:
        status = int(num(w.get("BatteryStatus")) or 0)
        rep.kv("Charge level right now", f"{w.get('EstimatedChargeRemaining')}%  "
               f"({'on battery' if status == 1 else 'charger connected'}) - not battery health")

    html = os.path.join(outdir, f"battery-report_{stamp}.html")
    run_cmd(["powercfg", "/batteryreport", "/output", html])
    if os.path.exists(html):
        rep.line(f"  Detailed battery history saved to: {html}")
    return summary


def dsreg_status():
    _, out = run_cmd(["dsregcmd", "/status"])
    found = {}
    for key in ("AzureAdJoined", "DomainJoined", "EnterpriseJoined", "WorkplaceJoined"):
        m = re.search(rf"^\s*{key}\s*:\s*(YES|NO)", out, re.M | re.I)
        if m:
            found[key] = m.group(1).upper() == "YES"
    return found


def section_windows(rep, system):
    rep.section("5. WINDOWS", "Windows")
    w = ps_json(r"""
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$pw = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue
$lic = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='__APPID__' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue | Select-Object Name, Description, LicenseStatus, PartialProductKey, ProductKeyChannel)
$svc = Get-CimInstance SoftwareLicensingService -ErrorAction SilentlyContinue
$ap = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot' -ErrorAction SilentlyContinue
$mdm = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | Get-ItemProperty -ErrorAction SilentlyContinue | Where-Object { $_.ProviderID -eq 'MS DM Server' } | ForEach-Object { [string]$_.UPN })
[pscustomobject]@{
  Caption = $os.Caption; Version = $os.Version; Build = [int]$os.BuildNumber; Arch = $os.OSArchitecture
  DisplayVersion = $cv.DisplayVersion; UBR = $cv.UBR
  InstallDate = $os.InstallDate.ToString('yyyy-MM-dd'); InstallDays = [math]::Round(((Get-Date) - $os.InstallDate).TotalDays, 1)
  LastBoot = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'); UptimeSec = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalSeconds)
  FastStartup = $pw.HiberbootEnabled
  Licenses = $lic
  HasOemKey = [bool]$svc.OA3xOriginalProductKey; OemKeyDescription = $svc.OA3xOriginalProductKeyDescription
  AutopilotTenant = $ap.CloudAssignedTenantDomain
  MdmUpns = $mdm
}
""".replace("__APPID__", WINDOWS_APP_ID)) or {}
    build = int(num(w.get("Build")) or 0)
    rep.kv("Edition", clean(w.get("Caption")) or "n/a")
    ver = f"{w.get('DisplayVersion') or ''} (build {build}.{w.get('UBR') or 0})".strip()
    rep.kv("Version", f"{ver}, {w.get('Arch') or ''}")
    if build and build < 22000:
        rep.flag(NOTE, "This is Windows 10, not Windows 11.")
    rep.kv("Installed / last major update", f"{w.get('InstallDate')} ({num(w.get('InstallDays')) or 0:.0f} days ago)")

    lic = as_list(w.get("Licenses"))
    activated = None
    if lic:
        main = sorted(lic, key=lambda x: x.get("LicenseStatus") != 1)[0]
        status = int(num(main.get("LicenseStatus")) or 0)
        activated = status == 1
        rep.kv("Activation", LICENSE_STATUS.get(status, f"status {status}"))
        channel = clean(main.get("ProductKeyChannel")) or clean(main.get("Description"))
        rep.kv("License channel", channel)
        if not activated:
            rep.flag(RED, "Windows is NOT activated.")
        else:
            rep.ok("Windows is activated.")
        if "KMS" in (str(main.get("Description")) + str(main.get("ProductKeyChannel"))).upper() \
                and not system.get("PartOfDomain"):
            rep.flag(YELLOW, "Activated via KMS (volume license). On a home laptop this usually "
                             "means an unofficial activator; it may stop being activated.")
    else:
        rep.flag(YELLOW, "Could not determine activation status (try running slmgr /xpr).")
    rep.kv("Factory license key in BIOS", ("yes - " + clean(w.get("OemKeyDescription")))
           if w.get("HasOemKey") else "no")

    # Is the device owned/managed by an organisation? (company / stolen laptops)
    reg = dsreg_status()
    managed = []
    if system.get("PartOfDomain") or reg.get("DomainJoined"):
        managed.append(f"joined to domain '{clean(system.get('Domain'))}'")
    if reg.get("AzureAdJoined"):
        managed.append("joined to Microsoft Entra ID (Azure AD)")
    if reg.get("EnterpriseJoined"):
        managed.append("enterprise joined")
    if as_list(w.get("MdmUpns")):
        managed.append("enrolled in MDM (e.g. Intune): " + ", ".join(clean(u) for u in as_list(w.get("MdmUpns")) if u))
    if w.get("AutopilotTenant"):
        managed.append(f"registered in Windows Autopilot to '{clean(w.get('AutopilotTenant'))}'")
    rep.kv("Organisation management", "; ".join(managed) if managed else "none detected")
    if managed:
        rep.flag(RED, "Laptop is managed by an organisation (" + "; ".join(managed) + "). It may be "
                      "company property and can be locked remotely or after a reset - ask for proof.")
    return w, activated


def section_uptime(rep, w):
    rep.section("7. UPTIME", "Uptime")
    rep.kv("Last boot", w.get("LastBoot") or "n/a")
    rep.kv("Uptime", duration_str(w.get("UptimeSec")))
    if w.get("FastStartup") == 1:
        rep.line("  -> Fast Startup is ON: 'Shut down' does not reset uptime, only 'Restart' does.")


# --------------------------------------------------------------------------
# Stress test
# --------------------------------------------------------------------------

def _verify_data():
    # 1 MB of fixed pseudo-random data, identical in every process.
    return b"".join(hashlib.sha256(i.to_bytes(4, "little")).digest() for i in range(32768))


def _verified_work(data):
    """A fixed calculation with a known answer: SHA-256 chain + floating-point series."""
    digest = b""
    for _ in range(4):
        h = hashlib.sha256(digest)
        h.update(data)
        digest = h.digest()
    acc = sum(math.sqrt(i) * math.sin(i) / i for i in range(1, 20000))
    return digest + repr(acc).encode()


def _stress_worker(stop_at, expected, idx, counts, errors):
    # Each worker repeats the calculation and compares it with the answer computed
    # before the load started. A different result means the CPU miscalculated.
    data = _verify_data()
    while time.time() < stop_at:
        if _verified_work(data) != expected:
            errors[idx] += 1
        counts[idx] += 1


def stream_samples(seconds, interval_ms, on_sample=None):
    script = PS_SAMPLE_FUNCS + r"""
$end = (Get-Date).AddSeconds(__SECONDS__)
$null = Get-CpuSample
while ((Get-Date) -lt $end) {
  Start-Sleep -Milliseconds __MS__
  [Console]::Out.WriteLine((Get-CpuSample | ConvertTo-Json -Compress -Depth 4))
  [Console]::Out.Flush()
}
""".replace("__SECONDS__", str(seconds)).replace("__MS__", str(interval_ms))
    samples = []
    start = time.time()
    try:
        proc = subprocess.Popen(ps_command(script), stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, creationflags=NO_WINDOW)
    except OSError:
        return samples
    for raw in proc.stdout:
        s = parse_json_line(raw.decode("utf-8", errors="replace"))
        if isinstance(s, dict):
            s["t"] = time.time() - start
            s["Temps"] = as_list(s.get("Temps"))
            samples.append(s)
            if on_sample:
                on_sample(s)
    proc.wait()
    return samples


def max_temp(samples):
    vals = [num(t.get("C")) for s in samples for t in as_list(s.get("Temps"))]
    vals = [v for v in vals if v is not None]
    return max(vals) if vals else None


def avg(values):
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None


def section_stress(rep, seconds, cpu):
    rep.section(f"6. CPU STRESS TEST ({seconds} s) + TEMPERATURES", "Stress test")
    rep.line("  Tip: connect the charger and close other programs for a fair result.")
    rep.line("  Measuring idle state...")
    idle = stream_samples(4, 1000)

    threads = int(num(cpu.get("NumberOfLogicalProcessors")) or os.cpu_count() or 2)
    rep.line(f"  Loading all {threads} threads for {seconds} s, verifying every calculation...")
    expected = _verified_work(_verify_data())  # the correct answer, computed on a cool CPU
    counts = multiprocessing.RawArray("q", threads)
    errors = multiprocessing.RawArray("q", threads)
    rates, last = [], {"t": time.time(), "n": 0}

    def show(s):
        perf, base = num(s.get("PerfPct")), num(s.get("BaseMHz"))
        mhz = f"~{base * perf / 100 / 1000:.2f} GHz" if perf and base else "clock n/a"
        t = max_temp([s])
        now, done = time.time(), sum(counts)
        rate = (done - last["n"]) / max(now - last["t"], 0.001)
        last.update(t=now, n=done)
        rates.append(rate)
        rep.line(f"    t={s['t']:5.1f}s  CPU {num(s.get('Util')) or 0:5.1f}%  {mhz}  "
                 f"temp {f'{t:.0f} C' if t is not None else 'n/a'}  {rate:6.1f} calc/s  "
                 f"errors {sum(errors)}")

    # The load runs slightly longer than the sampler, which needs ~1 s to start.
    sampler_args = (seconds, 2000)
    stop_at = time.time() + seconds + 1.5
    workers = [multiprocessing.Process(target=_stress_worker, args=(stop_at, expected, i, counts, errors),
                                       daemon=True) for i in range(threads)]
    for p in workers:
        p.start()
    last["t"] = time.time()
    load = stream_samples(*sampler_args, on_sample=show)
    crashed = 0
    for p in workers:
        p.join(timeout=10)
        if p.is_alive():
            p.terminate()
        elif p.exitcode:
            crashed += 1
    total, wrong = sum(counts), sum(errors)

    rep.line("  Cooling down for 10 s...")
    time.sleep(8)
    after = stream_samples(2, 1000)

    steady = load[2:] if len(load) > 4 else load
    util = avg([num(s.get("Util")) for s in steady])
    perf = avg([num(s.get("PerfPct")) for s in steady])
    base = avg([num(s.get("BaseMHz")) for s in steady]) or num(cpu.get("MaxClockSpeed"))
    t_idle, t_peak = max_temp(idle), max_temp(load)
    t_end, t_after = max_temp(load[-1:]), max_temp(after)

    def tstr(v):
        return f"{v:.0f} C" if v is not None else "n/a"

    rep.line()
    rep.kv("Temperature before (idle)", tstr(t_idle))
    rep.kv("Temperature peak under load", tstr(t_peak))
    rep.kv("Temperature at end of load", tstr(t_end))
    rep.kv("Temperature after 10 s cooldown", tstr(t_after))
    if util is not None:
        rep.kv("Average CPU load", f"{util:.0f}%")
    if perf and base:
        rep.kv("Average clock under load", f"~{base * perf / 100:.0f} MHz ({perf:.0f}% of base {base:.0f} MHz)")

    all_temps = {num(t.get("C")) for s in idle + load + after for t in s["Temps"]}
    if t_peak is None:
        rep.flag(NOTE, "This laptop does not expose a temperature sensor to Windows. For exact CPU "
                       "temperatures use HWiNFO or LibreHardwareMonitor (portable).")
    elif len(all_temps) == 1:
        rep.flag(NOTE, f"Temperature sensor stays fixed at {t_peak:.0f} C - it is an ACPI zone, not the "
                       "real CPU temperature. Use HWiNFO for real values.")
    elif t_peak >= 95:
        rep.flag(RED, f"CPU reached {t_peak:.0f} C - overheating (dust, dried thermal paste or fan problem).")
    elif t_peak >= 88:
        rep.flag(YELLOW, f"CPU reached {t_peak:.0f} C - running hot; cooling may need cleaning.")
    else:
        rep.ok(f"Peak temperature {t_peak:.0f} C.")

    if perf:
        if perf < 50:
            rep.flag(RED, f"CPU ran at only {perf:.0f}% of base clock under load - heavy throttling "
                          "(overheating, failing fan, worn battery/charger or power-saving mode).")
        elif perf < 80:
            rep.flag(YELLOW, f"CPU ran at {perf:.0f}% of base clock under load - some throttling. "
                             "Check that the charger is connected and power mode is 'Best performance'.")
        else:
            rep.ok("No significant throttling detected.")
    if util is not None and util < 80:
        rep.flag(NOTE, f"CPU load only reached {util:.0f}% - the result may be less reliable.")

    rep.kv("Calculations verified", f"{total:,} ({wrong} wrong)")
    # Skip the first sample (workers still starting) and compare start vs end speed.
    speed = rates[1:]
    drop = None
    if len(speed) >= 4:
        start_rate, end_rate = avg(speed[:2]), avg(speed[-2:])
        if start_rate:
            drop = (1 - end_rate / start_rate) * 100
            rep.kv("Speed start -> end of test", f"{start_rate:.1f} -> {end_rate:.1f} calc/s "
                                                 f"({-round(drop):+d}%)")
    if wrong:
        rep.flag(RED, f"CPU produced {wrong} wrong results under load - unstable (overheating, "
                      "undervolting/overclocking, or faulty CPU/RAM).")
    elif total:
        rep.ok(f"All {total:,} calculations under load were correct.")
    else:
        rep.flag(YELLOW, "The verified stress test did not run - result unknown.")
    if crashed:
        rep.flag(RED, f"{crashed} stress test worker(s) crashed under load.")
    if drop is not None and drop >= 50:
        rep.flag(YELLOW, f"Speed fell {drop:.0f}% during the test - strong thermal/power throttling. "
                         "(A drop of up to ~30% is normal when turbo boost ends.)")
    return {"peak": t_peak, "calc": f"{total:,} verified, {wrong} wrong"}


# --------------------------------------------------------------------------
# Crash / hardware error history (Windows System event log)
# --------------------------------------------------------------------------

# Bugcheck (blue screen) code -> (name, likely cause, severity)
BUGCHECKS = {
    0x0A: ("IRQL_NOT_LESS_OR_EQUAL", "driver or RAM", YELLOW),
    0x1A: ("MEMORY_MANAGEMENT", "RAM", RED),
    0x1E: ("KMODE_EXCEPTION_NOT_HANDLED", "driver", NOTE),
    0x3B: ("SYSTEM_SERVICE_EXCEPTION", "driver", NOTE),
    0x50: ("PAGE_FAULT_IN_NONPAGED_AREA", "RAM or driver", YELLOW),
    0x77: ("KERNEL_STACK_INPAGE_ERROR", "disk", RED),
    0x7A: ("KERNEL_DATA_INPAGE_ERROR", "disk", RED),
    0x7E: ("SYSTEM_THREAD_EXCEPTION_NOT_HANDLED", "driver", NOTE),
    0x9C: ("MACHINE_CHECK_EXCEPTION", "CPU", RED),
    0x9F: ("DRIVER_POWER_STATE_FAILURE", "driver", NOTE),
    0xD1: ("DRIVER_IRQL_NOT_LESS_OR_EQUAL", "driver", NOTE),
    0xEF: ("CRITICAL_PROCESS_DIED", "software or disk", YELLOW),
    0xF4: ("CRITICAL_OBJECT_TERMINATION", "disk", RED),
    0x101: ("CLOCK_WATCHDOG_TIMEOUT", "CPU", RED),
    0x116: ("VIDEO_TDR_FAILURE", "GPU or graphics driver", YELLOW),
    0x119: ("VIDEO_SCHEDULER_INTERNAL_ERROR", "GPU or graphics driver", YELLOW),
    0x124: ("WHEA_UNCORRECTABLE_ERROR", "CPU/RAM hardware or overheating", RED),
    0x12B: ("FAULTY_HARDWARE_CORRUPTED_PAGE", "RAM", RED),
    0x133: ("DPC_WATCHDOG_VIOLATION", "driver or SSD firmware", YELLOW),
    0x139: ("KERNEL_SECURITY_CHECK_FAILURE", "driver or RAM", YELLOW),
    0x154: ("UNEXPECTED_STORE_EXCEPTION", "disk", RED),
}
WHEA_KINDS = {17: "corrected PCIe/bus error", 18: "fatal CPU error", 19: "corrected CPU error",
              47: "corrected memory error"}
DISK_EVENTS = {7: ("bad block on disk", RED), 51: ("disk paging error", YELLOW),
               153: ("disk I/O retried", YELLOW)}

PS_HISTORY = r"""
$since = (Get-Date).AddDays(-__DAYS__)
$events = @()
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
    $code = $null; $button = $false
    if ($e.Id -eq 41) {
      if ($vals.Count -gt 0) { $code = [int64]$vals[0] }
      if ($vals.Count -gt 6) { $button = ([int64]$vals[6] -ne 0) }
    } elseif ($e.Id -eq 1001) {
      $m = [regex]::Match((($vals -join ' ') + ' ' + $e.Message), '0x([0-9a-fA-F]{1,8})\b')
      if ($m.Success) { $code = [Convert]::ToInt64($m.Groups[1].Value, 16) }
    }
    $events += [pscustomobject]@{ Time = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'); Provider = $e.ProviderName; Id = $e.Id; Level = [int]$e.Level; Code = $code; Button = $button }
  }
}
$dumps = @()
try { $dumps = @(Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" -ErrorAction Stop | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.LastWriteTime.ToString('yyyy-MM-dd') }) } catch {}
$oldest = $null
try { $oldest = (Get-WinEvent -LogName System -MaxEvents 1 -Oldest -ErrorAction Stop).TimeCreated.ToString('yyyy-MM-dd') } catch {}
[pscustomobject]@{ Events = $events; Dumps = $dumps; Oldest = $oldest }
"""


def bugcheck_info(code):
    code = int(code or 0)
    if code >= 0x10000000:  # e.g. 0x1000007E is the same crash as 0x7E
        code &= 0xFFFFFF
    name, cause, level = BUGCHECKS.get(code, ("unknown", "unknown", NOTE))
    return code, name, cause, level


def section_history(rep, days):
    rep.section(f"8. CRASH & HARDWARE ERROR HISTORY (last {days} days)", "Error history")
    data = ps_json(PS_HISTORY.replace("__DAYS__", str(days)))
    if data is None:
        rep.flag(YELLOW, "Could not read the Windows event log.")
        return None
    events = as_list(data.get("Events"))
    dumps = as_list(data.get("Dumps"))

    def when(e):
        return dt.datetime.strptime(e["Time"], "%Y-%m-%d %H:%M")

    def of(provider, ids=None):
        return [e for e in events if e.get("Provider") == provider and (ids is None or e.get("Id") in ids)]

    # Blue screens: BugCheck 1001 events, plus Kernel-Power 41 with a bugcheck code
    # that has no matching 1001 event (both are logged for the same crash).
    bsods = [e for e in of("Microsoft-Windows-WER-SystemErrorReporting", [1001]) if e.get("Code")]
    power = of("Microsoft-Windows-Kernel-Power", [41])
    for e in power:
        if e.get("Code") and not any(abs((when(e) - when(b)).total_seconds()) < 900 for b in bsods):
            bsods.append(e)
    unexpected = [e for e in power if not e.get("Code") and not e.get("Button")]
    forced = [e for e in power if not e.get("Code") and e.get("Button")]
    whea = of("Microsoft-Windows-WHEA-Logger")
    disk = of("disk")
    memdiag = of("Microsoft-Windows-MemoryDiagnostics-Results")
    cleared = of("Microsoft-Windows-Eventlog", [104])

    oldest = data.get("Oldest")
    if oldest:
        covered = (dt.datetime.now() - dt.datetime.strptime(oldest, "%Y-%m-%d")).days
        rep.kv("Event log goes back to", f"{oldest} ({covered} days)")
        if covered < 30:
            rep.flag(NOTE, f"The event log only goes back {covered} days - older problems are not visible.")

    rep.kv("Blue screens (BSOD)", len(bsods))
    groups = {}
    for e in sorted(bsods, key=when):
        groups.setdefault(bugcheck_info(e["Code"])[0], []).append(e["Time"][:10])
    for code, dates in groups.items():
        _, name, cause, level = bugcheck_info(code)
        rep.line(f"    - 0x{code:X} {name} x{len(dates)} (last {dates[-1]}) -> likely cause: {cause}")
        if level == RED:
            rep.flag(RED, f"Blue screen 0x{code:X} {name} x{len(dates)} - points to a {cause} problem.")
        elif level == YELLOW or len(dates) >= 3:
            rep.flag(YELLOW, f"Blue screen 0x{code:X} {name} x{len(dates)} - possible {cause} problem.")
        else:
            rep.flag(NOTE, f"Blue screen 0x{code:X} {name} x{len(dates)} - usually a {cause} issue.")

    rep.kv("Unexpected shutdowns", f"{len(unexpected)}  (+{len(forced)} forced off with the power button)")
    if len(unexpected) >= 3:
        rep.flag(YELLOW, f"{len(unexpected)} unexpected shutdowns - possible overheating, power or battery problem.")
    elif unexpected:
        rep.flag(NOTE, f"{len(unexpected)} unexpected shutdown(s) - can also be a dead battery or a power cut.")
    if len(forced) >= 3:
        rep.flag(NOTE, f"Forced off with the power button {len(forced)} times - the laptop may freeze.")

    rep.kv("Hardware errors (WHEA)", len(whea))
    by_id = {}
    for e in whea:
        by_id.setdefault((e.get("Id"), e.get("Level")), []).append(e["Time"][:10])
    for (eid, level), dates in sorted(by_id.items(), key=lambda x: str(x[0])):
        kind = WHEA_KINDS.get(eid, f"hardware error (event {eid})")
        fatal = level in (1, 2)
        rep.line(f"    - {kind}{' (FATAL)' if fatal else ''} x{len(dates)} (last {max(dates)})")
        if fatal:
            rep.flag(RED, f"Fatal hardware error logged x{len(dates)}: {kind}.")
        elif eid in (19, 47):
            rep.flag(YELLOW, f"{kind} x{len(dates)} - the CPU/RAM reported errors it had to correct.")
        else:
            rep.flag(NOTE, f"{kind} x{len(dates)} - often harmless, but worth noting.")

    rep.kv("Disk errors in log", len(disk))
    for eid, (label, level) in DISK_EVENTS.items():
        hits = [e for e in disk if e.get("Id") == eid]
        if hits:
            rep.line(f"    - {label} x{len(hits)} (last {max(e['Time'][:10] for e in hits)})")
            rep.flag(level, f"Event log shows '{label}' x{len(hits)}.")

    if memdiag:
        last = max(memdiag, key=when)
        failed = [e for e in memdiag if (e.get("Level") or 4) <= 3]
        rep.kv("Windows Memory Diagnostic", f"run {len(memdiag)} time(s), last {last['Time'][:10]}"
               + (f" - ERRORS FOUND {len(failed)} time(s)" if failed else " - no errors"))
        if failed:
            rep.flag(RED, "Windows Memory Diagnostic found RAM errors in the past.")
    else:
        rep.kv("Windows Memory Diagnostic", "never run in this period")

    rep.kv("Crash dump files", f"{len(dumps)} (latest {dumps[0]})" if dumps else "none")
    if dumps and not bsods:
        rep.flag(NOTE, f"{len(dumps)} crash dump file(s) exist (latest {dumps[0]}) - there were blue screens "
                       "earlier than the event log shows.")

    if cleared:
        dates = ", ".join(sorted({e["Time"][:10] for e in cleared}))
        rep.kv("Event log cleared", dates)
        rep.flag(YELLOW, f"The System event log was cleared ({dates}) - earlier history is gone. "
                         "Can be innocent (cleanup tools), but ask why.")

    if not (bsods or unexpected or whea or disk or cleared):
        rep.ok("No crashes or hardware errors logged.")
    return f"{len(bsods)} BSOD, {len(whea)} hardware errors, {len(unexpected)} unexpected shutdowns"


# --------------------------------------------------------------------------
# Quick RAM test
# --------------------------------------------------------------------------

MEMTEST_CHUNK = 64 * 1024 * 1024
MEMTEST_BLOCK = 4096


def memory_status():
    class MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong)] + [
            (n, ctypes.c_ulonglong) for n in ("ullTotalPhys", "ullAvailPhys", "ullTotalPageFile",
                                              "ullAvailPageFile", "ullTotalVirtual", "ullAvailVirtual",
                                              "ullAvailExtendedVirtual")]
    st = MEMORYSTATUSEX()
    st.dwLength = ctypes.sizeof(st)
    if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
        return None, None
    return st.ullTotalPhys, st.ullAvailPhys


def section_memtest(rep, budget):
    rep.section("9. QUICK MEMORY (RAM) TEST", "Memory test")
    total, avail = memory_status()
    if not avail:
        rep.flag(YELLOW, "Could not read free memory - RAM test skipped.")
        return None
    # Use 60% of the free RAM (max 8 GB) so Windows and open apps keep running normally.
    target = min(int(avail * 0.6), 8 * 1024 ** 3)
    chunks = []
    try:
        while (len(chunks) + 1) * MEMTEST_CHUNK <= target:
            chunks.append(bytearray(MEMTEST_CHUNK))
    except MemoryError:
        if chunks:
            chunks.pop()
    if not chunks:
        rep.flag(YELLOW, "Not enough free memory for the RAM test.")
        return None
    tested = len(chunks) * MEMTEST_CHUNK
    rep.kv("Memory tested", f"{size_str(tested, True)} of {size_str(total, True)} "
                            f"({tested / total * 100:.0f}% - the part that was free)")
    rep.line(f"  Writing and verifying patterns for about {budget} s...")

    rnd = os.urandom(MEMTEST_CHUNK)
    patterns = [("zeros", 0x00), ("ones", 0xFF), ("0x55", 0x55), ("0xAA", 0xAA), ("random", None)]
    bad_blocks, passes, start = 0, 0, time.time()
    finished = False
    while not finished:
        for name, value in patterns:
            passes += 1
            fixed = bytes([value]) * MEMTEST_CHUNK if value is not None else None

            def expected(i, p=passes, fixed=fixed):
                if fixed is not None:
                    return fixed
                k = (i * 4099 + p * 131) % MEMTEST_CHUNK  # different data in every chunk and pass
                return rnd[k:] + rnd[:k]

            t0 = time.time()
            # Write everything first, then verify, so a write that corrupts
            # another address is caught too.
            for i, chunk in enumerate(chunks):
                chunk[:] = expected(i)
            errors = 0
            for i, chunk in enumerate(chunks):
                ref = expected(i)
                if chunk != ref:
                    errors += sum(1 for o in range(0, MEMTEST_CHUNK, MEMTEST_BLOCK)
                                  if chunk[o:o + MEMTEST_BLOCK] != ref[o:o + MEMTEST_BLOCK])
            bad_blocks += errors
            rep.line(f"    pass {passes} ({name}): "
                     f"{'OK' if not errors else f'{errors} corrupted 4 KB blocks'}  [{time.time() - t0:.1f} s]")
            if passes >= len(patterns) and time.time() - start >= budget:
                finished = True
                break
    del chunks

    if bad_blocks:
        rep.flag(RED, f"RAM test found {bad_blocks} corrupted 4 KB blocks - faulty memory. "
                      "Confirm with MemTest86 before buying.")
    else:
        rep.ok(f"No errors in {size_str(tested, True)} over {passes} passes.")
    rep.line("  -> Quick test of the free memory only. A full test: MemTest86 from a USB stick")
    rep.line("     (1+ hour) or Windows Memory Diagnostic (mdsched.exe, needs a restart).")
    return ("ERRORS FOUND" if bad_blocks else "OK") + f" ({size_str(tested, True)} tested, {passes} passes)"


# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------

MANUAL_CHECKS = [
    "Screen: open a full-screen white, black, red, green and blue image - look for dead pixels,",
    "  bright spots and backlight bleed. Tilt the lid - no flicker or lines.",
    "Keyboard & touchpad: type every key (e.g. keyboard-test website / Notepad), test clicks.",
    "Ports: try every USB port, HDMI, headphone jack, SD reader; charge via USB-C if supported.",
    "Webcam, microphone and speakers (Camera app, Voice Recorder, a YouTube video).",
    "Wi-Fi and Bluetooth connect; hinges are firm; no cracks, swollen battery (lifted touchpad/case).",
    "Charger: original wattage; unplug and replug - Windows should switch to charging.",
    "BIOS: reboot and enter BIOS setup (F2/Del/F1/Esc) - it must NOT ask for a password.",
    "Ask the seller to remove their Microsoft account / reset Windows in front of you.",
]


def section_summary(rep, facts):
    rep.section("SUMMARY", "Summary")
    for k, v in facts:
        rep.kv(k, v)
    reds = [f for f in rep.flags if f[0] == RED]
    yellows = [f for f in rep.flags if f[0] == YELLOW]
    notes = [f for f in rep.flags if f[0] == NOTE]
    rep.line()
    if reds:
        rep.line(f"  RED FLAGS ({len(reds)}):", RED)
        for _, sec, msg in reds:
            rep.line(f"   ! [{sec}] {msg}", RED)
    else:
        rep.line("  No red flags found.", OK)
    if yellows:
        rep.line(f"  WARNINGS ({len(yellows)}):", YELLOW)
        for _, sec, msg in yellows:
            rep.line(f"   - [{sec}] {msg}", YELLOW)
    if notes:
        rep.line(f"  NOTES ({len(notes)}):", NOTE)
        for _, sec, msg in notes:
            rep.line(f"   * [{sec}] {msg}", NOTE)
    rep.line()
    if reds:
        rep.line("  VERDICT: serious problems found - negotiate the price down or walk away.", RED)
    elif yellows:
        rep.line("  VERDICT: usable, but take the warnings into account in the price.", YELLOW)
    else:
        rep.line("  VERDICT: hardware looks healthy. Finish the manual checks below.", OK)
    rep.line()
    rep.line("  MANUAL CHECKS (the script cannot test these):")
    for item in MANUAL_CHECKS:
        rep.line(("      " if item.startswith("  ") else "  [ ] ") + item.strip())


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Inspect a used Windows laptop before buying it.")
    ap.add_argument("--seconds", type=int, default=30, help="stress test length (default 30)")
    ap.add_argument("--skip-stress", action="store_true", help="skip the CPU stress test")
    ap.add_argument("--skip-memtest", action="store_true", help="skip the quick RAM test")
    ap.add_argument("--memtest-seconds", type=int, default=45, help="RAM test length (default 45)")
    ap.add_argument("--history-days", type=int, default=90, help="days of error history to read (default 90)")
    ap.add_argument("--no-admin", action="store_true", help="do not ask for administrator rights")
    ap.add_argument("--no-pause", action="store_true", help="do not wait for Enter at the end")
    ap.add_argument("--elevated", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()

    if not IS_WINDOWS:
        print("This script only runs on Windows 10/11.")
        return 1

    admin = is_admin()
    if not admin and not args.no_admin and not args.elevated:
        passthrough = [a for a in sys.argv[1:] if a != "--elevated"]
        print("Requesting administrator rights (needed for disk SMART data and temperatures)...")
        if relaunch_as_admin(passthrough):
            print("The check continues in the new window.")
            return 0
        print("Administrator rights were not granted - continuing with limited data.\n")

    os.system("")  # enables ANSI colours in the Windows console
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    rep = Report(use_color=sys.stdout.isatty())
    rep.line("USED LAPTOP INSPECTION REPORT", "HEAD")
    rep.line("Collecting data - this takes about 3 minutes...")

    outdir = output_dir()
    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M")
    facts = []

    def safe(fn, *a):
        try:
            return fn(*a)
        except Exception as e:  # keep going if one section fails
            rep.flag(YELLOW, f"Section failed: {type(e).__name__}: {e}")
            return None

    system = safe(section_system, rep, admin) or {}
    cpu = safe(section_cpu, rep) or {}
    ram = safe(section_ram, rep) or {}
    disks = safe(section_disks, rep, admin) or []
    battery = safe(section_battery, rep, outdir, stamp)
    win = safe(section_windows, rep, system) or ({}, None)
    stress = None
    if not args.skip_stress:
        stress = safe(section_stress, rep, max(5, args.seconds), cpu)
    safe(section_uptime, rep, win[0])
    history = safe(section_history, rep, max(1, args.history_days))
    memtest = None
    if not args.skip_memtest:
        memtest = safe(section_memtest, rep, max(5, args.memtest_seconds))

    facts.append(("Model", f"{clean(system.get('Manufacturer'))} {clean(system.get('Model'))}".strip() or "n/a"))
    facts.append(("CPU", f"{clean(cpu.get('Name'))} ({cpu.get('NumberOfCores')}C/"
                         f"{cpu.get('NumberOfLogicalProcessors')}T)" if cpu else "n/a"))
    facts.append(("RAM", f"{size_str(ram.get('total'), True)} {'/'.join(ram.get('types', []))}" if ram else "n/a"))
    facts.append(("Storage", ", ".join(disks) or "n/a"))
    facts.append(("Battery health", battery[1] if battery else "n/a"))
    facts.append(("Windows", f"{clean(win[0].get('Caption'))} - "
                             f"{'activated' if win[1] else 'NOT activated' if win[1] is False else 'activation unknown'}"))
    if stress:
        if stress["peak"] is not None:
            facts.append(("Peak CPU temperature", f"{stress['peak']:.0f} C"))
        facts.append(("CPU calculations", stress["calc"]))
    if history:
        facts.append((f"Last {args.history_days} days", history))
    if memtest:
        facts.append(("RAM test", memtest))
    safe(section_summary, rep, facts)

    name = clean(system.get("ComputerName")) or "laptop"
    path = os.path.join(outdir, f"laptop_report_{name}_{stamp}.txt")
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(rep.lines) + "\n")
        print(f"\nReport saved to: {path}")
    except OSError as e:
        print(f"\nCould not save report: {e}")

    if not args.no_pause:
        try:
            input("\nPress Enter to exit...")
        except EOFError:
            pass
    return 0


if __name__ == "__main__":
    multiprocessing.freeze_support()
    sys.exit(main())
