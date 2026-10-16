#!/usr/bin/env bash
#
# laptop_check.sh - inspect a used Linux laptop before buying it.
#
# Bash port of laptop_check.py for Linux. It checks the CPU, RAM, storage
# (health / SMART), battery wear, the operating system, runs a short CPU stress
# test that verifies every calculation and measures temperatures, reports uptime,
# reads the kernel error history and runs a quick RAM test.
# It prints a readable report with red flags and saves it to a text file.
#
# Everything comes from files and tools that are normally already present:
# /proc, /sys, lsblk, smartctl (optional), dmesg / journalctl (optional).
#
# Usage:
#   ./laptop_check.sh                  full check, 30 s stress test
#   ./laptop_check.sh --seconds 60     longer stress test
#   ./laptop_check.sh --skip-stress    no stress test
#   ./laptop_check.sh --skip-memtest   no RAM test
#
# The CPU stress test and the RAM test deliberately use the whole machine for a
# while. Do not run them on a machine you cannot afford to load.

set -u

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
# These can be overridden so the helper functions can be tested against
# synthetic trees (see tests/test_laptop_check.sh).
SYSFS_ROOT="${SYSFS_ROOT:-/sys}"
PROC_ROOT="${PROC_ROOT:-/proc}"

RED="RED"
YELLOW="YELLOW"
NOTE="NOTE"
OK="OK"
HEAD="HEAD"

RULE="$(printf '=%.0s' $(seq 1 72))"
RULE="${RULE:-========================================================================}"

USE_COLOR=0
SECTION_NAME=""
declare -a REPORT_LINES=()
declare -a FLAGS=()

# Inner arithmetic iterations per verified work unit. Each unit is a tight,
# deterministic calculation whose answer is known before the load starts.
WORK_ROUNDS="${WORK_ROUNDS:-200000}"

# Command-line options (defaults).
STRESS_SECONDS=30
SKIP_STRESS=0
SKIP_MEMTEST=0
MEMTEST_SECONDS=45
HISTORY_DAYS=90
NO_PAUSE=0

# Filled in by the sections (initialised so `set -u` never trips).
CPU_THREADS=""
CPU_BASE_MHZ=""
CPU_MODEL_TEXT=""
SYSTEM_VENDOR=""
SYSTEM_MODEL=""
SYSTEM_HOST=""
RAM_TOTAL_BYTES=0
STORAGE_SUMMARY="n/a"
BATTERY_SUMMARY="n/a"
OS_SUMMARY="n/a"
STRESS_SUMMARY="n/a"
HISTORY_SUMMARY="n/a"
MEMTEST_SUMMARY="n/a"

# --------------------------------------------------------------------------
# Report output
# --------------------------------------------------------------------------
_paint() {
    local text="$1" style="${2:-}"
    if (( USE_COLOR )) && [[ -n "$style" ]]; then
        case "$style" in
            "$RED")    printf '\033[91m%s\033[0m' "$text" ;;
            "$YELLOW") printf '\033[93m%s\033[0m' "$text" ;;
            "$NOTE")   printf '\033[96m%s\033[0m' "$text" ;;
            "$OK")     printf '\033[92m%s\033[0m' "$text" ;;
            "$HEAD")   printf '\033[1m%s\033[0m' "$text" ;;
            *)         printf '%s' "$text" ;;
        esac
    else
        printf '%s' "$text"
    fi
}

reset_report() {
    SECTION_NAME=""
    REPORT_LINES=()
    FLAGS=()
}

report_line() {
    local text="${1:-}" style="${2:-}"
    _paint "$text" "$style"
    printf '\n'
    REPORT_LINES+=("$text")
}

report_section() {
    local title="$1" short="$2"
    SECTION_NAME="$short"
    report_line ""
    report_line "$RULE" "$HEAD"
    report_line " $title" "$HEAD"
    report_line "$RULE" "$HEAD"
}

report_kv() {
    local key="$1" value="$2"
    report_line "$(printf '  %-34s%s' "$key:" "$value")"
}

report_flag() {
    local level="$1" message="$2"
    FLAGS+=("$level|$SECTION_NAME|$message")
    report_line "  [$level] $message" "$level"
}

report_ok() {
    report_line "  [OK] $1" "$OK"
}

count_flags() {
    local level="$1" n=0 f
    for f in ${FLAGS[@]+"${FLAGS[@]}"}; do
        [[ "${f%%|*}" == "$level" ]] && n=$((n + 1))
    done
    printf '%s' "$n"
}

report_summary() {
    report_section "SUMMARY" "Summary"
    while (( $# >= 2 )); do
        report_kv "$1" "$2"
        shift 2
    done

    local reds yellows notes f level rest sec msg
    reds="$(count_flags "$RED")"
    yellows="$(count_flags "$YELLOW")"
    notes="$(count_flags "$NOTE")"

    report_line ""
    if (( reds > 0 )); then
        report_line "  RED FLAGS ($reds):" "$RED"
        for f in ${FLAGS[@]+"${FLAGS[@]}"}; do
            level="${f%%|*}"; rest="${f#*|}"; sec="${rest%%|*}"; msg="${rest#*|}"
            [[ "$level" == "$RED" ]] && report_line "   ! [$sec] $msg" "$RED"
        done
    else
        report_line "  No red flags found." "$OK"
    fi
    if (( yellows > 0 )); then
        report_line "  WARNINGS ($yellows):" "$YELLOW"
        for f in ${FLAGS[@]+"${FLAGS[@]}"}; do
            level="${f%%|*}"; rest="${f#*|}"; sec="${rest%%|*}"; msg="${rest#*|}"
            [[ "$level" == "$YELLOW" ]] && report_line "   - [$sec] $msg" "$YELLOW"
        done
    fi
    if (( notes > 0 )); then
        report_line "  NOTES ($notes):" "$NOTE"
        for f in ${FLAGS[@]+"${FLAGS[@]}"}; do
            level="${f%%|*}"; rest="${f#*|}"; sec="${rest%%|*}"; msg="${rest#*|}"
            [[ "$level" == "$NOTE" ]] && report_line "   * [$sec] $msg" "$NOTE"
        done
    fi

    report_line ""
    if (( reds > 0 )); then
        report_line "  VERDICT: serious problems found - negotiate the price down or walk away." "$RED"
    elif (( yellows > 0 )); then
        report_line "  VERDICT: usable, but take the warnings into account in the price." "$YELLOW"
    else
        report_line "  VERDICT: hardware looks healthy. Finish the manual checks below." "$OK"
    fi
    report_line ""
    report_line "  MANUAL CHECKS (the script cannot test these):"
    report_line "  [ ] Screen: open a full-screen white, black, red, green and blue image - look for dead"
    report_line "      pixels, bright spots and backlight bleed. Tilt the lid - no flicker or lines."
    report_line "  [ ] Keyboard & touchpad: type every key, test clicks and gestures."
    report_line "  [ ] Ports: try every USB port, HDMI/USB-C dock, headphone jack, SD reader."
    report_line "  [ ] Webcam, microphone and speakers."
    report_line "  [ ] Wi-Fi and Bluetooth connect; hinges are firm; no cracks, swollen battery."
    report_line "  [ ] Charger: original wattage; unplug and replug - charging must work."
    report_line "  [ ] Firmware: reboot and enter setup (F2/Del/F1/Esc) - it must NOT ask for a password."
    report_line "  [ ] Ask the seller to log out of their accounts / reset the machine in front of you."
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
have() {
    command -v "$1" >/dev/null 2>&1
}

clean_str() {
    printf '%s' "${1:-}" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# Human readable size. Mirrors size_str() in laptop_check.py.
human_size() {
    local n="${1:-}" binary="${2:-0}"
    [[ -z "$n" || "$n" == "0" ]] && { printf 'n/a'; return; }
    awk -v n="$n" -v b="$binary" 'BEGIN {
        v = n / (b ? 1073741824 : 1000000000);
        if (v >= 1000) printf "%.2f TB\n", v / 1000;
        else if (v >= 100 || v == int(v)) printf "%.0f GB\n", v;
        else printf "%.1f GB\n", v;
    }'
}

# Uptime style duration. Mirrors duration_str() in laptop_check.py.
duration_str() {
    local secs="${1:-0}"
    secs="${secs%.*}"                       # drop any fractional part
    [[ "$secs" =~ ^-?[0-9]+$ ]] || secs=0
    (( secs < 0 )) && secs=0
    local d=$(( secs / 86400 ))
    local rem=$(( secs % 86400 ))
    local h=$(( rem / 3600 ))
    local m=$(( (rem % 3600) / 60 ))
    local out=""
    if (( d == 1 )); then
        out="1 day"
    elif (( d > 1 )); then
        out="$d days"
    fi
    printf '%s' "${out:+$out }$h h $m min"
}

dmi_field() {
    local f="$SYSFS_ROOT/class/dmi/id/$1"
    [[ -r "$f" ]] && tr -d '\n' < "$f" 2>/dev/null
    return 0
}

lscpu_field() {
    lscpu 2>/dev/null | awk -F: -v k="$1" '
        { key = $1; sub(/[ \t]+$/, "", key)
          if (key == k) { v = $2; sub(/^[ \t]+/, "", v); print v; exit } }'
}

meminfo_kb() {
    local field="$1" v=""
    [[ -r "$PROC_ROOT/meminfo" ]] && \
        v="$(awk -v k="$field" '$1 == k":" { print $2; exit }' "$PROC_ROOT/meminfo" 2>/dev/null)"
    printf '%s' "${v:-0}"
}

# Read the highest CPU-ish temperature (degrees C) from /sys, or empty string.
read_max_temp() {
    local max="" f value celsius
    for f in "$SYSFS_ROOT"/class/thermal/thermal_zone*/temp; do
        [[ -r "$f" ]] || continue
        value="$(cat "$f" 2>/dev/null)" || continue
        [[ "$value" =~ ^-?[0-9]+$ ]] || continue
        celsius=$(( value / 1000 ))
        (( celsius > 5 && celsius < 130 )) || continue
        [[ -z "$max" || $celsius -gt $max ]] && max=$celsius
    done
    for f in "$SYSFS_ROOT"/class/hwmon/hwmon*/temp*_input; do
        [[ -r "$f" ]] || continue
        value="$(cat "$f" 2>/dev/null)" || continue
        [[ "$value" =~ ^-?[0-9]+$ ]] || continue
        celsius=$(( value / 1000 ))
        (( celsius > 5 && celsius < 130 )) || continue
        [[ -z "$max" || $celsius -gt $max ]] && max=$celsius
    done
    printf '%s' "$max"
}

# Classify a kernel log line as RED / YELLOW / NOTE (or empty when benign).
kernel_error_level() {
    local l="${1:-}"
    l="${l,,}"
    case "$l" in
        *"machine check"*|*"hardware error"*|*"mce:"*|*"uncorrected error"*|\
        *"ext4-fs error"*|*"xfs ("*"error"*|*"kernel panic"*|*"kernel bug"*|*"bug:"*)
            printf '%s' "$RED"; return ;;
    esac
    case "$l" in
        *"corrected error"*|*"throttl"*|*"failed command"*|*"i/o error"*|\
        *"ata"*"error"*|*"nvme"*"error"*|*"hung task"*)
            printf '%s' "$YELLOW"; return ;;
    esac
    case "$l" in
        *"out of memory"*|*"oom-kill"*|*"oom_reaper"*)
            printf '%s' "$NOTE"; return ;;
    esac
    printf ''
}

# A deterministic calculation with a known answer. Bash arithmetic is 64-bit;
# the multiply/add stays well below 2^63 and the mask keeps it bounded.
verify_arithmetic() {
    local x=1 i
    for (( i = 0; i < WORK_ROUNDS; i++ )); do
        x=$(( (x * 1103515245 + 12345) & 0x7fffffff ))
    done
    printf '%s' "$x"
}

# --------------------------------------------------------------------------
# Data collection sections
# --------------------------------------------------------------------------
section_system() {
    report_section "0. SYSTEM" "System"
    SYSTEM_VENDOR="$(dmi_field sys_vendor)"
    SYSTEM_MODEL="$(dmi_field product_name)"
    local version serial bios bdate
    version="$(dmi_field product_version)"
    serial="$(dmi_field product_serial)"
    bios="$(dmi_field bios_version)"
    bdate="$(dmi_field bios_date)"
    SYSTEM_HOST="$(cat "$PROC_ROOT/sys/kernel/hostname" 2>/dev/null || true)"
    [[ -z "$SYSTEM_HOST" ]] && SYSTEM_HOST="$(hostname 2>/dev/null || true)"

    local model="$SYSTEM_MODEL"
    if [[ -n "$version" && "${version,,}" != "none" && "$model" != *"$version"* ]]; then
        model="$model ($version)"
    fi
    report_kv "Manufacturer / model" "$(clean_str "$SYSTEM_VENDOR $model")"
    local serial_clean
    serial_clean="$(clean_str "$serial")"
    report_kv "Serial number" "${serial_clean:-n/a}"
    report_kv "BIOS / firmware" "$(clean_str "$bios")  (${bdate:-date n/a})"
    report_kv "Hostname" "${SYSTEM_HOST:-n/a}"
    report_kv "Report time" "$(date '+%Y-%m-%d %H:%M')"
    if (( EUID == 0 )); then
        report_kv "Running as root" "yes"
    else
        report_kv "Running as root" "no (some data will be missing)"
    fi
    report_line "  -> Compare model and serial with the sticker under the laptop and the ad."
}

section_cpu() {
    report_section "1. CPU" "CPU"
    local model="" cores="" threads="" max_mhz="" base_mhz=""

    if have lscpu; then
        model="$(lscpu_field 'Model name')"
        local sockets cores_per_socket
        sockets="$(lscpu_field 'Socket(s)')"
        cores_per_socket="$(lscpu_field 'Core(s) per socket')"
        threads="$(lscpu_field 'CPU(s)')"
        max_mhz="$(lscpu_field 'CPU max MHz')"
        if [[ "$sockets" =~ ^[0-9]+$ && "$cores_per_socket" =~ ^[0-9]+$ ]]; then
            cores=$(( sockets * cores_per_socket ))
        elif [[ "$cores_per_socket" =~ ^[0-9]+$ ]]; then
            cores="$cores_per_socket"
        fi
    fi

    # Fall back to /proc/cpuinfo when lscpu is unavailable.
    if [[ -z "$model" && -r "$PROC_ROOT/cpuinfo" ]]; then
        model="$(awk -F: '/model name/{sub(/^[ \t]+/, "", $2); print $2; exit}' "$PROC_ROOT/cpuinfo")"
        threads="$(grep -c '^processor' "$PROC_ROOT/cpuinfo" 2>/dev/null || true)"
        cores="$(awk -F: '/^cpu cores/{gsub(/[ \t]/, "", $2); print $2; exit}' "$PROC_ROOT/cpuinfo")"
    fi
    [[ -z "$threads" ]] && threads="$(nproc 2>/dev/null || echo 1)"

    # Base clock: prefer the "@ x.xxGHz" in the model name, else the max MHz.
    if [[ "$model" =~ @[[:space:]]*([0-9]+\.[0-9]+)[[:space:]]*GHz ]]; then
        base_mhz="$(awk -v g="${BASH_REMATCH[1]}" 'BEGIN { printf "%.0f", g * 1000 }')"
    elif [[ "$max_mhz" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        base_mhz="$(awk -v m="$max_mhz" 'BEGIN { printf "%.0f", m }')"
    fi

    if [[ -z "$model" ]]; then
        report_flag "$YELLOW" "Could not read CPU information."
        CPU_THREADS="$threads"
        CPU_BASE_MHZ="$base_mhz"
        return
    fi
    report_kv "Model" "$(clean_str "$model")"
    report_kv "Physical cores" "${cores:-n/a}"
    report_kv "Logical processors (threads)" "$threads"
    report_kv "Base clock" "${base_mhz:+$base_mhz MHz}"
    report_line "  -> Make sure the CPU model matches exactly what the seller advertised."
    CPU_THREADS="$threads"
    CPU_BASE_MHZ="$base_mhz"
    CPU_MODEL_TEXT="$(clean_str "$model")"
}

section_ram() {
    report_section "2. MEMORY (RAM)" "RAM"
    local total_kb total_bytes
    total_kb="$(meminfo_kb MemTotal)"
    total_bytes=$(( total_kb * 1024 ))
    report_kv "Total installed" "$(human_size "$total_bytes" 1)"

    # Module details need root (dmidecode). Skip quietly when unavailable.
    local dmi="" modules=0 types=""
    if have dmidecode; then
        dmi="$(dmidecode -t memory 2>/dev/null)" || dmi=""
    fi
    if [[ -n "$dmi" ]]; then
        modules="$(awk '/^[[:space:]]*Size:/ { if ($2 != "No" && $2 != "0" && $2 != "Unknown") c++ } END { print c+0 }' <<<"$dmi")"
        types="$(awk -F: '/^[[:space:]]*Type:/ { gsub(/[ \t]/, "", $2); if ($2 != "" && $2 != "Unknown" && $2 != "Other") print $2 }' <<<"$dmi" | sort -u | paste -sd, -)"
        if (( modules > 0 )); then
            report_kv "Modules detected" "$modules"
        fi
        [[ -n "$types" ]] && report_kv "Type" "$types"
    else
        report_line "  (Run as root / install dmidecode for module type and speed.)"
    fi
    report_line "  -> Slot counts reported by laptops are not always accurate; soldered RAM"
    report_line "     also appears as a module."

    local gib
    gib="$(awk -v b="$total_bytes" 'BEGIN { printf "%.1f", b / 1073741824 }')"
    if (( total_bytes == 0 )); then
        report_flag "$YELLOW" "Could not read RAM size."
    elif awk -v g="$gib" 'BEGIN { exit !(g < 3.5) }'; then
        report_flag "$RED" "Only ${gib%.*} GB RAM - too little for a modern desktop."
    elif awk -v g="$gib" 'BEGIN { exit !(g < 7.5) }'; then
        report_flag "$YELLOW" "Only ${gib%.*} GB RAM - will feel slow; 8 GB minimum, 16 GB recommended."
    else
        report_ok "${gib%.*} GB RAM."
    fi
    RAM_TOTAL_BYTES="$total_bytes"
}

section_disks() {
    report_section "3. STORAGE" "Storage"
    local summary="" out=""
    if have lsblk; then
        out="$(lsblk -dn -P -o NAME,SIZE,TYPE,ROTA,TRAN,MODEL 2>/dev/null)" || out=""
    fi
    if [[ -z "$out" ]]; then
        report_flag "$YELLOW" "Could not list physical disks (lsblk missing?)."
        STORAGE_SUMMARY="n/a"
        return
    fi

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local NAME="" SIZE="" TYPE="" ROTA="" TRAN="" MODEL=""
        # lsblk -P output is shell-quoted key="value" pairs.
        # shellcheck disable=SC2294
        eval "$line"
        [[ "$TYPE" == "disk" ]] || continue

        local media="SSD" bus="${TRAN^^}"
        [[ "$ROTA" == "1" ]] && media="HDD"
        [[ -z "$bus" ]] && bus="?"
        local model="$MODEL"
        [[ -z "$model" ]] && model="Unknown disk"

        report_line ""
        report_line "  Disk: $model (/dev/$NAME)"
        report_kv "    Capacity" "$(clean_str "$SIZE")"
        report_kv "    Type / interface" "$media / $bus"

        # SMART health, when smartmontools is installed.
        if have smartctl; then
            local smart="" overall=""
            smart="$(smartctl -H -i -A "/dev/$NAME" 2>/dev/null)" || smart=""
            overall="$(awk -F: '/overall-health self-assessment test result/{sub(/^[ \t]+/, "", $2); print $2; exit}' <<<"$smart")"
            if [[ -n "$overall" ]]; then
                report_kv "    SMART overall" "$overall"
                [[ "${overall^^}" != *PASSED* ]] && report_flag "$RED" "$model: SMART self-assessment $overall."
            fi
            local poh used realloc
            poh="$(awk '/Power_On_Hours/{print $NF; exit}' <<<"$smart")"
            used="$(awk -F: '/Percentage Used/{gsub(/[^0-9]/, "", $2); print $2; exit}' <<<"$smart")"
            realloc="$(awk '/Reallocated_Sector_Ct/{print $NF; exit}' <<<"$smart")"
            [[ -n "$poh" ]] && report_kv "    Power-on hours" "$poh"
            [[ -n "$used" ]] && report_kv "    Life used" "$used%"
            [[ -n "$realloc" ]] && report_kv "    Reallocated sectors" "$realloc"
            if [[ "$used" =~ ^[0-9]+$ ]]; then
                if (( used >= 90 )); then
                    report_flag "$RED" "$model: $used% of rated life used - near end of life."
                elif (( used >= 60 )); then
                    report_flag "$YELLOW" "$model: $used% of rated life used."
                fi
            fi
            if [[ "$realloc" =~ ^[0-9]+$ ]] && (( realloc > 0 )); then
                report_flag "$RED" "$model: $realloc reallocated sectors (surface/flash damage)."
            fi
        fi

        if [[ "$ROTA" == "1" && "$bus" != "USB" ]]; then
            report_flag "$YELLOW" "$model is a mechanical hard drive - much slower than an SSD."
        fi
        [[ "$bus" == "USB" ]] && report_flag "$NOTE" "$model is an external USB drive - not part of the laptop."
        [[ "$bus" != "USB" ]] && summary="${summary:+$summary, }$media"
    done <<<"$out"

    if ! have smartctl; then
        report_line ""
        report_line "  (Optional: install smartmontools for SMART health and wear data.)"
    fi
    STORAGE_SUMMARY="${summary:-n/a}"
}

section_battery() {
    report_section "4. BATTERY" "Battery"
    local found=0 dir
    for dir in "$SYSFS_ROOT"/class/power_supply/*; do
        [[ -r "$dir/type" ]] || continue
        [[ "$(cat "$dir/type" 2>/dev/null)" == "Battery" ]] || continue
        found=1
        local name full design unit cycles health
        name="$(cat "$dir/model_name" 2>/dev/null || true)"
        [[ -z "$name" ]] && name="$(cat "$dir/manufacturer" 2>/dev/null || true)"
        full="$(cat "$dir/charge_full" 2>/dev/null || cat "$dir/energy_full" 2>/dev/null || true)"
        design="$(cat "$dir/charge_full_design" 2>/dev/null || cat "$dir/energy_full_design" 2>/dev/null || true)"
        cycles="$(cat "$dir/cycle_count" 2>/dev/null || true)"
        report_line ""
        [[ -n "$name" ]] && report_kv "Battery" "$name"
        if [[ -n "$design" && -n "$full" ]]; then
            unit="mAh"; [[ -r "$dir/energy_full" ]] && unit="mWh"
            health="$(awk -v f="$full" -v d="$design" 'BEGIN { printf "%.0f", f / d * 100 }')"
            local design_h full_h
            design_h="$(awk -v d="$design" 'BEGIN { printf "%.0f", d / 1000 }')"
            full_h="$(awk -v f="$full" 'BEGIN { printf "%.0f", f / 1000 }')"
            report_kv "Original capacity (when new)" "$design_h $unit"
            report_kv "Capacity left (full charge)" "$full_h $unit"
            report_kv "Remaining from original" "$health%"
            if (( health < 60 )); then
                report_flag "$RED" "Battery health $health% - plan on replacing the battery."
            elif (( health < 80 )); then
                report_flag "$YELLOW" "Battery health $health% - noticeably reduced runtime."
            else
                report_ok "Battery health $health%."
            fi
            (( health > 105 )) && report_flag "$NOTE" "Capacity above design value - battery may be new or poorly calibrated."
            BATTERY_SUMMARY="$health% of original"
        else
            report_flag "$YELLOW" "Battery capacity not reported - cannot calculate health."
        fi
        if [[ "$cycles" =~ ^[0-9]+$ && "$cycles" -gt 0 ]]; then
            report_kv "Charge cycles" "$cycles"
            if (( cycles > 800 )); then
                report_flag "$RED" "$cycles charge cycles - battery is near end of life."
            elif (( cycles > 500 )); then
                report_flag "$YELLOW" "$cycles charge cycles - battery is well used."
            fi
        else
            report_kv "Charge cycles" "not reported by the battery"
        fi
    done
    if (( !found )); then
        report_flag "$RED" "No battery detected! (removed, dead, or disconnected)"
        BATTERY_SUMMARY="n/a"
    fi
}

section_os() {
    report_section "5. OPERATING SYSTEM" "OS"
    local pretty="" osver=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        pretty="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}")"
        # shellcheck disable=SC1091
        osver="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}")"
    fi
    report_kv "Distribution" "${pretty:-n/a}${osver:+ ($osver)}"
    report_kv "Kernel" "$(uname -r 2>/dev/null || true)"
    report_kv "Architecture" "$(uname -m 2>/dev/null || true)"

    local domain="" managed=""
    domain="$(dnsdomainname 2>/dev/null || true)"
    # Being on a DNS domain is normal; only real domain-join markers count.
    if have realm; then
        local realmout
        realmout="$(realm list 2>/dev/null)" || realmout=""
        [[ -n "$realmout" ]] && managed="joined to a realm (${realmout%%$'\n'*})"
    fi
    if [[ -r /etc/sssd/sssd.conf ]] && grep -qE '^[[:space:]]*domains[[:space:]]*=' /etc/sssd/sssd.conf 2>/dev/null; then
        managed="${managed:+$managed; }configured with sssd domain authentication"
    fi
    if [[ -r /etc/krb5.keytab ]]; then
        managed="${managed:+$managed; }has a Kerberos machine keytab (joined to a domain)"
    fi
    report_kv "Organisation management" "${managed:-none detected}"
    if [[ -n "$managed" ]]; then
        report_flag "$RED" "Laptop appears to be managed ($managed). It may be company property and can be locked remotely - ask for proof."
    elif [[ -n "$domain" && "$domain" != "localdomain" ]]; then
        report_kv "DNS domain" "$domain (not by itself a sign of management)"
    fi
    OS_SUMMARY="${pretty:-n/a}"
}

section_uptime() {
    report_section "7. UPTIME" "Uptime"
    local up=""
    if [[ -r "$PROC_ROOT/uptime" ]]; then
        read -r up _ < "$PROC_ROOT/uptime"
    fi
    report_kv "Uptime" "$(duration_str "${up:-0}")"
    local btime=""
    if [[ -r "$PROC_ROOT/stat" ]]; then
        btime="$(awk '/^btime/{print $2; exit}' "$PROC_ROOT/stat" 2>/dev/null)"
    fi
    if [[ -n "$btime" ]]; then
        report_kv "Last boot" "$(date -d "@$btime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$btime")"
    fi
}

# --------------------------------------------------------------------------
# CPU stress test with verified calculations and temperatures
# --------------------------------------------------------------------------
cpu_util_and_idle() {
    # Print "total idle jiffies" from /proc/stat.
    [[ -r "$PROC_ROOT/stat" ]] || { printf '0 0'; return; }
    awk '/^cpu / { t = 0; for (i = 2; i <= NF; i++) t += $i; printf "%s %s", t, $5 + $6; exit }' "$PROC_ROOT/stat"
}

read_cpu_mhz() {
    local sum=0 n=0 f v
    for f in "$SYSFS_ROOT"/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        [[ -r "$f" ]] || continue
        v="$(cat "$f" 2>/dev/null)" || continue
        [[ "$v" =~ ^[0-9]+$ ]] || continue
        sum=$(( sum + v / 1000 ))
        n=$(( n + 1 ))
    done
    (( n > 0 )) && printf '%s' "$(( sum / n ))"
    return 0
}

stress_worker() {
    local stop_ms="$1" expected="$2" idx="$3" cdir="$4"
    local rounds=0 errors=0 now
    while :; do
        now="$(date +%s%3N)"
        (( now >= stop_ms )) && break
        if [[ "$(verify_arithmetic)" != "$expected" ]]; then
            errors=$(( errors + 1 ))
        fi
        rounds=$(( rounds + WORK_ROUNDS ))
        printf '%s' "$rounds" > "$cdir/c$idx"
        printf '%s' "$errors" > "$cdir/e$idx"
    done
}

section_stress() {
    local seconds="$1"
    report_section "6. CPU STRESS TEST (${seconds}s) + TEMPERATURES" "Stress test"
    report_line "  Tip: connect the charger and close other programs for a fair result."

    local threads="${CPU_THREADS:-}"
    [[ "$threads" =~ ^[0-9]+$ ]] || threads="$(nproc 2>/dev/null || echo 2)"
    (( threads < 1 )) && threads=1

    # Idle baseline.
    report_line "  Measuring idle state..."
    local idle_temp idle_util idle_stat
    idle_stat="$(cpu_util_and_idle)"
    sleep 3
    idle_temp="$(read_max_temp)"
    idle_util="$(cpu_util_and_idle)"

    local expected
    expected="$(verify_arithmetic)"          # the correct answer, from a cool CPU

    local cdir
    cdir="$(mktemp -d)"
    report_line "  Loading all $threads threads for ${seconds}s, verifying every calculation..."
    local stop_ms
    stop_ms=$(( $(date +%s%3N) + (seconds + 1) * 1000 ))
    local i pids=()
    for (( i = 0; i < threads; i++ )); do
        stress_worker "$stop_ms" "$expected" "$i" "$cdir" &
        pids+=("$!")
    done

    # Sample while the load runs.
    local peak_temp="" start_ms now_ms last_n=0 last_ms rates=()
    start_ms="$(date +%s%3N)"
    last_ms="$start_ms"
    while :; do
        sleep 2
        now_ms="$(date +%s%3N)"
        (( now_ms >= stop_ms )) && break
        local t; t="$(read_max_temp)"
        [[ -n "$t" ]] && { [[ -z "$peak_temp" || $t -gt $peak_temp ]] && peak_temp="$t"; }
        local total=0 c
        for (( i = 0; i < threads; i++ )); do
            c="$(cat "$cdir/c$i" 2>/dev/null || echo 0)"
            total=$(( total + c ))
        done
        local elapsed_s rate
        elapsed_s=$(( now_ms - start_ms ))
        rate="$(awk -v a="$total" -v b="$last_n" -v ms="$(( now_ms - last_ms ))" 'BEGIN { print (b==0?0:(a-b)/(ms/1000.0)) }')"
        rates+=("$rate")
        last_n="$total"
        last_ms="$now_ms"
        report_line "$(printf '    t=%5.1fs  temp %s  %s calc/s' "$(awk -v ms="$elapsed_s" 'BEGIN{print ms/1000.0}')" \
            "$([[ -n "$t" ]] && echo "${t} C" || echo "n/a")" "$(printf '%.0f' "$rate")")"
    done

    # Wait for the workers and collect totals.
    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    local total=0 wrong=0
    for (( i = 0; i < threads; i++ )); do
        total=$(( total + $(cat "$cdir/c$i" 2>/dev/null || echo 0) ))
        wrong=$(( wrong + $(cat "$cdir/e$i" 2>/dev/null || echo 0) ))
    done

    # Cooldown.
    report_line "  Cooling down for 10 s..."
    sleep 8
    local after_temp; after_temp="$(read_max_temp)"
    rm -rf "$cdir"

    # CPU utilisation over the load.
    local util
    util="$(awk -v a="$idle_stat" -v b="$idle_util" '
        BEGIN { split(a, x, " "); split(b, y, " ");
                dt = y[1] - x[1]; di = y[2] - x[2];
                if (dt <= 0) { print ""; exit }
                printf "%.0f", (1 - di / dt) * 100 }')"
    local clip
    clip="$(awk -v m="$CPU_BASE_MHZ" -v c="$(read_cpu_mhz)" 'BEGIN { if (m+0 > 0 && c+0 > 0) printf "~%d MHz (%d%% of base)", c, c/m*100; }')"

    report_line ""
    report_kv "Temperature before (idle)" "$([[ -n "$idle_temp" ]] && echo "${idle_temp} C" || echo n/a)"
    report_kv "Temperature peak under load" "$([[ -n "$peak_temp" ]] && echo "${peak_temp} C" || echo n/a)"
    report_kv "Temperature after 10 s cooldown" "$([[ -n "$after_temp" ]] && echo "${after_temp} C" || echo n/a)"
    [[ -n "$util" ]] && report_kv "Average CPU load" "${util}%"
    [[ -n "$clip" ]] && report_kv "Average clock under load" "$clip"

    if [[ -z "$peak_temp" ]]; then
        report_flag "$NOTE" "This laptop does not expose a temperature sensor. For exact CPU temperatures install lm-sensors (sensors-detect)."
    elif (( peak_temp >= 95 )); then
        report_flag "$RED" "CPU reached ${peak_temp} C - overheating (dust, dried thermal paste or fan problem)."
    elif (( peak_temp >= 88 )); then
        report_flag "$YELLOW" "CPU reached ${peak_temp} C - running hot; cooling may need cleaning."
    else
        report_ok "Peak temperature ${peak_temp} C."
    fi

    report_kv "Calculations verified" "$total ($wrong wrong)"
    if (( wrong > 0 )); then
        report_flag "$RED" "CPU produced $wrong wrong results under load - unstable (overheating, undervolting/overclocking, or faulty CPU/RAM)."
    elif (( total > 0 )); then
        report_ok "All $total calculations under load were correct."
    else
        report_flag "$YELLOW" "The verified stress test did not run - result unknown."
    fi
    if (( ${#rates[@]} >= 4 )); then
        local first last drop
        first="$(awk -v a="${rates[0]}" -v b="${rates[1]}" 'BEGIN { print (a+b)/2 }')"
        last="$(awk -v a="${rates[${#rates[@]}-2]}" -v b="${rates[${#rates[@]}-1]}" 'BEGIN { print (a+b)/2 }')"
        drop="$(awk -v f="$first" -v l="$last" 'BEGIN { if (f > 0) printf "%.0f", (1 - l/f) * 100; else print "" }')"
        [[ -n "$drop" ]] && report_kv "Speed start -> end of test" "${drop}% change"
        if [[ -n "$drop" && "$drop" =~ ^[0-9]+$ ]] && (( drop >= 50 )); then
            report_flag "$YELLOW" "Speed fell ${drop}% during the test - strong thermal/power throttling."
        fi
    fi

    STRESS_SUMMARY="${total} verified, ${wrong} wrong"
}

# --------------------------------------------------------------------------
# Kernel error history
# --------------------------------------------------------------------------
section_history() {
    local days="$1"
    report_section "8. CRASH & HARDWARE ERROR HISTORY (last ${days} days)" "Error history"
    local log=""
    if have journalctl; then
        log="$(journalctl -k --since "-${days} days" --no-pager -q 2>/dev/null)" || log=""
    fi
    if [[ -z "$log" ]] && have dmesg; then
        log="$(dmesg 2>/dev/null)" || log=""
    fi
    if [[ -z "$log" ]]; then
        report_flag "$YELLOW" "Could not read the kernel log (need root, or dmesg/journalctl restricted)."
        return
    fi

    local reds=0 yellows=0 notes=0 last_red="" last_yellow="" line level
    while IFS= read -r line; do
        level="$(kernel_error_level "$line")"
        case "$level" in
            "$RED")    reds=$(( reds + 1 ));    last_red="$(clean_str "$line")" ;;
            "$YELLOW") yellows=$(( yellows + 1 )); last_yellow="$(clean_str "$line")" ;;
            "$NOTE")   notes=$(( notes + 1 )) ;;
        esac
    done <<<"$log"

    report_kv "Hardware errors (MCE/WHEA)" "$reds"
    report_kv "Correctable / throttling / IO warnings" "$yellows"
    report_kv "Out-of-memory events" "$notes"
    if (( reds > 0 )); then
        report_flag "$RED" "$reds fatal hardware or filesystem error(s) in the kernel log, e.g.: ${last_red:0:120}"
    fi
    if (( yellows > 0 )); then
        report_flag "$YELLOW" "$yellows corrected hardware / disk / throttling warning(s), e.g.: ${last_yellow:0:120}"
    fi
    if (( notes > 0 )); then
        report_flag "$NOTE" "$notes out-of-memory event(s) - the machine may have been short on RAM."
    fi
    if (( reds == 0 && yellows == 0 && notes == 0 )); then
        report_ok "No crashes or hardware errors logged."
    fi
    report_line "  -> The kernel log is a ring buffer; a reboot clears it, so older problems"
    report_line "     may not be visible. Check 'journalctl -k -b -1' for the previous boot."
    HISTORY_SUMMARY="${reds} hardware errors, ${yellows} warnings"
}

# --------------------------------------------------------------------------
# Quick RAM test (writes and reads back patterns)
# --------------------------------------------------------------------------
gen_pattern() {
    local name="$1" mb="$2"
    case "$name" in
        zeros)  dd if=/dev/zero bs=1M count="$mb" 2>/dev/null ;;
        ones)   dd if=/dev/zero bs=1M count="$mb" 2>/dev/null | tr '\0' '\377' ;;
        0x55)   dd if=/dev/zero bs=1M count="$mb" 2>/dev/null | tr '\0' '\125' ;;
        0xAA)   dd if=/dev/zero bs=1M count="$mb" 2>/dev/null | tr '\0' '\252' ;;
        random) dd if=/dev/urandom bs=1M count="$mb" 2>/dev/null ;;
    esac
}

section_memtest() {
    local budget="$1"
    report_section "9. QUICK MEMORY (RAM) TEST" "Memory test"

    local total_kb avail_kb
    total_kb="$(meminfo_kb MemTotal)"
    avail_kb="$(meminfo_kb MemAvailable)"
    if (( avail_kb <= 0 )); then
        report_flag "$YELLOW" "Could not read free memory - RAM test skipped."
        return
    fi

    # Use 60% of free RAM, capped at 8 GB, so the rest of the system keeps running.
    local target_mb cap_mb
    target_mb=$(( avail_kb * 60 / 100 / 1024 ))
    cap_mb=$(( 8 * 1024 ))
    (( target_mb > cap_mb )) && target_mb="$cap_mb"
    if (( target_mb < 1 )); then
        report_flag "$YELLOW" "Not enough free memory for the RAM test."
        return
    fi

    # Prefer tmpfs so the test really touches RAM.
    local dir="" size_mb_free
    for dir in /dev/shm "${TMPDIR:-}" /tmp; do
        [[ -n "$dir" && -w "$dir" ]] || continue
        size_mb_free="$(df -Pm "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
        [[ "$size_mb_free" =~ ^[0-9]+$ ]] || continue
        (( size_mb_free > target_mb + 64 )) && break
        dir=""
    done
    if [[ -z "$dir" ]]; then
        report_flag "$YELLOW" "Not enough free space for the RAM test."
        return
    fi

    report_kv "Memory tested" "$(human_size "$(( target_mb * 1024 * 1024 ))" 1) of $(human_size "$(( total_kb * 1024 ))" 1)"
    report_line "  Writing and verifying patterns for about ${budget}s..."

    local tmp
    tmp="$(mktemp "$dir/laptop_check_memtest.XXXXXX")" || {
        report_flag "$YELLOW" "Could not create the RAM test file."
        return
    }
    local patterns=(zeros ones 0x55 0xAA random)
    local bad=0 passes=0 start now wrote read
    start="$(date +%s)"
    local finished=0
    while (( !finished )); do
        local name
        for name in "${patterns[@]}"; do
            passes=$(( passes + 1 ))
            wrote="$(gen_pattern "$name" "$target_mb" | tee "$tmp" | sha256sum | awk '{print $1}')"
            read="$(sha256sum "$tmp" | awk '{print $1}')"
            if [[ "$wrote" != "$read" ]]; then
                bad=$(( bad + 1 ))
                report_line "    pass $passes ($name): CORRUPTED"
            else
                report_line "    pass $passes ($name): OK"
            fi
            now="$(date +%s)"
            if (( passes >= ${#patterns[@]} && now - start >= budget )); then
                finished=1
                break
            fi
        done
    done
    rm -f "$tmp"

    if (( bad > 0 )); then
        report_flag "$RED" "RAM test found $bad corrupted pass(es) - faulty memory. Confirm with MemTest86 before buying."
    else
        report_ok "No errors over $passes passes."
    fi
    report_line "  -> Quick test of the free memory only. A full test: MemTest86 from a USB"
    report_line "     stick (1+ hour), or memtester."
    MEMTEST_SUMMARY="$([[ $bad -gt 0 ]] && echo 'ERRORS FOUND' || echo OK) ($passes passes)"
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: laptop_check.sh [options]

  --seconds N          stress test length in seconds (default 30)
  --skip-stress        skip the CPU stress test
  --skip-memtest       skip the quick RAM test
  --memtest-seconds N  RAM test length in seconds (default 45)
  --history-days N     days of kernel error history to read (default 90)
  --no-pause           do not wait for Enter at the end
  -h, --help           show this help
EOF
}

parse_args() {
    STRESS_SECONDS=30
    SKIP_STRESS=0
    SKIP_MEMTEST=0
    MEMTEST_SECONDS=45
    HISTORY_DAYS=90
    NO_PAUSE=0

    while (( $# > 0 )); do
        case "$1" in
            --seconds)          need_value "$@" || return 2; STRESS_SECONDS="$2"; shift 2 ;;
            --seconds=*)        STRESS_SECONDS="${1#*=}"; shift ;;
            --memtest-seconds)  need_value "$@" || return 2; MEMTEST_SECONDS="$2"; shift 2 ;;
            --memtest-seconds=*) MEMTEST_SECONDS="${1#*=}"; shift ;;
            --history-days)     need_value "$@" || return 2; HISTORY_DAYS="$2"; shift 2 ;;
            --history-days=*)   HISTORY_DAYS="${1#*=}"; shift ;;
            --skip-stress)      SKIP_STRESS=1; shift ;;
            --skip-memtest)     SKIP_MEMTEST=1; shift ;;
            --no-pause)         NO_PAUSE=1; shift ;;
            -h|--help)          usage; exit 0 ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                usage >&2
                return 2 ;;
        esac
    done
    local v
    for v in "$STRESS_SECONDS" "$MEMTEST_SECONDS" "$HISTORY_DAYS"; do
        if [[ ! "$v" =~ ^[0-9]+$ ]]; then
            printf 'Error: expected a non-negative integer, got "%s"\n' "$v" >&2
            return 2
        fi
    done
    return 0
}

need_value() {
    if (( $# < 2 )); then
        printf 'Error: %s needs a value\n' "$1" >&2
        return 1
    fi
    return 0
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
output_dir() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local d
    for d in "$here" "${TMPDIR:-/tmp}"; do
        [[ -w "$d" ]] && { printf '%s' "$d"; return; }
    done
    printf '%s' "${TMPDIR:-/tmp}"
}

main() {
    if ! parse_args "$@"; then
        return 2
    fi

    if [[ -t 1 ]]; then
        USE_COLOR=1
    fi
    reset_report

    printf 'USED LAPTOP INSPECTION REPORT (Linux)\n'
    REPORT_LINES+=("USED LAPTOP INSPECTION REPORT (Linux)")
    printf 'Collecting data - this takes a few minutes...\n\n'

    local outdir stamp
    outdir="$(output_dir)"
    stamp="$(date '+%Y%m%d_%H%M')"

    section_system
    section_cpu
    section_ram
    section_disks
    section_battery
    section_os
    if (( !SKIP_STRESS )); then
        section_stress "$(( STRESS_SECONDS < 5 ? 5 : STRESS_SECONDS ))"
    fi
    section_uptime
    section_history "$(( HISTORY_DAYS < 1 ? 1 : HISTORY_DAYS ))"
    if (( !SKIP_MEMTEST )); then
        section_memtest "$(( MEMTEST_SECONDS < 5 ? 5 : MEMTEST_SECONDS ))"
    fi

    local facts=()
    facts+=("Model" "$(clean_str "${SYSTEM_VENDOR:-} ${SYSTEM_MODEL:-}")")
    facts+=("CPU" "${CPU_MODEL_TEXT:-n/a} (${CPU_THREADS:-?} threads)")
    facts+=("RAM" "$(human_size "${RAM_TOTAL_BYTES:-0}" 1)")
    facts+=("Storage" "${STORAGE_SUMMARY:-n/a}")
    facts+=("Battery health" "${BATTERY_SUMMARY:-n/a}")
    facts+=("OS" "${OS_SUMMARY:-n/a}")
    if (( !SKIP_STRESS )); then
        facts+=("CPU calculations" "${STRESS_SUMMARY:-n/a}")
    fi
    facts+=("Kernel history" "${HISTORY_SUMMARY:-n/a}")
    if (( !SKIP_MEMTEST )); then
        facts+=("RAM test" "${MEMTEST_SUMMARY:-n/a}")
    fi
    report_summary "${facts[@]}"

    local name path
    name="$(clean_str "${SYSTEM_HOST:-laptop}")"
    path="$outdir/laptop_report_${name}_${stamp}.txt"
    if printf '%s\n' "${REPORT_LINES[@]}" > "$path" 2>/dev/null; then
        printf '\nReport saved to: %s\n' "$path"
    else
        printf '\nCould not save report to %s\n' "$path" >&2
    fi

    if (( !NO_PAUSE )); then
        printf '\nPress Enter to exit...'
        read -r _ || true
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit $?
fi
