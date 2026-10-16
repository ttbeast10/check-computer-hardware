#!/usr/bin/env bash
#
# tests/run_all.sh - run the whole test suite for the bash laptop check.
#
#   ./tests/run_all.sh
  
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

status=0
for t in "$HERE"/test_laptop_check.sh "$HERE"/test_laptop_check_integration.sh; do
    printf '==> %s\n' "$(basename "$t")"
    if ! bash "$t"; then
        status=1
    fi
    printf '\n'
done

if [ "$status" -eq 0 ]; then
    printf 'All test suites passed.\n'
else
    printf 'Some test suites FAILED.\n'
fi
exit "$status"
