#!/usr/bin/env bash
# Isolated ART/ECL acceptance test. Creates an ephemeral AVD and signing key,
# targets one exact emulator serial, and never installs a product application.
set -euo pipefail

if [ "${STARINTEL_ANDROID_TEST_IN_SHELL:-}" != 1 ]; then
    exec env -u 'BASH_FUNC_git-sync%%' STARINTEL_ANDROID_TEST_IN_SHELL=1 \
        nix develop --no-update-lock-file .#android-runtime -c bash "$0" "$@"
fi

# CI images may export ANDROID_HOME for a different SDK. Use only the flake SDK.
: "${ANDROID_SDK_ROOT:?android-runtime shell must provide its SDK}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"
system_image="$ANDROID_SDK_ROOT/system-images/android-36/google_apis/x86_64"
for required in system.img vendor.img ramdisk.img kernel-ranchu; do
    if [ ! -s "$system_image/$required" ]; then
        printf 'Missing emulator image file: %s/%s\n' "$system_image" "$required" >&2
        exit 1
    fi
done
printf 'Android SDK: %s\nSystem image: %s\n' "$ANDROID_HOME" "$system_image"

port=${STARINTEL_ANDROID_EMULATOR_PORT:-5584}
serial="emulator-$port"
test_root=$(mktemp -d /tmp/starintel-edge-emulator-test.XXXXXX)
avd_home="$test_root/avd"
android_user_home="$test_root/user"
emulator_pid=
evidence="$PWD/build/owned-art-evidence"
mkdir -p "$evidence"
git rev-parse HEAD > "$evidence/source-revision.txt"

cleanup() {
    if [ -n "$emulator_pid" ]; then
        timeout 10 adb -s "$serial" logcat -d > "$evidence/logcat-final.txt" 2>&1 || true
        cp "$test_root/emulator.log" "$evidence/emulator.log" || true
        tail -n 100 "$test_root/emulator.log" || true
        timeout 10 adb -s "$serial" emu kill >/dev/null 2>&1 || true
        # Only the emulator still tracked as our own active shell job. ADB may
        # never connect during a failed boot, so it cannot be the sole cleanup path.
        if jobs -pr | grep -qx "$emulator_pid"; then
            kill -KILL "$emulator_pid" 2>/dev/null || true
        fi
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

apk_output=$(nix build --no-update-lock-file .#android-runtime-diagnostic-apk \
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

bundle_output=$(nix build --no-update-lock-file .#android-runtime-x86_64 --no-link --print-out-paths)
python3 tests/android/verify_owned_apk.py "$signed_apk" "$bundle_output" > "$evidence/packaged-bytes.json"

cp "$signed_apk" "$evidence/owned-runtime-diagnostic.apk"
sha256sum "$evidence/owned-runtime-diagnostic.apk" > "$evidence/apk.sha256"
cat "$avd_home/starintel_edge_runtime.avd/config.ini" > "$evidence/avd-config.ini"
printf 'ANDROID_HOME=%s\nANDROID_SDK_ROOT=%s\n' "$ANDROID_HOME" "$ANDROID_SDK_ROOT" > "$evidence/sdk.txt"

emulator -avd starintel_edge_runtime -port "$port" \
    -no-window -no-snapshot -wipe-data -no-audio -no-boot-anim \
    -gpu swiftshader_indirect >"$test_root/emulator.log" 2>&1 &
emulator_pid=$!

booted=0
boot_deadline=$((SECONDS + 300))
while [ "$SECONDS" -lt "$boot_deadline" ]; do
    if ! jobs -pr | grep -qx "$emulator_pid"; then
        echo 'Owned emulator exited before boot completed' >&2
        exit 1
    fi
    if [ "$(timeout 5 adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)" = 1 ]; then
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
package=actor.starintel.edge.diagnostic
adb -s "$serial" shell getprop > "$evidence/emulator-properties.txt"
if adb -s "$serial" shell dumpsys package "$package" | grep -q android.permission.INTERNET; then
    echo 'Diagnostic APK unexpectedly requests Internet permission' >&2
    exit 1
fi
for phase in first restart; do
    adb -s "$serial" logcat -c
    adb -s "$serial" shell am start -W -n "$package/actor.starintel.edge.service.RuntimeDiagnosticActivity" \
        --es phase "$phase" > "$evidence/launch-$phase.txt"
    ready=0
    for _ in $(seq 1 120); do
        adb -s "$serial" logcat -d -s StarIntelEdgeDiagnostic:I '*:S' > "$evidence/$phase.log"
        if grep -q "FAIL $phase" "$evidence/$phase.log"; then cat "$evidence/$phase.log"; exit 1; fi
        if grep -q "HOLD $phase" "$evidence/$phase.log"; then ready=1; break; fi
        sleep 1
    done
    test "$ready" -eq 1
    test "$(grep -c "STOPPED $phase" "$evidence/$phase.log")" -eq 2
    adb -s "$serial" shell ps -A -o PID,PPID,ARGS > "$evidence/processes-$phase.txt"
    # Exact disposable APK PID only. Killing ART alone tests creator-parent
    # death separately from Android force-stop, which may kill the whole UID.
    parent=$(adb -s "$serial" shell pidof "$package" | tr -d '\r')
    [[ "$parent" =~ ^[0-9]+$ ]]
    child=$(awk -v p="$parent" '$2 == p && /libstarintel_ecl_runner.so/ {print $1}' "$evidence/processes-$phase.txt")
    [[ "$child" =~ ^[0-9]+$ ]]
    adb -s "$serial" shell run-as "$package" kill -0 "$child"
    adb -s "$serial" shell run-as "$package" kill -9 "$parent"
    retired=0
    for _ in $(seq 1 30); do
        if ! adb -s "$serial" shell run-as "$package" kill -0 "$child" 2>/dev/null; then retired=1; break; fi
        sleep 1
    done
    test "$retired" -eq 1
    printf 'ART pid=%s killed; owned child pid=%s exited; phase=%s\n' "$parent" "$child" "$phase" >> "$evidence/retirement.txt"
    adb -s "$serial" shell am force-stop "$package"
done
printf '%s\n' 'PASS x86_64 Android ART launching standalone ECL: real Sento, stop/restart, parent death, offline private fixture preservation. No physical-device or database crash-durability claim.' | tee "$evidence/result.txt"
