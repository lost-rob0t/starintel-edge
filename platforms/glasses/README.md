# Smart-glasses hosts and adapters

`GlassesHosts.kt` provides typed native and companion facades. It does not yet bind any vendor SDK or certify a device. Target families include Android-installable glasses, XREAL/VITURE display/compute configurations, Vuzix/RealWear devices, and Meta. Each needs an exact model/firmware/host/SDK compatibility entry before support is claimed.

Native: execute the common Lisp runtime on installable hardware after proving the backend works. Companion: execute on Android/compute host; advertise the glasses as an accessory, not as an independent Lisp node. Reuse the same upstream host contract in both cases.

## Meta

Use the official Meta Wearables Device Access Toolkit Android integration. The official repository currently documents DAT 0.9.0, camera and display artifacts; the 2026-08-03 changelog describes `DeviceSession.addCamera()` with the stream underneath the camera. Earlier `addStream()` examples are not the current API. Pin and verify the SDK at implementation time, rather than copying an old sample.

The adapter must implement registration/permission flow, device/session lifecycle, capture/stream cancellation, disconnect/reconnect and permission revocation. Discover model-specific camera, display and input support. Never infer a display for all Ray-Ban/Meta models; conversely do not hard-code the obsolete assumption that no Meta model supports display APIs. Official companion APIs do not imply a sideloadable on-glasses runtime. No custom firmware or bypass is assumed.

Use vendor mock tests plus physical-device tests. Mock availability is not hardware conformance. Sensor operations require visible user consent/indicators and scoped capabilities; permission revocation must stop the actual stream. SDK analytics and crash-reporting controls must be exposed deliberately, without embedding secrets.

## Primary references checked 2026-09-23

- https://github.com/facebook/meta-wearables-dat-android
- https://github.com/facebook/meta-wearables-dat-android/blob/main/CHANGELOG.md
- https://wearables.developer.meta.com/docs/ (login required in this session)
- https://docs.xreal.com/

VITURE, Vuzix and RealWear bindings remain research/implementation gates; these names are requested coverage targets, not verified compatibility claims.
