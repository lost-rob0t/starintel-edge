# Watch runtime host

`WatchHost.kt` forwards to the same Common Lisp port as Android. This is a source facade, not a watch APK. Wear OS is the first implementation target; no Apple Watch or other closed watch-platform support is claimed.

Build a watch-local, lightweight profile with bounded local state, explicit sensor permissions, power/thermal policy and optional phone relay. The goal is useful disconnected operation, not a watch that is only a notification mirror. Do not silently substitute a phone backend for a requested local runtime.

Gate release on ABCL/ART execution on the actual watch, process death, offline operation with the phone disconnected, charging/battery tests, notification/permission behavior, and wearable transport reconnection. Standalone manifest status must match actual functionality. Existing Wear OS product UI and phone configuration companion can remain downstream.

Reference: https://developer.android.com/training/wearables/apps/standalone-apps (checked 2026-09-23).
