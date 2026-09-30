## 0.4.0

* Added an optional reveal animation, `CutoutRevealAnimation`, behind a separate entry point: `import 'package:native_cutout/cutout_reveal.dart'`. It is not exported from `native_cutout.dart`, so apps that only need background removal are unaffected, and it adds no dependencies.
* The animation sweeps two glowing pulses across the subject, zooms it out of a dimmed background, then breathes an outline glow. Pass `CutoutSuccess.subjectBounds` to position the pulses without an alpha scan. Tunable via `glowColor`, `backgroundColor`, `rippleSpeed`, `loop`, and `CutoutStrokeStyle`.
* Example app: added a Reveal button on the result page (disabled with `cropToSubject`).

## 0.3.0

* Added `CutoutSuccess.subjectBounds`: the subject's alpha bounding box in pixel coordinates of the returned image, computed natively during mask generation (iOS scans the Vision soft mask, Android reuses the bounds already tracked while applying the ML Kit mask). Consumers that need the subject's position or size no longer have to scan the decoded image's alpha channel in Dart — a full-resolution scan on the main isolate can block the UI thread for seconds on large photos and get reported as an app hang.
* With `cropToSubject: true` the returned image is the subject crop, so `subjectBounds` equals the full image rect.
* Method channel success payload changed from a bare `String`/bytes to a map (`path`/`bytes` + optional `subjectBounds`). The Dart layer still parses the old scalar payloads, so mixed versions fail soft (bounds become `null`).

## 0.2.0

* Lowered the iOS pod platform from 17.0 to 13.0 so consuming apps no longer need to raise their deployment target. Background removal still requires iOS 17 at runtime and now returns the `UNSUPPORTED_OS` error on older systems.
* Clarified Android ML Kit model delivery in the README: the segmentation model is not bundled and is downloaded by Google Play services on demand. First call to `removeBackground` will implicitly download the model when missing.
* Added Simplified Chinese translation (`README.zh-CN.md`) and a language switcher in the English README.
* Updated pubspec description to surface on-device processing, iOS 17 runtime requirement, and on-demand ML Kit model download.

## 0.1.0

* Initial release of the native Flutter background-removal plugin.
* iOS implementation powered by Vision Framework `VNGenerateForegroundInstanceMaskRequest` (iOS 17+).
* Android implementation powered by ML Kit Subject Segmentation.
* Added `CutoutOptions.cropToSubject` for optional subject-bound cropping.
* Added `CutoutOptions.writeToCache` with file-backed PNG output enabled by default.
* Added typed result models: `CutoutFileSuccess`, `CutoutBytesSuccess`, and `CutoutFailure`.
* Added cache cleanup via `NativeCutout.clearCache()`.
* Added Android model lifecycle APIs: `isModelAvailable()`, `downloadModel()`, `downloadProgress`, and `clearModel()`.
* Expanded the example app and README to cover model management, output modes, and result comparison.
