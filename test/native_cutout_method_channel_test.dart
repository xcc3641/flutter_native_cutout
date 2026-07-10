import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_cutout/native_cutout.dart';
import 'package:native_cutout/native_cutout_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelNativeCutout', () {
    late MethodChannelNativeCutout platform;
    late List<MethodCall> calls;

    setUp(() {
      platform = MethodChannelNativeCutout();
      calls = <MethodCall>[];
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform.methodChannel, null);
    });

    test('removeBackground with writeToCache=false returns bytes', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform.methodChannel, (call) async {
            calls.add(call);
            return Uint8List.fromList([1, 2, 3]);
          });

      final result = await platform.removeBackground(
        '/tmp/photo.jpg',
        options: const CutoutOptions(
          cropToSubject: true,
          writeToCache: false,
        ),
      );

      expect(calls, hasLength(1));
      expect(calls.single.method, 'removeBackground');
      expect(calls.single.arguments, <String, dynamic>{
        'imagePath': '/tmp/photo.jpg',
        'options': <String, dynamic>{
          'cropToSubject': true,
          'writeToCache': false,
        },
      });

      expect(result, isA<CutoutBytesSuccess>());
      expect((result as CutoutBytesSuccess).pngBytes, [1, 2, 3]);
    });

    test('removeBackground with default options returns path', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform.methodChannel, (call) async {
            calls.add(call);
            return '/tmp/cache/cutout.png';
          });

      final result = await platform.removeBackground(
        '/tmp/photo.jpg',
        options: const CutoutOptions(),
      );

      expect(calls.single.arguments, <String, dynamic>{
        'imagePath': '/tmp/photo.jpg',
        'options': <String, dynamic>{
          'cropToSubject': false,
          'writeToCache': true,
        },
      });

      expect(result, isA<CutoutFileSuccess>());
      expect((result as CutoutFileSuccess).path, '/tmp/cache/cutout.png');
    });

    test('parses map payload with path and subjectBounds', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform.methodChannel, (call) async {
            return <String, Object?>{
              'path': '/tmp/cache/cutout.png',
              'subjectBounds': [10, 20, 100, 200],
            };
          });

      final result = await platform.removeBackground(
        '/tmp/photo.jpg',
        options: const CutoutOptions(),
      );

      expect(result, isA<CutoutFileSuccess>());
      final success = result as CutoutFileSuccess;
      expect(success.path, '/tmp/cache/cutout.png');
      expect(success.subjectBounds, const Rect.fromLTWH(10, 20, 100, 200));
    });

    test('parses map payload with bytes and subjectBounds', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform.methodChannel, (call) async {
            return <String, Object?>{
              'bytes': Uint8List.fromList([1, 2, 3]),
              'subjectBounds': [0, 0, 50, 60],
            };
          });

      final result = await platform.removeBackground(
        '/tmp/photo.jpg',
        options: const CutoutOptions(writeToCache: false),
      );

      expect(result, isA<CutoutBytesSuccess>());
      final success = result as CutoutBytesSuccess;
      expect(success.pngBytes, [1, 2, 3]);
      expect(success.subjectBounds, const Rect.fromLTWH(0, 0, 50, 60));
    });

    test('map payload without subjectBounds yields null bounds', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform.methodChannel, (call) async {
            return <String, Object?>{'path': '/tmp/cache/cutout.png'};
          });

      final result = await platform.removeBackground(
        '/tmp/photo.jpg',
        options: const CutoutOptions(),
      );

      expect((result as CutoutFileSuccess).subjectBounds, isNull);
    });

    test('malformed or empty subjectBounds yields null bounds', () async {
      for (final bounds in [
        [1, 2, 3], // wrong length
        [0, 0, 0, 100], // zero width
        'nonsense', // wrong type
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(platform.methodChannel, (call) async {
              return <String, Object?>{
                'path': '/tmp/cache/cutout.png',
                'subjectBounds': bounds,
              };
            });

        final result = await platform.removeBackground(
          '/tmp/photo.jpg',
          options: const CutoutOptions(),
        );

        expect(
          (result as CutoutFileSuccess).subjectBounds,
          isNull,
          reason: 'bounds: $bounds',
        );
      }
    });

    test('legacy scalar payloads still parse (old native code)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            platform.methodChannel,
            (call) async => '/tmp/cache/legacy.png',
          );

      final result = await platform.removeBackground(
        '/tmp/photo.jpg',
        options: const CutoutOptions(),
      );

      final success = result as CutoutFileSuccess;
      expect(success.path, '/tmp/cache/legacy.png');
      expect(success.subjectBounds, isNull);
    });

    test('maps NO_SUBJECT platform errors to noSubjectFound', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform.methodChannel, (call) async {
            throw PlatformException(code: 'NO_SUBJECT', message: 'No subject');
          });

      final result = await platform.removeBackground(
        '/tmp/photo.jpg',
        options: const CutoutOptions(),
      );

      expect(result, isA<CutoutFailure>());
      final failure = result as CutoutFailure;
      expect(failure.code, CutoutErrorCode.noSubjectFound);
      expect(failure.message, 'No subject');
    });

    test('returns processingFailed when native result is null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            platform.methodChannel,
            (call) async => null,
          );

      final result = await platform.removeBackground(
        '/tmp/photo.jpg',
        options: const CutoutOptions(),
      );

      expect(result, isA<CutoutFailure>());
      final failure = result as CutoutFailure;
      expect(failure.code, CutoutErrorCode.processingFailed);
    });

    test('clearModel forwards the method call', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform.methodChannel, (call) async {
            calls.add(call);
            return true;
          });

      final result = await platform.clearModel();

      expect(result, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'clearModel');
    });

    test('clearCache forwards the method call', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform.methodChannel, (call) async {
            calls.add(call);
            return true;
          });

      final result = await platform.clearCache();

      expect(result, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'clearCache');
    });
  });
}
