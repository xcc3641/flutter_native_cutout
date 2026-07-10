import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'native_cutout_platform_interface.dart';

/// Error codes for cutout operations.
enum CutoutErrorCode {
  /// The input image path is invalid or file doesn't exist.
  invalidInput,

  /// No subject/foreground was detected in the image.
  noSubjectFound,

  /// An error occurred during image processing.
  processingFailed,
}

/// Options for the cutout operation.
class CutoutOptions {
  /// Whether to crop the result to the subject bounds.
  final bool cropToSubject;

  /// When true (default) the native side writes the PNG to the app cache
  /// directory and returns a file path ([CutoutFileSuccess]).
  ///
  /// When false, raw PNG bytes are returned ([CutoutBytesSuccess]). Note that
  /// bytes round-trip across the method channel and are then decoded for
  /// display, so a 4000×3000 PNG can push peak memory past 100 MB. Prefer the
  /// cache path unless you specifically need bytes in Dart.
  final bool writeToCache;

  const CutoutOptions({
    this.cropToSubject = false,
    this.writeToCache = true,
  });

  Map<String, dynamic> toMap() => {
    'cropToSubject': cropToSubject,
    'writeToCache': writeToCache,
  };
}

/// Result of a cutout operation.
sealed class CutoutResult {
  const CutoutResult();
}

/// Successful cutout. Either file-backed or in-memory depending on
/// [CutoutOptions.writeToCache].
sealed class CutoutSuccess extends CutoutResult {
  /// Bounding box of the subject's non-transparent pixels, in pixel
  /// coordinates of the returned image.
  ///
  /// Computed natively during mask generation, so reading it costs nothing —
  /// use it instead of scanning the decoded image's alpha channel in Dart
  /// (a full-resolution scan on the main isolate can block the UI for
  /// seconds on large photos).
  ///
  /// When [CutoutOptions.cropToSubject] is true the returned image *is* the
  /// subject crop, so this equals the full image rect. Null when the native
  /// side could not determine the box.
  final Rect? subjectBounds;

  const CutoutSuccess({this.subjectBounds});
}

/// PNG was written to the app cache directory.
///
/// Use [path] with `Image.file`, or read the file as needed. The file lives
/// under the app cache directory and can be removed via
/// [NativeCutout.clearCache].
class CutoutFileSuccess extends CutoutSuccess {
  /// Absolute path to the PNG file on device storage.
  final String path;

  const CutoutFileSuccess(this.path, {super.subjectBounds});
}

/// PNG returned directly as bytes.
class CutoutBytesSuccess extends CutoutSuccess {
  /// The processed image with transparent background as PNG bytes.
  final Uint8List pngBytes;

  const CutoutBytesSuccess(this.pngBytes, {super.subjectBounds});
}

/// Failed cutout result containing error information.
class CutoutFailure extends CutoutResult {
  /// The error code indicating the type of failure.
  final CutoutErrorCode code;

  /// A human-readable error message.
  final String message;

  const CutoutFailure(this.code, this.message);

  @override
  String toString() => 'CutoutFailure($code: $message)';
}

/// Install state of the Android ML Kit model.
///
/// Mirrors Google Play Services `ModuleInstallStatusUpdate.InstallState`.
enum ModelInstallState {
  unknown,
  pending,
  downloading,
  downloadPaused,
  installing,
  completed,
  canceled,
  failed,
}

/// Snapshot of Android ML model download progress.
///
/// Emitted on [NativeCutout.downloadProgress] while [NativeCutout.downloadModel]
/// is running. iOS never emits events (Vision framework is bundled).
class ModelDownloadProgress {
  /// Current install state reported by Play Services.
  final ModelInstallState state;

  /// Bytes downloaded so far. May be 0 before the download actually starts.
  final int bytesDownloaded;

  /// Total bytes to download. May be 0 before the download actually starts.
  final int totalBytes;

  /// Play Services error code when [state] is [ModelInstallState.failed].
  final int? errorCode;

  const ModelDownloadProgress({
    required this.state,
    required this.bytesDownloaded,
    required this.totalBytes,
    this.errorCode,
  });

  /// Fraction downloaded in `[0, 1]`, or `null` when total size is unknown.
  double? get fraction => totalBytes > 0 ? bytesDownloaded / totalBytes : null;

  @override
  String toString() =>
      'ModelDownloadProgress($state, $bytesDownloaded/$totalBytes'
      '${errorCode != null ? ', err=$errorCode' : ''})';
}

/// AI-powered background removal using native platform APIs.
///
/// Uses iOS Vision Framework (iOS 17+) and Android ML Kit Subject Segmentation.
class NativeCutout {
  NativeCutout._();

  /// Removes the background from an image, keeping only the foreground subject.
  ///
  /// [imagePath] is the absolute path to the image file on the device.
  /// [options] allows customizing the cutout behavior.
  ///
  /// Returns a [CutoutResult] which is one of:
  /// - [CutoutFileSuccess] with a path to a cached PNG (default)
  /// - [CutoutBytesSuccess] with PNG bytes when `options.writeToCache` is false
  /// - [CutoutFailure] with error code and message
  ///
  /// Example:
  /// ```dart
  /// final result = await NativeCutout.removeBackground('/path/to/image.jpg');
  /// switch (result) {
  ///   case CutoutFileSuccess(:final path):
  ///     // Image.file(File(path))
  ///     break;
  ///   case CutoutBytesSuccess(:final pngBytes):
  ///     // Image.memory(pngBytes)
  ///     break;
  ///   case CutoutFailure(:final code, :final message):
  ///     // Handle error
  ///     break;
  /// }
  /// ```
  static Future<CutoutResult> removeBackground(
    String imagePath, {
    CutoutOptions? options,
  }) {
    return NativeCutoutPlatform.instance.removeBackground(
      imagePath,
      options: options ?? const CutoutOptions(),
    );
  }

  /// Deletes every PNG written to the app cache directory by this plugin.
  ///
  /// Safe to call while no cutout is in flight. Returns true on success.
  static Future<bool> clearCache() {
    return NativeCutoutPlatform.instance.clearCache();
  }

  /// Checks if the ML model is available and ready to use.
  ///
  /// On Android, the ML Kit subject segmentation model must be downloaded
  /// before use. Call [downloadModel] if this returns false.
  ///
  /// On iOS, this always returns true as the Vision framework is built-in.
  static Future<bool> isModelAvailable() {
    return NativeCutoutPlatform.instance.isModelAvailable();
  }

  /// Downloads the ML model required for background removal.
  ///
  /// On Android, this triggers the download of the ML Kit subject segmentation
  /// model from Google Play Services. The download happens in the background.
  ///
  /// On iOS, this is a no-op and always returns true.
  ///
  /// Returns true if the model is ready to use after this call.
  static Future<bool> downloadModel() {
    return NativeCutoutPlatform.instance.downloadModel();
  }

  /// Requests release of the downloaded Android ML Kit model.
  ///
  /// This delegates to Google Play services `releaseModules(...)`, so the
  /// behavior is best-effort and removal may not happen immediately. Use
  /// [isModelAvailable] afterwards to refresh the current availability state.
  ///
  /// On iOS, this is a no-op and always returns true.
  static Future<bool> clearModel() {
    return NativeCutoutPlatform.instance.clearModel();
  }

  /// Broadcast stream of download progress events while [downloadModel] runs.
  ///
  /// Only emits on Android. iOS returns an empty stream since the Vision
  /// framework is bundled with the system.
  static Stream<ModelDownloadProgress> get downloadProgress =>
      NativeCutoutPlatform.instance.downloadProgress;
}
