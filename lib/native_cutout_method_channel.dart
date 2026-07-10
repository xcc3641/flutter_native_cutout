import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'native_cutout.dart';
import 'native_cutout_platform_interface.dart';

/// An implementation of [NativeCutoutPlatform] that uses method channels.
class MethodChannelNativeCutout extends NativeCutoutPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('com.hugo/native_cutout');

  @visibleForTesting
  final progressEventChannel = const EventChannel(
    'com.hugo/native_cutout/download_progress',
  );

  @override
  Future<CutoutResult> removeBackground(
    String imagePath, {
    required CutoutOptions options,
  }) async {
    try {
      final result = await methodChannel.invokeMethod<Object>(
        'removeBackground',
        {'imagePath': imagePath, 'options': options.toMap()},
      );

      return switch (result) {
        // Native >= 0.3.0: map payload carrying path/bytes plus subjectBounds.
        Map map => _successFromMap(map),
        // Pre-0.3.0 native payloads.
        String path => CutoutFileSuccess(path),
        Uint8List bytes => CutoutBytesSuccess(bytes),
        _ => const CutoutFailure(
          CutoutErrorCode.processingFailed,
          'No result returned from native code',
        ),
      };
    } on PlatformException catch (e) {
      final code = _parseErrorCode(e.code);
      return CutoutFailure(code, e.message ?? 'Unknown error');
    }
  }

  CutoutResult _successFromMap(Map<Object?, Object?> map) {
    final bounds = _parseSubjectBounds(map['subjectBounds']);
    return switch ((map['path'], map['bytes'])) {
      (String path, _) => CutoutFileSuccess(path, subjectBounds: bounds),
      (_, Uint8List bytes) => CutoutBytesSuccess(bytes, subjectBounds: bounds),
      _ => const CutoutFailure(
        CutoutErrorCode.processingFailed,
        'Malformed result payload from native code',
      ),
    };
  }

  Rect? _parseSubjectBounds(Object? raw) {
    if (raw is! List || raw.length != 4) return null;
    final v = raw.cast<num>();
    final rect = Rect.fromLTWH(
      v[0].toDouble(),
      v[1].toDouble(),
      v[2].toDouble(),
      v[3].toDouble(),
    );
    return rect.isEmpty ? null : rect;
  }

  CutoutErrorCode _parseErrorCode(String code) {
    return switch (code) {
      'INVALID_INPUT' => CutoutErrorCode.invalidInput,
      'NO_SUBJECT' => CutoutErrorCode.noSubjectFound,
      _ => CutoutErrorCode.processingFailed,
    };
  }

  @override
  Future<bool> isModelAvailable() async {
    // iOS Vision framework is built-in, always available
    if (Platform.isIOS) return true;

    try {
      final result = await methodChannel.invokeMethod<bool>('isModelAvailable');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> downloadModel() async {
    // iOS Vision framework is built-in, no download needed
    if (Platform.isIOS) return true;

    try {
      final result = await methodChannel.invokeMethod<bool>('downloadModel');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> clearModel() async {
    // iOS Vision framework is built-in, no downloaded module to clear.
    if (Platform.isIOS) return true;

    try {
      final result = await methodChannel.invokeMethod<bool>('clearModel');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> clearCache() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('clearCache');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Stream<ModelDownloadProgress> get downloadProgress {
    if (Platform.isIOS) return const Stream.empty();
    return progressEventChannel.receiveBroadcastStream().map((event) {
      final map = (event as Map).cast<Object?, Object?>();
      return ModelDownloadProgress(
        state: _parseState(map['state'] as String?),
        bytesDownloaded: (map['bytesDownloaded'] as num?)?.toInt() ?? 0,
        totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
        errorCode: (map['errorCode'] as num?)?.toInt(),
      );
    });
  }

  ModelInstallState _parseState(String? s) => switch (s) {
    'pending' => ModelInstallState.pending,
    'downloading' => ModelInstallState.downloading,
    'downloadPaused' => ModelInstallState.downloadPaused,
    'installing' => ModelInstallState.installing,
    'completed' => ModelInstallState.completed,
    'canceled' => ModelInstallState.canceled,
    'failed' => ModelInstallState.failed,
    _ => ModelInstallState.unknown,
  };
}
