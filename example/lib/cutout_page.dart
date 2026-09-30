import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:native_cutout/native_cutout.dart';

import 'reveal_page.dart';

class CutoutPage extends StatefulWidget {
  const CutoutPage({super.key, required this.imagePath});

  final String imagePath;

  @override
  State<CutoutPage> createState() => _CutoutPageState();
}

class _CutoutPageState extends State<CutoutPage> {
  CutoutSuccess? _success;
  bool _isProcessing = true;
  String? _errorMessage;

  int? _originalFileSize;
  Size? _originalDimensions;
  Size? _resultDimensions;
  int? _resultFileSize;
  Duration? _processingTime;
  bool _isSaving = false;
  bool _cropToSubject = false;
  bool _writeToCache = true;

  @override
  void initState() {
    super.initState();
    _loadOriginalAndRun();
  }

  Future<void> _loadOriginalAndRun() async {
    final file = File(widget.imagePath);
    _originalFileSize = await file.length();
    _originalDimensions = await _decodeDimensions(await file.readAsBytes());
    if (mounted) setState(() {});
    await _runCutout();
  }

  Future<void> _runCutout() async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
      _success = null;
      _resultDimensions = null;
      _resultFileSize = null;
      _processingTime = null;
    });

    final stopwatch = Stopwatch()..start();
    final result = await NativeCutout.removeBackground(
      widget.imagePath,
      options: CutoutOptions(
        cropToSubject: _cropToSubject,
        writeToCache: _writeToCache,
      ),
    );
    stopwatch.stop();

    if (!mounted) return;
    setState(() {
      _isProcessing = false;
      _processingTime = stopwatch.elapsed;
      switch (result) {
        case CutoutSuccess success:
          _success = success;
        case CutoutFailure(:final code, :final message):
          _errorMessage = '${code.name}: $message';
      }
    });

    final s = _success;
    if (s == null) return;

    final (provider, size) = switch (s) {
      CutoutFileSuccess(:final path) => (
        FileImage(File(path)) as ImageProvider,
        await File(path).length(),
      ),
      CutoutBytesSuccess(:final pngBytes) => (
        MemoryImage(pngBytes) as ImageProvider,
        pngBytes.length,
      ),
    };
    final dims = await _sizeFromProvider(provider);
    if (mounted) {
      setState(() {
        _resultDimensions = dims;
        _resultFileSize = size;
      });
    }
  }

  void _onCropToggle(bool value) {
    if (_isProcessing || value == _cropToSubject) return;
    _cropToSubject = value;
    _runCutout();
  }

  void _onWriteToCacheToggle(bool value) {
    if (_isProcessing || value == _writeToCache) return;
    _writeToCache = value;
    _runCutout();
  }

  Future<Size> _decodeDimensions(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final size = Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
    frame.image.dispose();
    return size;
  }

  Future<Size> _sizeFromProvider(ImageProvider provider) {
    final completer = Completer<Size>();
    late final ImageStreamListener listener;
    final stream = provider.resolve(ImageConfiguration.empty);
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) {
          completer.complete(
            Size(info.image.width.toDouble(), info.image.height.toDouble()),
          );
        }
        stream.removeListener(listener);
      },
      onError: (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  Future<void> _saveToGallery() async {
    final s = _success;
    if (s == null) return;
    setState(() => _isSaving = true);
    try {
      final name = 'cutout_${DateTime.now().millisecondsSinceEpoch}';
      switch (s) {
        case CutoutFileSuccess(:final path):
          await Gal.putImage(path);
        case CutoutBytesSuccess(:final pngBytes):
          await Gal.putImageBytes(pngBytes, name: name);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved to gallery'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  Widget _buildResultImage(CutoutSuccess success) {
    return switch (success) {
      CutoutFileSuccess(:final path) => Image.file(
        File(path),
        fit: BoxFit.contain,
        gaplessPlayback: true,
      ),
      CutoutBytesSuccess(:final pngBytes) => Image.memory(
        pngBytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      ),
    };
  }

  String _resultModeLabel(CutoutSuccess success) => switch (success) {
    CutoutFileSuccess() => 'cache file',
    CutoutBytesSuccess() => 'memory bytes',
  };

  @override
  Widget build(BuildContext context) {
    final success = _success;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Cutout Result'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _OptionSwitch(
              title: 'cropToSubject',
              subtitle: 'Crop output to the subject bounding box',
              value: _cropToSubject,
              enabled: !_isProcessing,
              onChanged: _onCropToggle,
            ),
            const SizedBox(height: 8),
            _OptionSwitch(
              title: 'writeToCache',
              subtitle:
                  'On: write PNG to cache, return path. '
                  'Off: return bytes in memory (careful with large images).',
              value: _writeToCache,
              enabled: !_isProcessing,
              onChanged: _onWriteToCacheToggle,
            ),
            const SizedBox(height: 12),
            if (_isProcessing)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Processing...'),
                    ],
                  ),
                ),
              ),
            if (_errorMessage != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            if (success != null && !_isProcessing) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_processingTime != null)
                      Text(
                        'Processing time: ${_processingTime!.inMilliseconds} ms',
                        style: Theme.of(
                          context,
                        ).textTheme.titleMedium?.copyWith(color: Colors.green),
                      ),
                    const SizedBox(width: 16),
                    ElevatedButton.icon(
                      onPressed: _isSaving ? null : _saveToGallery,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_alt),
                      label: Text(_isSaving ? 'Saving...' : 'Save'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      // The animation needs original and cutout at the same
                      // resolution, so it is unavailable for cropped output.
                      onPressed: _cropToSubject
                          ? null
                          : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => RevealPage(
                                    originalPath: widget.imagePath,
                                    success: success,
                                  ),
                                ),
                              ),
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Reveal'),
                    ),
                  ],
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        const Text(
                          'Before',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(widget.imagePath),
                            height: 250,
                            fit: BoxFit.contain,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _InfoCard(
                          title: 'Original',
                          lines: [
                            if (_originalDimensions != null)
                              '${_originalDimensions!.width.toInt()} × ${_originalDimensions!.height.toInt()}',
                            if (_originalFileSize != null)
                              _formatFileSize(_originalFileSize!),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      children: [
                        const Text(
                          'After',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            height: 250,
                            width: double.infinity,
                            child: CustomPaint(
                              painter: _CheckerboardPainter(),
                              child: _buildResultImage(success),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _InfoCard(
                          title: 'Result · ${_resultModeLabel(success)}',
                          lines: [
                            if (_resultDimensions != null)
                              '${_resultDimensions!.width.toInt()} × ${_resultDimensions!.height.toInt()}',
                            if (_resultFileSize != null)
                              _formatFileSize(_resultFileSize!),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (success is CutoutFileSuccess) ...[
                const SizedBox(height: 12),
                _PathCard(path: success.path),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _PathCard extends StatelessWidget {
  const _PathCard({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'Cache path',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              path,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionSwitch extends StatelessWidget {
  const _OptionSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckerboardPainter extends CustomPainter {
  static const _cellSize = 10.0;
  static final _light = Paint()..color = const Color(0xFFE0E0E0);
  static final _dark = Paint()..color = const Color(0xFFBDBDBD);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, _light);
    final cols = (size.width / _cellSize).ceil();
    final rows = (size.height / _cellSize).ceil();
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        if ((r + c).isOdd) {
          canvas.drawRect(
            Rect.fromLTWH(c * _cellSize, r * _cellSize, _cellSize, _cellSize),
            _dark,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerboardPainter oldDelegate) => false;
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
            ...lines.map(
              (t) => Text(t, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }
}
