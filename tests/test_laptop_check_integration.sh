#!/usr/bin/env bash
#
# tests/test_laptop_check_integration.sh - end-to-end test for laptop_check.sh.
#
# Runs the whole script against a fake powershell.exe / powercfg / dsregcmd so
# the Windows data collection is simulated. This verifies that the parsing,
# the flag logic, the report and the saved text file all work together.

set -u
export LC_ALL=C

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/laptop_check.sh"

PASS=0
FAIL=0

check_contains() { # description haystack needle
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf 'FAIL: %s\n  expected to contain: [%s]\n' "$desc" "$needle"
            ;;
    esac
}

check_absent() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*)
            FAIL=$((FAIL + 1))
            printf 'FAIL: %s\n  expected NOT to contain: [%s]\n' "$desc" "$needle"
            ;;
        *) PASS=$((PASS + 1)) ;;
    esac
}

check_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual"
    fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/laptop_it.XXXXXX")
trap 'if [ -z "${KEEP_WORK:-}" ]; then rm -rf "$WORK"; else echo "WORK_DIR=$WORK" >&2; fi' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"
cp "$SCRIPT" "$WORK/laptop_check.sh"
chmod +x "$WORK/laptop_check.sh"

# --------------------------------------------------------------- fake tools

cat > "$BIN/powershell.exe" <<'STUB'
#!/usr/bin/env bash
# Fake powershell.exe: decode the -EncodedCommand and answer with canned data.
enc=""
command=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-EncodedCommand" ]; then enc="$a"; fi
    if [ "$prev" = "-Command" ]; then command="$a"; fi
    prev="$a"
done
if [ -z "$enc" ]; then
    case "$command" in
        *IsInRole*) printf 'False\n' ;;
    esac
    exit 0
fi
script=$(printf '%s' "$enc" | base64 -d 2>/dev/null | iconv -f UTF-16LE -t UTF-8 2>/dev/null)
case "$script" in
    *Win32_BIOS*)
        printf '%s\n' \
            $'Manufacturer\tACME' \
            $'Model\tLaptop 3000' \
            $'ProductVersion\tRev 2' \
            $'Serial\tSN-123456' \
            $'BiosVersion\t1.2.3' \
            $'BiosDate\t2020-05-01' \
            $'PartOfDomain\tFalse' \
            $'Domain\tWORKGROUP' \
            $'ComputerName\tTESTLAPTOP'
        ;;
    *Win32_Processor*)
        printf 'CPU|Test(R) Core(TM) i5|4|8|2000\n'
        ;;
    *Win32_PhysicalMemory*)
        printf '%s\n' \
            'MOD|8589934592|3200|2666|26|Samsung|M471A1K43|DIMM 0|x' \
            'ARR|2|x' \
            'VISIBLE|8000000000|x'
        ;;
    *Get-PhysicalDisk*)
        printf '%s\n' \
            'DISK|0|Test NVMe SSD|512110190592|SSD|NVMe|Healthy|OK|C:|5|120|40|0|0|x' \
            'DISK|1|Old Mechanical|500107862016|HDD|SATA|Healthy|OK|D:|70|30000|50|0|0|x' \
            'PRED|\\\\.\\PHYSICALDRIVE1|x'
        ;;
    *batteryreport*)
        printf '%s\n' \
            'BAT|ACME|BAT-001|LiP|2020-05-01|50000|30000|900|x' \
            'W32|ACME Battery|85|2|11400|x'
        ;;
    *SoftwareLicensingProduct*)
        printf '%s\n' \
            'W|caption|Microsoft Windows 11 Pro|x' \
            'W|displayversion|23H2|x' \
            'W|build|22631|x' \
            'W|ubr|3155|x' \
            'W|arch|64-bit|x' \
            'W|installdate|2023-01-01|x' \
            'W|installdays|300|x' \
            'W|lastboot|2024-01-01 10:00:00|x' \
            'W|uptimesec|7200|x' \
            'W|faststartup|0|x' \
            'W|hasoemkey|True|x' \
            'W|oemdesc|Windows OEM key|x' \
            'W|autopilot|contoso.onmicrosoft.com|x' \
            'LIC|1|KMS|Windows 11 Pro (KMS)|x' \
            'MDM|user@contoso.com|x'
        ;;
    *Get-WinEvent*)
        printf '%s\n' \
            'EV|2024-01-01 10:00|Microsoft-Windows-WER-SystemErrorReporting|1001|2|26|False|x' \
            'EV|2024-01-02 10:00|Microsoft-Windows-Kernel-Power|41|4||False|x' \
            'EV|2024-01-03 10:00|Microsoft-Windows-WHEA-Logger|19|3||False|x' \
            'OLDEST|2024-01-01|x' \
            'DUMP|2024-01-01|x'
        ;;
    *LaptopMemTest*)
        printf '%s\n' \
            'PASS|1|zeros|0|0.1' \
            'PASS|2|ones|0|0.1' \
            'PASS|3|0x55|0|0.1' \
            'PASS|4|0xAA|0|0.1' \
            'PASS|5|random|0|0.1' \
            'MT|8589934592|1073741824|5|0'
        ;;
    *ThermalZoneTemperature*)
        printf 'S|50|100|2000|55|x\n'
        ;;
    *)
        exit 0
        ;;
esac
STUB
chmod +x "$BIN/powershell.exe"

cat > "$BIN/dsregcmd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
    'AzureAdJoined : NO' \
    'EnterpriseJoined : NO' \
    'DomainJoined : NO'
STUB
chmod +x "$BIN/dsregcmd"

cat > "$BIN/powercfg" <<'STUB'
#!/usr/bin/env bash
# Emulate "powercfg /batteryreport /output <file>" by creating the file.
out=""
prev=""
for a in "$@"; do
    if [ "$prev" = "/output" ]; then out="$a"; fi
    prev="$a"
done
[ -n "$out" ] && : > "$out"
exit 0
STUB
chmod +x "$BIN/powercfg"

# --------------------------------------------------------------- run

PATH="$BIN:$PATH"
export PATH

out=$(bash "$WORK/laptop_check.sh" --no-admin --no-pause --seconds 5 --memtest-seconds 5 --history-days 90 2>&1)
rc=$?
check_eq "script exits 0" 0 "$rc"

report=$(ls "$WORK"/laptop_report_*.txt 2>/dev/null | head -1)
if [ -z "$report" ]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL: report file was not created\n'
    printf '%s\n' "$out"
else
    PASS=$((PASS + 1))
fi
content="$out"
[ -n "${report:-}" ] && content="$content"$'\n'"$(cat "$report")"

# Sections
check_contains "header" "$content" "USED LAPTOP INSPECTION REPORT"
check_contains "system section" "$content" "0. SYSTEM"
check_contains "cpu section" "$content" "1. CPU"
check_contains "ram section" "$content" "2. MEMORY (RAM)"
check_contains "storage section" "$content" "3. STORAGE"
check_contains "battery section" "$content" "4. BATTERY"
check_contains "windows section" "$content" "5. WINDOWS"
check_contains "stress section" "$content" "CPU STRESS TEST (5 s)"
check_contains "uptime section" "$content" "7. UPTIME"
check_contains "history section" "$content" "8. CRASH & HARDWARE ERROR HISTORY"
check_contains "memtest section" "$content" "9. QUICK MEMORY (RAM) TEST"
check_contains "summary section" "$content" "SUMMARY"

# Values parsed from the fake data
check_contains "system model" "$content" "ACME Laptop 3000 (Rev 2)"
check_contains "cpu model" "$content" "Test(R) Core(TM) i5"
check_contains "ram type" "$content" "DDR4"
check_contains "windows edition" "$content" "Microsoft Windows 11 Pro"
check_contains "windows activated" "$content" "Windows is activated."
check_contains "kms warning" "$content" "Activated via KMS"
check_contains "mdm managed" "$content" "enrolled in MDM (e.g. Intune): user@contoso.com"
check_contains "autopilot managed" "$content" "registered in Windows Autopilot to 'contoso.onmicrosoft.com'"
check_contains "org management red flag" "$content" "Laptop is managed by an organisation"
check_contains "uptime" "$content" "2 h 0 min"
check_contains "memtest result" "$content" "No errors in"

# Flags decided by the bash logic
check_contains "single module note" "$content" "Single RAM module with a free slot"
check_contains "disk wear warning" "$content" "70% of rated life used"
check_contains "disk hours warning" "$content" "power-on hours"
check_contains "mechanical disk warning" "$content" "mechanical hard drive"
check_contains "smart predict red flag" "$content" "SMART predicts imminent failure"
check_contains "battery health warning" "$content" "Battery health 60%"
check_contains "battery capacity formatted" "$content" "50,000 mWh"
check_contains "battery cycle red flag" "$content" "900 charge cycles"
check_contains "bsod red flag" "$content" "Blue screen 0x1A MEMORY_MANAGEMENT"
check_contains "whea warning" "$content" "corrected CPU error"
check_contains "unexpected shutdown note" "$content" "unexpected shutdown"
check_contains "averaged cpu load note" "$content" "CPU load only reached"
check_contains "vedict red" "$content" "serious problems found"
check_absent "no activation red flag" "$content" "Windows is NOT activated."

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
