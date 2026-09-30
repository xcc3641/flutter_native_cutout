# native_cutout

[![pub package](https://img.shields.io/pub/v/native_cutout.svg)](https://pub.dev/packages/native_cutout)
[![pub points](https://img.shields.io/pub/points/native_cutout)](https://pub.dev/packages/native_cutout/score)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-android%20%7C%20ios-blue.svg)](https://pub.dev/packages/native_cutout)

English | [简体中文](README.zh-CN.md)

Native background removal for Flutter using platform image segmentation APIs.

`native_cutout` removes the background from a local image file and produces a transparent PNG — fully on-device, with no external API, no upload step, and no API keys.

| Home · model manager | Cutout result |
| :---: | :---: |
| <img src="https://raw.githubusercontent.com/xcc3641/flutter_native_cutout/main/images/1.png" width="320" alt="Home page with Android model manager" /> | <img src="https://raw.githubusercontent.com/xcc3641/flutter_native_cutout/main/images/2.png" width="320" alt="Cutout result with cropToSubject and writeToCache toggles" /> |

It is built on top of:

- **iOS**: Vision Framework (`VNGenerateForegroundInstanceMaskRequest`)
- **Android**: Google ML Kit Subject Segmentation

## Features

- Fully **on-device** background removal
- Default **file-backed output** written to the app cache directory
- Optional **in-memory PNG bytes** output when you need bytes in Dart
- Native image processing on both iOS and Android
- Handles **EXIF orientation** before segmentation
- Optional subject-bound cropping via `CutoutOptions.cropToSubject`
- Cache management via `clearCache()`
- Android model lifecycle helpers: availability check, download, progress, and clear
- Simple Dart API with typed success/failure results
- Optional **reveal animation** (`CutoutRevealAnimation`) behind a separate import, with no extra dependencies

## Platform support

| Platform | Engine | Minimum version | Notes |
| --- | --- | --- | --- |
| iOS | Vision Framework | iOS 13.0 (compile) / iOS 17.0 (runtime) | Requires a **real device** for actual processing |
| Android | ML Kit Subject Segmentation | API 21+ | Segmentation model is downloaded by Google Play services on demand |

> **Important**
>
> - On **iOS Simulator**, foreground extraction is not available. Use a real iPhone or iPad.
> - On **Android**, the ML Kit model is **not bundled** in your APK. If it isn't already on the device, the first call to `removeBackground` will trigger an implicit download via Google Play services — that first call will block until the download completes and will fail when the device is offline. See [Android setup](#android-setup) for the recommended explicit warm-up flow.

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  native_cutout: ^0.4.0
```

Then run:

```bash
flutter pub get
```

## iOS setup

The plugin compiles against **iOS 13.0+** (Flutter's default), so it will not
raise your app's deployment target. At **runtime** the background-removal API
(`VNGenerateForegroundInstanceMaskRequest`) requires **iOS 17.0+** — on older
versions `removeBackground` returns the error code `UNSUPPORTED_OS`.

No `Podfile` changes are required. Just run pods as usual:

```bash
cd ios && pod install
```

## Android setup

The plugin supports **Android API 21+** and requires no manual `AndroidManifest.xml` changes.

### How the ML Kit model is delivered

This plugin uses the **unbundled** variant of ML Kit Subject Segmentation
(`play-services-mlkit-subject-segmentation`). The segmentation model is **not**
shipped inside your APK — it is delivered by Google Play services and lives
outside your app. There are two ways the model gets onto the device:

1. **Implicit download (default, lazy)** — the first call to
   `NativeCutout.removeBackground` on a device that does not yet have the model
   triggers an internal download inside ML Kit. The `removeBackground` future
   will not complete until the download finishes, which means:
   - The very first cutout on a fresh install will take noticeably longer
   - It will fail when the device is offline (typical error: `processingFailed`)
   - There is **no progress callback** during this implicit download — your UI
     can only show an indeterminate spinner

2. **Explicit warm-up (recommended)** — call `NativeCutout.downloadModel()`
   ahead of time (e.g. on app launch, or the first time the user opens the
   editor). This path streams progress through `NativeCutout.downloadProgress`,
   lets you render a real download UI, and removes the first-cutout latency
   spike.

See the [Recommended Android warm-up flow](#recommended-android-warm-up-flow)
below for code.

For testing, `NativeCutout.clearModel()` requests Google Play services to
release the downloaded module so you can re-exercise the first-download path.

## Quick start

### Default flow: return a cached PNG file path

By default, `native_cutout` writes the result PNG to the app cache directory and returns a file path.

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:native_cutout/native_cutout.dart';

final result = await NativeCutout.removeBackground(
  imagePath,
  options: const CutoutOptions(
    cropToSubject: true,
    writeToCache: true,
  ),
);

late final Widget preview;

switch (result) {
  case CutoutFileSuccess(:final path):
    preview = Image.file(File(path));
    break;
  case CutoutBytesSuccess(:final pngBytes):
    preview = Image.memory(pngBytes);
    break;
  case CutoutFailure(:final code, :final message):
    debugPrint('Cutout failed: ${code.name} - $message');
    return;
}
```

### In-memory flow: return PNG bytes directly

If you explicitly need raw bytes in Dart, disable cache writing:

```dart
final result = await NativeCutout.removeBackground(
  imagePath,
  options: const CutoutOptions(writeToCache: false),
);
```

## Recommended Android warm-up flow

If you want a more reliable first-run experience on Android, check the model before processing:

```dart
final isReady = await NativeCutout.isModelAvailable();

if (!isReady) {
  final downloaded = await NativeCutout.downloadModel();
  if (!downloaded) {
    debugPrint('ML Kit model download failed');
    return;
  }
}

final result = await NativeCutout.removeBackground(imagePath);
```

If you want to surface download progress in your UI:

```dart
final sub = NativeCutout.downloadProgress.listen((progress) {
  debugPrint('state=${progress.state} fraction=${progress.fraction}');
});

final ok = await NativeCutout.downloadModel();
await sub.cancel();
```

If you need to re-test the first-download flow on Android:

```dart
await NativeCutout.clearModel();
final isStillAvailable = await NativeCutout.isModelAvailable();
debugPrint('available after clear: $isStillAvailable');
```

If you are using cached file output, you can also clear old generated PNGs:

```dart
await NativeCutout.clearCache();
```

On iOS:

- `isModelAvailable()` always returns `true`
- `downloadModel()` is a no-op and returns `true`
- `clearModel()` is a no-op and returns `true`

## API overview

### `NativeCutout.removeBackground`

Removes the background from a local image file.

```dart
Future<CutoutResult> NativeCutout.removeBackground(
  String imagePath, {
  CutoutOptions? options,
})
```

Parameters:

- `imagePath`: absolute path to a local image file on device storage
- `options`: optional cutout configuration

Returns:

- `CutoutFileSuccess` with a cached PNG file path (default)
- `CutoutBytesSuccess` with PNG bytes when `writeToCache` is `false`
- `CutoutFailure` with `code` and `message`

### `CutoutOptions`

```dart
const CutoutOptions(
  cropToSubject: false,
  writeToCache: true,
)
```

Available fields:

- `cropToSubject`: when `true`, trims transparent margins and returns a tight subject crop; when `false`, preserves the original image canvas size
- `writeToCache`: when `true` (default), writes the PNG to the app cache directory and returns `CutoutFileSuccess`; when `false`, returns `CutoutBytesSuccess`

### `NativeCutout.clearCache`

Deletes PNG files previously written by the plugin into the app cache directory.

```dart
Future<bool> NativeCutout.clearCache()
```

### `NativeCutout.isModelAvailable`

Checks whether the native model/runtime is ready to use.

```dart
Future<bool> NativeCutout.isModelAvailable()
```

### `NativeCutout.downloadModel`

Triggers download of the Android ML Kit segmentation module when needed.

```dart
Future<bool> NativeCutout.downloadModel()
```

### `NativeCutout.clearModel`

Requests release of the downloaded Android ML Kit module.

```dart
Future<bool> NativeCutout.clearModel()
```

> **Note**
>
> On Android this delegates to Google Play services `releaseModules(...)`, which is a **best-effort** request. The model may not disappear immediately, so call `isModelAvailable()` again to refresh the current state.

### `NativeCutout.downloadProgress`

Broadcast stream of Android model download progress events.

```dart
Stream<ModelDownloadProgress> get NativeCutout.downloadProgress
```

Notes:

- Only emits on Android while `downloadModel()` is running
- Returns an empty stream on iOS
- Each event includes `state`, `bytesDownloaded`, `totalBytes`, `errorCode`, and computed `fraction`

## Result types

### `CutoutSuccess.subjectBounds`

Every success carries the subject's bounding box, computed natively during
mask generation:

```dart
sealed class CutoutSuccess extends CutoutResult {
  /// Bounding box of the subject's non-transparent pixels, in pixel
  /// coordinates of the returned image. Null when it could not be determined.
  final Rect? subjectBounds;
}
```

Use it whenever you need the subject's position or size (e.g. to center an
animation on the subject). It is free to read — do **not** decode the PNG and
scan its alpha channel in Dart for this: a full-resolution scan on the main
isolate can block the UI thread for seconds on large photos.

With `cropToSubject: true` the returned image *is* the subject crop, so
`subjectBounds` equals the full image rect.

### `CutoutFileSuccess`

Successful result containing a cached PNG path:

```dart
class CutoutFileSuccess extends CutoutSuccess {
  final String path;
}
```

### `CutoutBytesSuccess`

Successful result containing in-memory PNG bytes:

```dart
class CutoutBytesSuccess extends CutoutSuccess {
  final Uint8List pngBytes;
}
```

### `CutoutFailure`

Failed result containing a typed error code and readable message:

```dart
class CutoutFailure extends CutoutResult {
  final CutoutErrorCode code;
  final String message;
}
```

## Error codes

| Error code | Meaning |
| --- | --- |
| `invalidInput` | The image path is missing, invalid, or the file could not be decoded |
| `noSubjectFound` | No clear foreground subject was detected in the image |
| `processingFailed` | Native processing failed for another reason |

## Output behavior

- The output is always a **PNG with transparent background**
- By default, the plugin writes the PNG to the app cache directory and returns a file path
- If `writeToCache` is `false`, the plugin returns PNG bytes in memory
- The background is made transparent
- Transparent borders are trimmed only when `cropToSubject` is set to `true`
- Cached PNGs can be removed with `NativeCutout.clearCache()`

## Best results

For the highest-quality cutout:

- Use images with a **clear foreground subject**
- Prefer images where the subject is visually separated from the background
- Avoid heavily blurred, extremely dark, or very low-resolution inputs

## Limitations

- Input must be a **local file path**
- iOS processing requires **iOS 17+** and a **real device**
- Android requires Google Play services and an **initial model download** (implicit on first use, or explicit via `downloadModel()`); the first call is **offline-unfriendly** if the model isn't already cached
- The quality of the result depends on the platform segmentation engine and source image quality

## Optional: reveal animation

The package ships an opt-in "pop-out" animation for presenting a result. It lives in a separate library, is not exported from `native_cutout.dart`, and adds no dependencies — import it only if you want it:

```dart
import 'package:native_cutout/cutout_reveal.dart';

// originalImage / cutoutImage: decoded ui.Image of the source photo and the
// cutout PNG. They must share the same resolution, so run the cutout with
// cropToSubject: false.
CutoutRevealAnimation(
  originalImage: originalImage,
  cutoutImage: cutoutImage,
  subjectBounds: success.subjectBounds, // skips the fallback alpha scan
  onCompleted: () {/* hold on the final frame or navigate */},
)
```

Timeline (default `rippleSpeed: 1.5`, about 2.4 s): two glowing pulses sweep across the subject, the subject zooms to 1.1× over a dimmed background, then its outline glow breathes once. With `loop: false` it holds on the final frame.

| Parameter | Default | Description |
| --- | --- | --- |
| `loop` | `false` | Repeat instead of playing once |
| `rippleSpeed` | `1.5` | Pulse phase speed multiplier (0.1–8.0) |
| `glowColor` | `#FFE200` | Pulse and outline glow color |
| `backgroundColor` | `#6A6A6A` | Fill behind the images |
| `strokeStyle` | `CutoutStrokeStyle()` | Outline width, blur, and halo layers |

The widget does not dispose the `ui.Image`s you pass in.

## Example app

The [`example/`](example/) app in this repository demonstrates:

- picking an image from the gallery
- checking/downloading the Android model
- observing Android model download progress
- clearing the Android model and refreshing availability for repeat testing
- running background removal
- toggling `cropToSubject` on the result page
- toggling `writeToCache` to compare cache-file vs memory-bytes output
- previewing before/after results
- comparing cached-file output dimensions with the original image
- saving the transparent PNG output
- playing the optional reveal animation on an uncropped result

## License

MIT
