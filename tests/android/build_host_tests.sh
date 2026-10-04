#!/usr/bin/env bash
# Builds the Android ECL adapter against the host ECL and runs the native
# host test suite (lifecycle, ownership, bounds, error behavior).
# Usage: tests/android/build_host_tests.sh   (from repository root)
set -euo pipefail

fixture_dir="tests/android/fixture"
build_dir="build/android-host-tests"
ecl_prefix=${1:-}
if [ -z "$ecl_prefix" ]; then
    if command -v ecl-config >/dev/null 2>&1; then
        ecl_prefix=$(dirname "$(command -v ecl-config)")
    elif command -v ecl >/dev/null 2>&1; then
        ecl_prefix=$(dirname "$(readlink -f "$(command -v ecl)")")
    fi
fi
if [ -z "$ecl_prefix" ]; then
    printf 'ECL is required; pass the directory containing ecl-config\n' >&2
    exit 1
fi

mkdir -p "$build_dir"
CC=${CC:-cc}

ECL_CFLAGS=$("$ecl_prefix/ecl-config" --cflags)
ECL_LIBS=$("$ecl_prefix/ecl-config" --libs)

# shellcheck disable=SC2086
$CC -O2 -Wall -Werror -std=gnu99 $ECL_CFLAGS \
    -Iplatforms/android/native \
    -o "$build_dir/native_test" \
    tests/android/native_test.c \
    platforms/android/native/starintel_ecl_adapter.c \
    $ECL_LIBS

"$build_dir/native_test" "$fixture_dir"

# Separate process: never reuse an ECL instance after shutdown. Copy only the
# trusted fixture into a non-ASCII pathname so native startup conversion is tested.
unicode_runtime="$build_dir/runtime-café-🙂"
mkdir -p "$unicode_runtime/lisp"
cp tests/android/unicode-fixture/lisp/startup.lisp "$unicode_runtime/lisp/startup.lisp"
# shellcheck disable=SC2086
$CC -O2 -Wall -Werror -std=gnu99 $ECL_CFLAGS \
    -Iplatforms/android/native \
    -o "$build_dir/native_unicode_test" \
    tests/android/native_unicode_test.c \
    platforms/android/native/starintel_ecl_adapter.c \
    $ECL_LIBS
EDGE_UNICODE_TEST_ROOT="$PWD/" "$build_dir/native_unicode_test" "$unicode_runtime"
