import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const _kDefaultGlowColor = Color(0xFFFFE200);
const _kDefaultBackgroundColor = Color(0xFF6A6A6A);

/// Pulse path size at start / end, as a multiple of the subject's long side.
/// Growth ratio = end / start, played over one pulse duration.
const _kPathStartOverSubject = 0.10;
const _kPathEndOverSubject = 2.0;

/// Assumed subject long-side ratio until the real one is known.
const _kFallbackSubjectRatio = 0.40;

const _kPathGlow = 3.1;
const _kPathWhiteRatio = 1.7 / 3.1;

/// Pulse duration and the offset between the two pulses at speed 1.0.
/// Both scale with [CutoutRevealAnimation.rippleSpeed].
const _kPathDurMs = 1400;
const _kPathOffsetMs = 300;

/// Zoom starts this long before the second pulse ends.
const _kZoomLeadMs = 200;
const _kZoomDurMs = 500;
const _kZoomScaleMax = 1.10;
const _kZoomOverlayAlpha = 0.4;
const _kBreathCycleMs = 1000;
const _kBreathCycles = 1;

/// Longest-side cap for the fallback alpha scan. Output is a normalized ratio,
/// so 1/256 precision is plenty.
const _kMetricsScanLongSide = 256;

/// Style of the glowing outline that traces the subject in the final phase.
///
/// Smaller blur values or fewer layers give a sharper line.
class CutoutStrokeStyle {
  /// Stroke width in logical pixels (dilation radius).
  final double strokeWidth;

  /// Gaussian blur sigma of the colored glow — the main source of softness.
  final double glowBlur;

  /// Gaussian blur sigma of the white halo.
  final double whiteBlur;

  /// How many white halo layers are stacked. More layers look brighter.
  final int whiteLayerCount;

  const CutoutStrokeStyle({
    this.strokeWidth = 1.0,
    this.glowBlur = 3.1,
    this.whiteBlur = 1.7,
    this.whiteLayerCount = 1,
  });

  CutoutStrokeStyle copyWith({
    double? strokeWidth,
    double? glowBlur,
    double? whiteBlur,
    int? whiteLayerCount,
  }) {
    return CutoutStrokeStyle(
      strokeWidth: strokeWidth ?? this.strokeWidth,
      glowBlur: glowBlur ?? this.glowBlur,
      whiteBlur: whiteBlur ?? this.whiteBlur,
      whiteLayerCount: whiteLayerCount ?? this.whiteLayerCount,
    );
  }
}

/// Timeline boundaries (ms) of one full play. Pulse duration / offset scale
/// with ripple speed; zoom and breath durations are fixed.
class _Timeline {
  final double pathDurMs;
  final double pathOffsetMs;
  const _Timeline({required this.pathDurMs, required this.pathOffsetMs});

  factory _Timeline.forSpeed(double speed) => _Timeline(
        pathDurMs: _kPathDurMs / speed,
        pathOffsetMs: _kPathOffsetMs / speed,
      );

  double get path1End => pathDurMs;
  double get path2Start => pathOffsetMs;
  double get path2End => pathOffsetMs + pathDurMs;
  double get zoomStart => path2End - _kZoomLeadMs;
  double get zoomEnd => zoomStart + _kZoomDurMs;
  double get breathStart => zoomEnd;
  double get cycleMs => breathStart + _kBreathCycleMs * _kBreathCycles;
}

/// Subject geometry inside the cutout image.
class _SubjectMetrics {
  /// Subject center offset from the image center, normalized to -1..1.
  final Alignment alignment;

  /// Bounding-box long side / image long side.
  final double longSideRatio;

  const _SubjectMetrics(this.alignment, this.longSideRatio);

  factory _SubjectMetrics.fromBounds(ui.Rect bounds, int w, int h) {
    final imgLong = (w > h ? w : h).toDouble();
    return _SubjectMetrics(
      Alignment(
        (2 * bounds.center.dx / w) - 1,
        (2 * bounds.center.dy / h) - 1,
      ),
      bounds.longestSide / imgLong,
    );
  }
}

/// Scans [image]'s alpha channel for the subject bounding box. Returns null
/// when fully transparent or unreadable.
///
/// Runs on the main isolate, so the image is first downscaled to at most
/// [_kMetricsScanLongSide] on its long side — a full-resolution scan of a
/// 12 MP photo can block the UI thread for seconds.
Future<_SubjectMetrics?> _scanSubjectMetrics(ui.Image image) async {
  final srcW = image.width;
  final srcH = image.height;
  final srcLong = srcW > srcH ? srcW : srcH;

  var scanImage = image;
  var ownsScanImage = false;
  if (srcLong > _kMetricsScanLongSide) {
    final scale = _kMetricsScanLongSide / srcLong;
    final sw = (srcW * scale).round().clamp(1, srcW);
    final sh = (srcH * scale).round().clamp(1, srcH);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble()),
      Rect.fromLTWH(0, 0, sw.toDouble(), sh.toDouble()),
      Paint()..filterQuality = FilterQuality.low,
    );
    final picture = recorder.endRecording();
    scanImage = await picture.toImage(sw, sh);
    picture.dispose();
    ownsScanImage = true;
  }

  try {
    final byteData =
        await scanImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;
    final bytes = byteData.buffer.asUint8List();
    final w = scanImage.width;
    final h = scanImage.height;
    int minX = w, minY = h, maxX = -1, maxY = -1;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (bytes[(y * w + x) * 4 + 3] > 0) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) return null;
    return _SubjectMetrics.fromBounds(
      Rect.fromLTRB(
        minX.toDouble(),
        minY.toDouble(),
        (maxX + 1).toDouble(),
        (maxY + 1).toDouble(),
      ),
      w,
      h,
    );
  } finally {
    if (ownsScanImage) scanImage.dispose();
  }
}

/// Optional "pop-out" reveal animation for a cutout result.
///
/// Not exported from `package:native_cutout/native_cutout.dart`; import
/// `package:native_cutout/cutout_reveal.dart` to opt in. Adds no dependencies.
///
/// [originalImage] and [cutoutImage] must have the same resolution (run the
/// cutout with `cropToSubject: false`), so that under `BoxFit.contain` the
/// subject pixels line up and the first frame looks like the original photo.
///
/// Timeline at `rippleSpeed: 1.0` (3000 ms total):
/// - 0..1700 ms: two glowing pulses sweep across the subject (300 ms apart)
/// - 1500..2000 ms: subject scales 1.0 → 1.10, background dims to 40%
/// - 2000..3000 ms: outline glow breathes once
///
/// With [loop] false it plays once, holds on the zoomed and dimmed frame, then
/// calls [onCompleted]. The widget does not dispose the images it is given.
class CutoutRevealAnimation extends StatefulWidget {
  final ui.Image originalImage;
  final ui.Image cutoutImage;
  final bool loop;
  final VoidCallback? onCompleted;

  /// Fill behind the images (visible in letterbox areas).
  final Color backgroundColor;

  /// Color of the pulse glow and the outline glow.
  final Color glowColor;

  final CutoutStrokeStyle strokeStyle;

  /// Pulse speed multiplier. >1 is faster. Only the pulse phase is scaled;
  /// zoom and breath durations stay fixed. Clamped to 0.1..8.0.
  final double rippleSpeed;

  /// Subject bounding box in [cutoutImage] pixel coordinates — pass
  /// `CutoutSuccess.subjectBounds`. When null, a downscaled alpha scan is used.
  final ui.Rect? subjectBounds;

  const CutoutRevealAnimation({
    super.key,
    required this.originalImage,
    required this.cutoutImage,
    this.loop = false,
    this.onCompleted,
    this.backgroundColor = _kDefaultBackgroundColor,
    this.glowColor = _kDefaultGlowColor,
    this.strokeStyle = const CutoutStrokeStyle(),
    this.rippleSpeed = 1.5,
    this.subjectBounds,
  });

  @override
  State<CutoutRevealAnimation> createState() => _CutoutRevealAnimationState();
}

class _CutoutRevealAnimationState extends State<CutoutRevealAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late _Timeline _timeline;
  _SubjectMetrics? _scannedMetrics;

  /// Bumped on every scan request so stale results are dropped.
  int _scanGeneration = 0;

  // Upper bound 8.0: faster makes path2End < _kZoomLeadMs, so zoom would start
  // at a negative time.
  _Timeline _timelineFor(double speed) =>
      _Timeline.forSpeed(speed.clamp(0.1, 8.0));

  @override
  void initState() {
    super.initState();
    _timeline = _timelineFor(widget.rippleSpeed);
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _timeline.cycleMs.round()),
    )..addStatusListener(_onStatus);
    _play();
    _maybeScan();
  }

  @override
  void didUpdateWidget(CutoutRevealAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rippleSpeed != widget.rippleSpeed) {
      _timeline = _timelineFor(widget.rippleSpeed);
      _controller.duration = Duration(milliseconds: _timeline.cycleMs.round());
      if (widget.loop) _controller.repeat();
    }
    if (oldWidget.loop != widget.loop) _play();
    if (oldWidget.cutoutImage != widget.cutoutImage ||
        oldWidget.subjectBounds != widget.subjectBounds) {
      _scannedMetrics = null;
      _maybeScan();
    }
  }

  void _play() {
    if (widget.loop) {
      _controller.repeat();
    } else {
      _controller.forward(from: 0);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (!widget.loop && status == AnimationStatus.completed) {
      widget.onCompleted?.call();
    }
  }

  Future<void> _maybeScan() async {
    if (widget.subjectBounds != null) return;
    final generation = ++_scanGeneration;
    final metrics = await _scanSubjectMetrics(widget.cutoutImage);
    if (!mounted || generation != _scanGeneration) return;
    setState(() => _scannedMetrics = metrics);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bounds = widget.subjectBounds;
    final metrics = bounds != null
        ? _SubjectMetrics.fromBounds(
            bounds, widget.cutoutImage.width, widget.cutoutImage.height)
        : _scannedMetrics;
    final pathAlignment = metrics?.alignment ?? Alignment.center;
    final subjectRatio = metrics?.longSideRatio ?? _kFallbackSubjectRatio;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => _buildFrame(
        _controller.value * _timeline.cycleMs,
        pathAlignment,
        subjectRatio * _kPathEndOverSubject,
      ),
    );
  }

  Widget _buildFrame(double ms, Alignment pathAlignment, double endSizeRatio) {
    final tl = _timeline;
    var path1T = 0.0;
    var path2T = 0.0;
    var zoomT = 0.0;
    var breathT = 0.0;
    if (ms < tl.path1End) {
      path1T = (ms / tl.pathDurMs).clamp(0.0, 1.0);
    }
    if (ms >= tl.path2Start && ms < tl.path2End) {
      path2T = ((ms - tl.path2Start) / tl.pathDurMs).clamp(0.0, 1.0);
    }
    if (ms >= tl.zoomEnd) {
      zoomT = 1.0;
    } else if (ms >= tl.zoomStart) {
      zoomT = (ms - tl.zoomStart) / _kZoomDurMs;
    }
    final zoomEased = Curves.easeOut.transform(zoomT.clamp(0.0, 1.0));
    final scale = 1.0 + (_kZoomScaleMax - 1.0) * zoomEased;
    final overlayOpacity = _kZoomOverlayAlpha * zoomEased;
    if (ms >= tl.breathStart) {
      final phase =
          ((ms - tl.breathStart) % _kBreathCycleMs) / _kBreathCycleMs;
      final tri = phase < 0.5 ? phase * 2 : 2 - phase * 2;
      breathT = Curves.easeInOut.transform(tri);
    }

    final cutout = widget.cutoutImage;
    return ClipRect(
      child: ColoredBox(
        color: widget.backgroundColor,
        child: Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            Transform.scale(
              scale: scale,
              child: FittedBox(
                fit: BoxFit.contain,
                child: RawImage(image: widget.originalImage),
              ),
            ),
            if (overlayOpacity > 0)
              IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: overlayOpacity),
                ),
              ),
            Transform.scale(
              scale: scale,
              child: Stack(
                alignment: Alignment.center,
                fit: StackFit.expand,
                children: [
                  Opacity(
                    opacity: breathT.clamp(0.0, 1.0),
                    child: _SubjectStrokeBorder(
                      image: cutout,
                      style: widget.strokeStyle,
                      glowColor: widget.glowColor,
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.contain,
                    child: RawImage(image: cutout),
                  ),
                  _ImageMask(
                    image: cutout,
                    child: _PathPulseLayer(
                      path1T: path1T,
                      path2T: path2T,
                      glowColor: widget.glowColor,
                      alignment: pathAlignment,
                      endSizeRatio: endSizeRatio,
                      startScale: _kPathStartOverSubject / _kPathEndOverSubject,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `BoxFit.contain` destination rect of an [imgW]×[imgH] image in [bounds].
Rect _containRect(Rect bounds, double imgW, double imgH) {
  final scale = (bounds.width / imgW < bounds.height / imgH)
      ? bounds.width / imgW
      : bounds.height / imgH;
  final dstW = imgW * scale;
  final dstH = imgH * scale;
  return Rect.fromLTWH(
    bounds.left + (bounds.width - dstW) / 2,
    bounds.top + (bounds.height - dstH) / 2,
    dstW,
    dstH,
  );
}

class _SubjectStrokeBorder extends StatelessWidget {
  final ui.Image image;
  final CutoutStrokeStyle style;
  final Color glowColor;
  const _SubjectStrokeBorder({
    required this.image,
    required this.style,
    required this.glowColor,
  });

  Widget _layer(double blur, Color color) => ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _OuterStrokePainter(
              image: image,
              strokeWidth: style.strokeWidth,
              color: color,
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final whiteLayer = _layer(style.whiteBlur, Colors.white);
    return Stack(
      fit: StackFit.expand,
      children: [
        _layer(style.glowBlur, glowColor),
        for (int i = 0; i < style.whiteLayerCount; i++) whiteLayer,
      ],
    );
  }
}

/// Paints a `strokeWidth`-px outer stroke along the image's alpha edge:
/// 1) draw the silhouette shifted in 8 compass directions (dilation)
/// 2) subtract the original silhouette via dstOut, leaving the outer ring
class _OuterStrokePainter extends CustomPainter {
  final ui.Image image;
  final double strokeWidth;
  final Color color;
  _OuterStrokePainter({
    required this.image,
    required this.strokeWidth,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    final dst = _containRect(Offset.zero & size, imgW, imgH);
    final src = Rect.fromLTWH(0, 0, imgW, imgH);

    final s = strokeWidth;
    final d = s * 0.70710678; // sqrt(2)/2 for diagonals
    final shifts = <Offset>[
      Offset(s, 0), Offset(-s, 0), Offset(0, s), Offset(0, -s),
      Offset(d, d), Offset(d, -d), Offset(-d, d), Offset(-d, -d),
    ];

    canvas.saveLayer(Offset.zero & size, Paint());
    final fillPaint = Paint()
      ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn);
    for (final off in shifts) {
      canvas.drawImageRect(image, src, dst.shift(off), fillPaint);
    }
    canvas.drawImageRect(image, src, dst, Paint()..blendMode = BlendMode.dstOut);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OuterStrokePainter old) =>
      old.image != image ||
      old.strokeWidth != strokeWidth ||
      old.color != color;
}

/// Clips [child] to the alpha of [image] laid out with `BoxFit.contain`.
class _ImageMask extends StatelessWidget {
  final ui.Image image;
  final Widget child;
  const _ImageMask({required this.image, required this.child});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final imgW = image.width.toDouble();
        final imgH = image.height.toDouble();
        final dst = _containRect(rect, imgW, imgH);
        final scale = dst.width / imgW;
        final matrix = Matrix4.identity()
          ..translateByDouble(dst.left, dst.top, 0, 1)
          ..scaleByDouble(scale, scale, 1, 1);
        return ImageShader(image, TileMode.clamp, TileMode.clamp, matrix.storage);
      },
      child: child,
    );
  }
}

class _PathPulseLayer extends StatelessWidget {
  final double path1T;
  final double path2T;
  final Color glowColor;

  /// Pulse origin, aligned to the subject center.
  final Alignment alignment;

  /// Final pulse size as a multiple of the layer's long side.
  final double endSizeRatio;

  /// Starting `Transform.scale` value of a pulse.
  final double startScale;

  const _PathPulseLayer({
    required this.path1T,
    required this.path2T,
    required this.glowColor,
    required this.alignment,
    required this.endSizeRatio,
    required this.startScale,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final finalSize = (w > h ? w : h) * endSizeRatio;
        return Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            for (final (t, shape) in [
              (path1T, _PulseShape.wide),
              (path2T, _PulseShape.tall),
            ])
              _PulseBlob(
                localT: t,
                shape: shape,
                glowColor: glowColor,
                finalSize: finalSize,
                alignment: alignment,
                startScale: startScale,
              ),
          ],
        );
      },
    );
  }
}

/// The two organic blob outlines swept across the subject.
enum _PulseShape {
  wide(Size(194, 177)),
  tall(Size(177, 194));

  const _PulseShape(this.viewBox);

  final Size viewBox;

  Path get path => switch (this) {
        _PulseShape.wide => Path()
          ..moveTo(191.031, 91.1161)
          ..cubicTo(192.319, 110.109, 197.002, 129.645, 184.886, 140.45)
          ..cubicTo(172.77, 151.254, 147.597, 142.487, 130.451, 145.139)
          ..cubicTo(113.306, 147.79, 115.244, 147.55, 99.1603, 153.709)
          ..cubicTo(83.0764, 159.868, 69.5948, 177.195, 50.0316, 175.935)
          ..cubicTo(30.4684, 174.674, 5.30694, 164.371, 1.3445, 147.408)
          ..cubicTo(-2.61794, 130.444, 28.9067, 112.877, 30.2194, 91.1161)
          ..cubicTo(31.5321, 69.3549, 4.53751, 56.5874, 7.908, 38.6017)
          ..cubicTo(11.2785, 20.616, 28.8214, 3.72766, 47.0719, 1.18757)
          ..cubicTo(65.3223, -1.35251, 80.1854, 22.6892, 99.1603, 25.9013)
          ..cubicTo(118.135, 29.1133, 126.089, 13.3307, 141.946, 17.2479)
          ..cubicTo(157.804, 21.165, 168.631, 30.7133, 178.448, 45.4869)
          ..cubicTo(188.265, 60.2606, 189.744, 72.1235, 191.031, 91.1161)
          ..close(),
        _PulseShape.tall => Path()
          ..moveTo(85.8839, 191.031)
          ..cubicTo(66.8913, 192.318, 47.3545, 197.002, 36.55, 184.886)
          ..cubicTo(25.7455, 172.77, 34.513, 147.596, 31.8613, 130.451)
          ..cubicTo(29.2095, 113.306, 29.4504, 115.244, 23.2912, 99.1601)
          ..cubicTo(17.132, 83.0761, -0.194926, 69.5945, 1.06529, 50.0314)
          ..cubicTo(2.32551, 30.4682, 12.6286, 5.30669, 29.5923, 1.34425)
          ..cubicTo(46.556, -2.61819, 64.1227, 28.9064, 85.8839, 30.2191)
          ..cubicTo(107.645, 31.5318, 120.413, 4.53726, 138.398, 7.90776)
          ..cubicTo(156.384, 11.2783, 173.272, 28.8212, 175.812, 47.0716)
          ..cubicTo(178.353, 65.3221, 154.311, 80.1852, 151.099, 99.1601)
          ..cubicTo(147.887, 118.135, 163.669, 126.089, 159.752, 141.946)
          ..cubicTo(155.835, 157.804, 146.287, 168.631, 131.513, 178.448)
          ..cubicTo(116.739, 188.265, 104.877, 189.743, 85.8839, 191.031)
          ..close(),
      };
}

/// Strokes a [_PulseShape] fitted (`BoxFit.contain`) into the paint area.
class _PulseShapePainter extends CustomPainter {
  final _PulseShape shape;
  _PulseShapePainter(this.shape);

  static const _strokeWidth = 2.0; // in viewBox units

  @override
  void paint(Canvas canvas, Size size) {
    final vb = shape.viewBox;
    final dst = _containRect(Offset.zero & size, vb.width, vb.height);
    final scale = dst.width / vb.width;
    canvas.translate(dst.left, dst.top);
    canvas.scale(scale);
    canvas.drawPath(
      shape.path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_PulseShapePainter old) => old.shape != shape;
}

class _PulseBlob extends StatelessWidget {
  final double localT;
  final _PulseShape shape;
  final Color glowColor;
  final double finalSize;
  final Alignment alignment;
  final double startScale;
  const _PulseBlob({
    required this.localT,
    required this.shape,
    required this.glowColor,
    required this.finalSize,
    required this.alignment,
    required this.startScale,
  });

  @override
  Widget build(BuildContext context) {
    if (localT <= 0 || localT >= 1) return const SizedBox.shrink();
    final scale =
        startScale + Curves.easeOut.transform(localT) * (1 - startScale);
    // Fade in over the first 20% only; no fade-out at the end.
    final opacity = localT < 0.2 ? localT / 0.2 : 1.0;
    final outline = CustomPaint(painter: _PulseShapePainter(shape));
    // OverflowBox lifts the parent constraint so the pulse can grow past the
    // layer bounds; alignment places its center on the subject center.
    return OverflowBox(
      alignment: alignment,
      maxWidth: double.infinity,
      maxHeight: double.infinity,
      child: Opacity(
        opacity: opacity,
        child: Transform.scale(
          scale: scale,
          child: SizedBox.square(
            dimension: finalSize,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _tinted(outline, glowColor, _kPathGlow),
                _tinted(outline, Colors.white, _kPathGlow * _kPathWhiteRatio),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _tinted(Widget child, Color color, double blur) =>
      ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          child: child,
        ),
      );
}
