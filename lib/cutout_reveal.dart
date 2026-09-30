/// Optional reveal animation for cutout results.
///
/// Kept out of `native_cutout.dart` so apps that only need background removal
/// never pull it in. Import this library explicitly to use it.
library;

export 'src/cutout_reveal_animation.dart'
    show CutoutRevealAnimation, CutoutStrokeStyle;
