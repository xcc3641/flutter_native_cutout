import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:native_cutout/cutout_reveal.dart';
import 'package:native_cutout/native_cutout.dart';

/// Plays [CutoutRevealAnimation] for an uncropped cutout result.
class RevealPage extends StatefulWidget {
  const RevealPage({
    super.key,
    required this.originalPath,
    required this.success,
  });

  final String originalPath;
  final CutoutSuccess success;

  @override
  State<RevealPage> createState() => _RevealPageState();
}

class _RevealPageState extends State<RevealPage> {
  ui.Image? _original;
  ui.Image? _cutout;
  int _playKey = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cutoutBytes = switch (widget.success) {
      CutoutFileSuccess(:final path) => await File(path).readAsBytes(),
      CutoutBytesSuccess(:final pngBytes) => pngBytes,
    };
    final original = await _decode(await File(widget.originalPath).readAsBytes());
    final cutout = await _decode(cutoutBytes);
    if (!mounted) {
      original.dispose();
      cutout.dispose();
      return;
    }
    setState(() {
      _original = original;
      _cutout = cutout;
    });
  }

  Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  @override
  void dispose() {
    _original?.dispose();
    _cutout?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final original = _original;
    final cutout = _cutout;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reveal Animation'),
        actions: [
          IconButton(
            icon: const Icon(Icons.replay),
            onPressed: () => setState(() => _playKey++),
          ),
        ],
      ),
      body: original == null || cutout == null
          ? const Center(child: CircularProgressIndicator())
          : CutoutRevealAnimation(
              key: ValueKey(_playKey),
              originalImage: original,
              cutoutImage: cutout,
              subjectBounds: widget.success.subjectBounds,
            ),
    );
  }
}
