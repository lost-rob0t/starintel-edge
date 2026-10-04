#!/usr/bin/env bash
# Additional host gate using exact packaged startup/runtime/vendor Lisp assets.
# Does not execute the Android binaries or establish ART/device behavior.
# Usage: tests/android/build_packaged_host_test.sh /path/to/assets/starintel-edge
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ "$#" -ne 1 ]; then
    echo 'Pass the built bundle assets/starintel-edge directory' >&2
    exit 2
fi
mkdir -p build/android-host-tests
CC=${CC:-cc}
ECL_CFLAGS=$(ecl-config --cflags)
ECL_LIBS=$(ecl-config --libs)
# shellcheck disable=SC2086
$CC -O2 -Wall -Werror -std=gnu99 $ECL_CFLAGS -Iplatforms/android/native \
    -o build/android-host-tests/native_packaged_bootstrap_test \
    tests/android/native_packaged_bootstrap_test.c \
    platforms/android/native/starintel_ecl_adapter.c $ECL_LIBS
python3 tests/android/run_packaged_host_test.py "$1" \
    build/android-host-tests/native_packaged_bootstrap_test
