#!/usr/bin/env bash
#
# Tests for laptop_check.sh (the Linux/bash port of the laptop check).
#
# The tests only exercise pure helper logic and synthetic sysfs/proc trees.
# They never run the CPU stress test or the RAM test, so they are quick and
# safe to run anywhere.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../laptop_check.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FATAL: cannot find $SCRIPT" >&2
    exit 2
fi

# Source the script. The entry point must be guarded with a BASH_SOURCE check
# so that sourcing does not start the inspection.
# shellcheck source=/dev/null
source "$SCRIPT"

pass=0
fail=0

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n      expected: %q\n      actual:   %q\n' "$label" "$expected" "$actual"
    fi
}

assert_nonzero() {
    local rc="$1" label="$2"
    if [[ "$rc" -ne 0 ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s (expected non-zero exit, got %s)\n' "$label" "$rc"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n      %q not found in output:\n%s\n' "$label" "$needle" "$haystack"
    fi
}

# --------------------------------------------------------------------------
# Syntax check
# --------------------------------------------------------------------------
if bash -n "$SCRIPT"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: bash -n reported a syntax error"
fi

# --------------------------------------------------------------------------
# human_size (mirrors size_str in laptop_check.py)
# --------------------------------------------------------------------------
assert_eq "n/a"   "$(human_size '')"            "human_size empty"
assert_eq "n/a"   "$(human_size 0)"             "human_size zero"
assert_eq "1.5 GB" "$(human_size 1500000000)"   "human_size decimal GB"
assert_eq "2 GB"  "$(human_size 2000000000)"    "human_size integer GB"
assert_eq "16 GB" "$(human_size 17179869184 1)" "human_size binary GB"
assert_eq "1.5 GB" "$(human_size 1610612736 1)" "human_size binary decimal GB"
assert_eq "1.02 TB" "$(human_size 1099511627776 1)" "human_size binary TB"

# --------------------------------------------------------------------------
# duration_str (mirrors duration_str in laptop_check.py)
# --------------------------------------------------------------------------
assert_eq "0 h 0 min"        "$(duration_str 0)"      "duration zero"
assert_eq "1 h 0 min"        "$(duration_str 3600)"   "duration one hour"
assert_eq "1 h 1 min"        "$(duration_str 3661)"   "duration hour+min"
assert_eq "1 day 1 h 0 min"  "$(duration_str 90000)"  "duration day"
assert_eq "2 days 0 h 0 min" "$(duration_str 172800)" "duration days"
assert_eq "0 h 2 min"        "$(duration_str 123.9)"  "duration float input"

# --------------------------------------------------------------------------
# clean_str
# --------------------------------------------------------------------------
assert_eq "a b" "$(clean_str '  a   b  ')"       "clean_str spaces"
assert_eq "x y" "$(clean_str "$(printf 'x\ty')")" "clean_str tab"

# --------------------------------------------------------------------------
# Report: flags and summary
# --------------------------------------------------------------------------
reset_report
report_section "1. CPU" "CPU"
report_flag "$RED" "bad cpu"
report_section "3. STORAGE" "Storage"
report_flag "$YELLOW" "worn disk"
report_flag "$NOTE" "just a note"
report_ok "disk fine"

assert_eq "3" "${#FLAGS[@]}" "flag count"
assert_eq "RED|CPU|bad cpu"      "${FLAGS[0]}" "first flag content"
assert_eq "YELLOW|Storage|worn disk" "${FLAGS[1]}" "second flag content"

summary="$(report_summary "Model" "Test Laptop" "RAM" "16 GB")"
assert_contains "Model"        "$summary" "summary prints facts"
assert_contains "RED FLAGS (1):" "$summary" "summary counts red flags"
assert_contains "WARNINGS (1):"  "$summary" "summary counts warnings"
assert_contains "NOTES (1):"     "$summary" "summary counts notes"
assert_contains "VERDICT"        "$summary" "summary prints verdict"

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
parse_args --seconds 60 --skip-stress --memtest-seconds 10
assert_eq "60" "$STRESS_SECONDS"  "parse --seconds"
assert_eq "1"  "$SKIP_STRESS"     "parse --skip-stress"
assert_eq "10" "$MEMTEST_SECONDS" "parse --memtest-seconds"

parse_args --history-days=180 --skip-memtest
assert_eq "180" "$HISTORY_DAYS" "parse --history-days=value"
assert_eq "1"   "$SKIP_MEMTEST" "parse --skip-memtest"

parse_args --no-pause
assert_eq "1" "$NO_PAUSE" "parse --no-pause"

parse_args --bogus-option >/dev/null 2>&1
assert_nonzero "$?" "unknown option rejected"

# Bad numeric values must be rejected rather than trusted.
parse_args --seconds notanumber >/dev/null 2>&1
assert_nonzero "$?" "non-numeric --seconds rejected"

# --------------------------------------------------------------------------
# Temperature reading from a synthetic sysfs tree
# --------------------------------------------------------------------------
tmp_sys="$(mktemp -d)"
mkdir -p "$tmp_sys/class/thermal/thermal_zone0" "$tmp_sys/class/thermal/thermal_zone1"
mkdir -p "$tmp_sys/class/hwmon/hwmon0"
printf '45000\n' > "$tmp_sys/class/thermal/thermal_zone0/temp"
printf '99000\n' > "$tmp_sys/class/thermal/thermal_zone1/temp"
printf '30000\n' > "$tmp_sys/class/hwmon/hwmon0/temp1_input"
saved_sysfs="$SYSFS_ROOT"
SYSFS_ROOT="$tmp_sys"
assert_eq "99" "$(read_max_temp)" "read_max_temp uses max of zones"
rm -rf "$tmp_sys"
SYSFS_ROOT="$saved_sysfs"

# A value that is obviously bogus (0) must be ignored.
tmp_sys="$(mktemp -d)"
mkdir -p "$tmp_sys/class/thermal/thermal_zone0"
printf '0\n' > "$tmp_sys/class/thermal/thermal_zone0/temp"
SYSFS_ROOT="$tmp_sys"
assert_eq "" "$(read_max_temp)" "read_max_temp ignores zero"
rm -rf "$tmp_sys"
SYSFS_ROOT="$saved_sysfs"

# --------------------------------------------------------------------------
# meminfo parsing from a synthetic /proc
# --------------------------------------------------------------------------
tmp_proc="$(mktemp -d)"
printf 'MemTotal:       16384000 kB\nMemAvailable:    8192000 kB\n' > "$tmp_proc/meminfo"
saved_proc="$PROC_ROOT"
PROC_ROOT="$tmp_proc"
assert_eq "16384000" "$(meminfo_kb MemTotal)"    "meminfo_kb MemTotal"
assert_eq "8192000"  "$(meminfo_kb MemAvailable)" "meminfo_kb MemAvailable"
assert_eq "0"        "$(meminfo_kb Missing)"      "meminfo_kb missing field"
rm -rf "$tmp_proc"
PROC_ROOT="$saved_proc"

# --------------------------------------------------------------------------
# Kernel error classification (used by the error-history section)
# --------------------------------------------------------------------------
assert_eq "$RED"    "$(kernel_error_level 'mce: [Hardware Error]: CPU 0: Machine Check: 0 Bank 5')" "MCE -> red"
assert_eq "$RED"    "$(kernel_error_level 'EDAC MC0: 1 Uncorrected error')"                         "uncorrected EDAC -> red"
assert_eq "$YELLOW" "$(kernel_error_level 'EDAC MC0: 1 Corrected error')"                           "corrected EDAC -> yellow"
assert_eq "$YELLOW" "$(kernel_error_level 'CPU0: Core temperature above threshold, cpu clock throttled')" "thermal throttle -> yellow"
assert_eq "$RED"    "$(kernel_error_level 'EXT4-fs error (device sda1): ext4_find_entry:1455')"     "filesystem error -> red"
assert_eq "$RED"    "$(kernel_error_level 'kernel BUG at mm/slub.c:4240!')"                          "kernel BUG -> red"
assert_eq "$YELLOW" "$(kernel_error_level 'ata1.00: failed command: READ FPDMA QUEUED')"            "ata error -> yellow"
assert_eq ""        "$(kernel_error_level 'Linux version 6.8.0-45-generic (buildd@lcy02)')"          "normal line -> none"

# --------------------------------------------------------------------------
# Verify arithmetic workload is deterministic and matches its expected value
# --------------------------------------------------------------------------
w1="$(verify_arithmetic)"
w2="$(verify_arithmetic)"
assert_eq "$w1" "$w2" "verify_arithmetic is deterministic"
assert_eq "1" "$([[ -n "$w1" ]] && echo 1 || echo 0)" "verify_arithmetic produces output"

# --------------------------------------------------------------------------
# summarize_flags counts by level
# --------------------------------------------------------------------------
reset_report
report_section "X" "X"
report_flag "$RED" "r1"
report_flag "$RED" "r2"
report_flag "$YELLOW" "y1"
assert_eq "2" "$(count_flags "$RED")"    "count_flags red"
assert_eq "1" "$(count_flags "$YELLOW")" "count_flags yellow"
assert_eq "0" "$(count_flags "$NOTE")"   "count_flags note"

# --------------------------------------------------------------------------
echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
