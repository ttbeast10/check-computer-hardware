#!/usr/bin/env bash
#
# tests/test_laptop_check.sh - test suite for laptop_check.sh.
#
# The Windows-only data collection (CIM / powercfg / event log) cannot run on
# the CI host, so these tests focus on the pure logic that decides what is a
# red flag / warning / note, the report formatting and argument parsing - the
# parts that are supposed to behave exactly like laptop_check.py.

set -u
export LC_ALL=C

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/laptop_check.sh"

PASS=0
FAIL=0

check() { # description expected actual
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual"
    fi
}

check_true() { # description condition-result (0/1)
    local desc="$1" rc="$2"
    if [ "$rc" = "0" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s (expected true)\n' "$desc"
    fi
}

check_false() {
    local desc="$1" rc="$2"
    if [ "$rc" != "0" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s (expected false)\n' "$desc"
    fi
}

# --------------------------------------------------------------- file checks

if [ ! -f "$SCRIPT" ]; then
    printf 'FAIL: %s does not exist\n' "$SCRIPT"
    exit 1
fi
if [ ! -x "$SCRIPT" ]; then
    printf 'FAIL: %s is not executable\n' "$SCRIPT"
    exit 1
fi

bash -n "$SCRIPT"
rc=$?
check "script passes 'bash -n' syntax check" 0 "$rc"

# --------------------------------------------------------------- CLI checks

out=$(bash "$SCRIPT" --help 2>&1)
rc=$?
check "--help exits 0" 0 "$rc"
case "$out" in
    *"--seconds"*"--skip-stress"*"--skip-memtest"*"--history-days"*) check_true "--help documents the options" 0 ;;
    *) check_true "--help documents the options" 1 ;;
esac

bash "$SCRIPT" --definitely-not-an-option >/dev/null 2>&1
rc=$?
if [ "$rc" != "0" ]; then
    check_true "unknown option fails" 0
else
    check_true "unknown option fails" 1
fi

# Load the library (main must not run when sourced).
# shellcheck source=../laptop_check.sh
source "$SCRIPT"

# --------------------------------------------------------------- formatting

check "size_str decimal 1GB" "1 GB" "$(size_str 1000000000)"
check "size_str decimal 500GB" "500 GB" "$(size_str 500000000000)"
check "size_str decimal 2TB" "2.00 TB" "$(size_str 2000000000000)"
check "size_str binary 1GB" "1 GB" "$(size_str 1073741824 binary)"
check "size_str empty is n/a" "n/a" "$(size_str '')"
check "size_str zero is n/a" "n/a" "$(size_str 0)"

check "thousands 900" "900" "$(thousands 900)"
check "thousands 50000" "50,000" "$(thousands 50000)"
check "thousands 1073741824" "1,073,741,824" "$(thousands 1073741824)"

check "duration_str 1h1min" "1 h 1 min" "$(duration_str 3661)"
check "duration_str 1 day" "1 day 1 h 0 min" "$(duration_str 90000)"
check "duration_str 2 days" "2 days 3 h 4 min" "$(duration_str $((2 * 86400 + 3 * 3600 + 4 * 60)))"
check "duration_str empty" "0 h 0 min" "$(duration_str '')"

check "clean collapses whitespace" "a b c" "$(clean '  a   b   c  ')"
check "clean of empty string" "" "$(clean '')"

# --------------------------------------------------------------- lookups

check "memtype DDR4" "DDR4" "$(memtype 26)"
check "memtype DDR5" "DDR5" "$(memtype 34)"
check "memtype unknown" "unknown" "$(memtype 99)"

check "whea_kind 19" "corrected CPU error" "$(whea_kind 19)"
check "whea_kind 47" "corrected memory error" "$(whea_kind 47)"
check "whea_kind other" "hardware error (event 99)" "$(whea_kind 99)"

check "avg_of" "2" "$(avg_of 1 2 3)"
check "max_of" "9" "$(max_of 3 9 4)"

check "license 1" "Licensed (activated)" "$(license_status 1)"
check "license 5" "Notification mode (NOT activated)" "$(license_status 5)"
check "license 42" "status 42" "$(license_status 42)"

# bugcheck_info -> "code|name|cause|level"
check "bugcheck 0x1A" "26|MEMORY_MANAGEMENT|RAM|RED" "$(bugcheck_info 26)"
check "bugcheck 0x9C" "156|MACHINE_CHECK_EXCEPTION|CPU|RED" "$(bugcheck_info 156)"
check "bugcheck 0x1000007E normalises" "126|SYSTEM_THREAD_EXCEPTION_NOT_HANDLED|driver|NOTE" \
    "$(bugcheck_info 268435582)"
check "bugcheck unknown" "39321|unknown|unknown|NOTE" "$(bugcheck_info 39321)"
check "bugcheck empty" "0|unknown|unknown|NOTE" "$(bugcheck_info '')"

# --------------------------------------------------------------- report

REPORT_LINES=()
FLAG_LEVELS=()
FLAG_SECTIONS=()
FLAG_MSGS=()
SECTION_NAME=""

{
    rep_section "0. SYSTEM" "System"
    rep_line "plain"
    rep_kv "Key" "value"
    rep_flag RED "bad thing"
    rep_ok "all good"
} >/dev/null

check "rep_section sets the section" "System" "$SECTION_NAME"
check "rep_section title line" " 0. SYSTEM" "${REPORT_LINES[2]}"
check "rep_line stores the text" "plain" "${REPORT_LINES[4]}"
check "rep_kv pads the key column" "  $(printf '%-34s' 'Key:')value" "${REPORT_LINES[5]}"
check "rep_flag level stored" "RED" "${FLAG_LEVELS[0]}"
check "rep_flag section stored" "System" "${FLAG_SECTIONS[0]}"
check "rep_flag message stored" "bad thing" "${FLAG_MSGS[0]}"
check "rep_flag line format" "  [RED] bad thing" "${REPORT_LINES[6]}"
check "rep_ok line format" "  [OK] all good" "${REPORT_LINES[7]}"

# --------------------------------------------------------------- argument parsing

reset_opts() {
    OPT_SECONDS=30
    OPT_SKIP_STRESS=0
    OPT_SKIP_MEMTEST=0
    OPT_MEMTEST_SECONDS=45
    OPT_HISTORY_DAYS=90
    OPT_NO_ADMIN=0
    OPT_NO_PAUSE=0
    OPT_ELEVATED=0
    OPT_HELP=0
}

reset_opts
parse_args
rc=$?
check "parse_args default rc" 0 "$rc"
check "default seconds" 30 "$OPT_SECONDS"
check "default memtest seconds" 45 "$OPT_MEMTEST_SECONDS"
check "default history days" 90 "$OPT_HISTORY_DAYS"

reset_opts
parse_args --seconds 60 --skip-stress --skip-memtest --memtest-seconds 10 --history-days 7 --no-admin --no-pause
rc=$?
check "parse_args overrides rc" 0 "$rc"
check "seconds override" 60 "$OPT_SECONDS"
check "memtest override" 10 "$OPT_MEMTEST_SECONDS"
check "history override" 7 "$OPT_HISTORY_DAYS"
check "skip stress" 1 "$OPT_SKIP_STRESS"
check "skip memtest" 1 "$OPT_SKIP_MEMTEST"
check "no admin" 1 "$OPT_NO_ADMIN"
check "no pause" 1 "$OPT_NO_PAUSE"

reset_opts
parse_args --elevated
check "elevated flag" 1 "$OPT_ELEVATED"

reset_opts
parse_args --help
check "help flag" 1 "$OPT_HELP"

reset_opts
parse_args --seconds >/dev/null 2>&1
rc=$?
check "missing option value fails" 2 "$rc"

# --------------------------------------------------------------- summary verdict

check "verdict with red flags" \
    "RED" "$(verdict_for 2 0 0)"
check "verdict with warnings only" \
    "YELLOW" "$(verdict_for 0 3 0)"
check "verdict clean" \
    "OK" "$(verdict_for 0 0 1)"

# --------------------------------------------------------------- done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
