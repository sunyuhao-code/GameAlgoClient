# Changelog

## 1.0.0

- Android/iOS native SDK bindings for Unity, distributed as a UPM tarball.
- Configuration, strategies, DDA, native event tracking, attribution, device identifiers and foreground timing.
- Main-thread callback dispatch through Unity's synchronization context and a Getting Started sample.
- Android AARs and iOS device/simulator XCFrameworks, with automatic iOS export integration.

See `VALIDATION.md` for the tested scope and remaining Unity player checks.

- Verified with Unity 6.3 LTS Android/iOS IL2CPP players and Release minification on Android.
- Retains native TTL/session/queue/timing behavior; no Unity-level request timeout or event quota.
- Excludes the unused desktop runtime from the Unity download.
- Replaces mandatory Newtonsoft JSON with dependency-free JSON values and parsing;
  preserves 64-bit integers and Unicode without reflection-based object conversion.
- Adds compressed APK/device IPA size comparisons with a configurable byte budget.
- iOS bridge exports only its five C entry points, strips non-global symbols and
  compiles with Swift size optimization; native SDK reporting behavior is retained.
