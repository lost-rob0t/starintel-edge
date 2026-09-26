#!/usr/bin/env bash
# Isolated ART/ECL acceptance test. Creates an ephemeral AVD and signing key,
# targets one exact emulator serial, and never installs a product application.
set -euo pipefail

if [ "${STARINTEL_ANDROID_TEST_IN_SHELL:-}" != 1 ]; then
    exec env -u 'BASH_FUNC_git-sync%%' STARINTEL_ANDROID_TEST_IN_SHELL=1 \
        nix develop -c bash "$0" "$@"
fi

port=${STARINTEL_ANDROID_EMULATOR_PORT:-5584}
serial="emulator-$port"
test_root=$(mktemp -d /tmp/starintel-edge-emulator-test.XXXXXX)
avd_home="$test_root/avd"
android_user_home="$test_root/user"
emulator_pid=

cleanup() {
    if [ -n "$emulator_pid" ]; then
        adb -s "$serial" emu kill >/dev/null 2>&1 || true
        wait "$emulator_pid" 2>/dev/null || true
    fi
    case "$test_root" in
        /tmp/starintel-edge-emulator-test.*) find "$test_root" -depth -delete ;;
        *) printf 'Refusing to remove unexpected test path: %s\n' "$test_root" >&2 ;;
    esac
}
trap cleanup EXIT INT TERM

if adb -s "$serial" get-state >/dev/null 2>&1; then
    printf 'Exact test serial is already in use: %s\n' "$serial" >&2
    exit 1
fi

mkdir -p "$avd_home" "$android_user_home"
export ANDROID_AVD_HOME="$avd_home"
export ANDROID_USER_HOME="$android_user_home"

avdmanager create avd --force \
    --name starintel_edge_runtime \
    --path "$avd_home/starintel_edge_runtime.avd" \
    --package 'system-images;android-36;google_apis;x86_64' \
    --device pixel_4 <<< no

apk_output=$(nix build .#android-runtime-diagnostic-apk \
    --no-link --print-out-paths)
unsigned_apk="$apk_output/starintel-edge-runtime-diagnostic-unsigned.apk"
signed_apk="$test_root/starintel-edge-runtime-diagnostic.apk"
keystore="$test_root/debug.keystore"

keytool -genkeypair -keystore "$keystore" -storepass android \
    -alias androiddebugkey -keypass android \
    -dname 'CN=Android Debug,O=StarIntel,C=US' \
    -keyalg RSA -validity 1 >/dev/null 2>&1
"$ANDROID_SDK_ROOT/build-tools/36.0.0/apksigner" sign \
    --ks "$keystore" --ks-pass pass:android --key-pass pass:android \
    --out "$signed_apk" "$unsigned_apk"

emulator -avd starintel_edge_runtime -port "$port" \
    -no-window -no-snapshot -wipe-data -no-audio -no-boot-anim \
    -gpu swiftshader_indirect >"$test_root/emulator.log" 2>&1 &
emulator_pid=$!

adb -s "$serial" wait-for-device
booted=0
for _ in $(seq 1 120); do
    if [ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
        booted=1
        break
    fi
    sleep 1
done
test "$booted" -eq 1
test "$(adb -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')" = x86_64

adb -s "$serial" install -r "$signed_apk"
adb -s "$serial" shell svc wifi disable
adb -s "$serial" shell svc data disable
adb -s "$serial" logcat -c
adb -s "$serial" shell am start -W \
    -n actor.starintel.edge.diagnostic/.RuntimeDiagnosticActivity >/dev/null

passed=0
for _ in $(seq 1 90); do
    if adb -s "$serial" logcat -d -s StarIntelEdgeDiagnostic:I '*:S' |
            grep -q ' PASS '; then
        passed=1
        break
    fi
    sleep 1
done
test "$passed" -eq 1

diagnostic_log=$(adb -s "$serial" logcat -d \
    -s StarIntelEdgeRuntime:E StarIntelEdgeDiagnostic:I '*:S')
if printf '%s' "$diagnostic_log" |
        grep -Eq 'Runtime diagnostic failed| FAIL '; then
    printf '%s\n' "$diagnostic_log" >&2
    exit 1
fi

if adb -s "$serial" shell dumpsys package actor.starintel.edge.diagnostic |
        grep -q android.permission.INTERNET; then
    printf 'Diagnostic APK unexpectedly requests Internet permission\n' >&2
    exit 1
fi
adb -s "$serial" shell uiautomator dump /sdcard/starintel-edge.xml >/dev/null
adb -s "$serial" shell cat /sdcard/starintel-edge.xml |
    grep -q 'Local Sento actor round-trip passed'
printf '%s\n' "$diagnostic_log"
