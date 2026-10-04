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
    status=$?
    set +e
    if [ "$status" -ne 0 ]; then
        printf 'Edge Android emulator diagnostic failed (exit %s)\n' "$status" >&2
        if adb -s "$serial" get-state >/dev/null 2>&1; then
            adb -s "$serial" logcat -d -t 200 >&2
        fi
        if [ -f "$test_root/emulator.log" ]; then
            tail -n 200 "$test_root/emulator.log" >&2
        fi
    fi
    if [ -n "$emulator_pid" ]; then
        adb -s "$serial" emu kill >/dev/null 2>&1 || true
        wait "$emulator_pid" 2>/dev/null || true
    fi
    case "$test_root" in
        /tmp/starintel-edge-emulator-test.*) find "$test_root" -depth -delete ;;
        *) printf 'Refusing to remove unexpected test path: %s\n' "$test_root" >&2 ;;
    esac
    return "$status"
}
trap cleanup EXIT INT TERM

if adb -s "$serial" get-state >/dev/null 2>&1; then
    printf 'Exact test serial is already in use: %s\n' "$serial" >&2
    exit 1
fi

mkdir -p "$avd_home" "$android_user_home"
export ANDROID_AVD_HOME="$avd_home"
export ANDROID_USER_HOME="$android_user_home"

avd_dir="$avd_home/starintel_edge_runtime.avd"
image_dir="$ANDROID_SDK_ROOT/system-images/android-36/google_apis/x86_64"
test -f "$image_dir/system.img"
mkdir -p "$avd_dir"
printf '%s\n' \
    'avd.ini.encoding=UTF-8' \
    "path=$avd_dir" \
    'target=android-36' \
    > "$avd_home/starintel_edge_runtime.ini"
printf '%s\n' \
    'AvdId=starintel_edge_runtime' \
    'PlayStore.enabled=false' \
    'abi.type=x86_64' \
    'avd.ini.displayname=StarIntel Edge runtime test' \
    'disk.dataPartition.size=6G' \
    'fastboot.forceColdBoot=yes' \
    'fastboot.forceFastBoot=no' \
    'hw.cpu.arch=x86_64' \
    'hw.cpu.ncore=4' \
    'hw.gpu.enabled=yes' \
    'hw.gpu.mode=swiftshader_indirect' \
    'hw.keyboard=yes' \
    'hw.lcd.density=420' \
    'hw.lcd.height=2400' \
    'hw.lcd.width=1080' \
    'hw.ramSize=2048' \
    'image.sysdir.1=system-images/android-36/google_apis/x86_64/' \
    'runtime.network.latency=none' \
    'runtime.network.speed=full' \
    'showDeviceFrame=no' \
    'skin.dynamic=yes' \
    'skin.name=1080x2400' \
    'skin.path=_no_skin' \
    'tag.display=Google APIs' \
    'tag.id=google_apis' \
    'vm.heapSize=576' \
    > "$avd_dir/config.ini"

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
    grep -q 'Closed actor catalog + dispatch passed'
printf '%s\n' "$diagnostic_log"
