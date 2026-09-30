# native_cutout

[![pub package](https://img.shields.io/pub/v/native_cutout.svg)](https://pub.dev/packages/native_cutout)
[![pub points](https://img.shields.io/pub/points/native_cutout)](https://pub.dev/packages/native_cutout/score)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-android%20%7C%20ios-blue.svg)](https://pub.dev/packages/native_cutout)

[English](README.md) | 简体中文

基于系统原生图像分割能力的 Flutter 抠图插件。

`native_cutout` 读取本地图片文件、去除背景、生成透明 PNG —— 全程**端侧处理**，不调用任何后端 API、不上传图片、不需要 API Key。

| 主页 · 模型管理 | 抠图结果 |
| :---: | :---: |
| <img src="https://raw.githubusercontent.com/xcc3641/flutter_native_cutout/main/images/1.png" width="320" alt="带 Android 模型管理的主页" /> | <img src="https://raw.githubusercontent.com/xcc3641/flutter_native_cutout/main/images/2.png" width="320" alt="带 cropToSubject 与 writeToCache 开关的抠图结果" /> |

底层依赖：

- **iOS**：Vision Framework（`VNGenerateForegroundInstanceMaskRequest`）
- **Android**：Google ML Kit Subject Segmentation

## 功能特性

- 完全**端侧**完成背景去除
- 默认**写入缓存目录**并返回文件路径
- 可选**内存 PNG 字节**输出，便于直接在 Dart 层使用
- iOS / Android 两端原生图像处理
- 分割前自动修正 **EXIF 方向**
- 可选「贴合主体」裁剪 `CutoutOptions.cropToSubject`
- `clearCache()` 清理缓存
- Android 提供模型生命周期 API：可用性查询、下载、下载进度、清除
- 简洁的 Dart API，结果类型严格区分成功 / 失败
- 可选的**揭示动画**（`CutoutRevealAnimation`），需单独导入，不引入额外依赖

## 平台支持

| 平台 | 引擎 | 最低版本 | 备注 |
| --- | --- | --- | --- |
| iOS | Vision Framework | iOS 13.0（编译）/ iOS 17.0（运行时） | 实际抠图需要**真机** |
| Android | ML Kit Subject Segmentation | API 21+ | 分割模型由 Google Play Services 按需下发 |

> **重要提示**
>
> - **iOS 模拟器**不支持前景分割，请使用 iPhone / iPad 真机。
> - **Android 端的 ML Kit 模型不会随 APK 一起打包**。如果设备本地没有该模型，首次调用 `removeBackground` 时会**隐式触发**一次模型下载 —— 这次调用会一直阻塞到下载完成，且**无网络时会失败**。建议参考下文 [Android 接入](#android-接入) 提前预热。

## 安装

`pubspec.yaml`：

```yaml
dependencies:
  native_cutout: ^0.4.0
```

然后执行：

```bash
flutter pub get
```

## iOS 接入

插件**编译目标**为 **iOS 13.0+**（与 Flutter 默认一致），**不会**抬高你 App 的最低部署版本。

**运行时**的背景去除 API（`VNGenerateForegroundInstanceMaskRequest`）需要 **iOS 17.0+**；在更低版本系统上调用 `removeBackground` 会返回错误码 `UNSUPPORTED_OS`。

无需修改 `Podfile`，正常安装即可：

```bash
cd ios && pod install
```

## Android 接入

插件支持 **Android API 21+**，**不需要**手动改 `AndroidManifest.xml`。

### ML Kit 模型如何下发

本插件使用 ML Kit Subject Segmentation 的 **unbundled（非内嵌）变体**
（`play-services-mlkit-subject-segmentation`）。分割模型**不会**打进你的 APK，
而是由 Google Play Services 在 App 之外管理、按需下发。模型有两种到达设备的路径：

1. **隐式下载（默认 / 懒加载）** —— 当设备上还没有模型时，首次调用
   `NativeCutout.removeBackground` 会在 ML Kit 内部**自动触发**一次模型下载。
   在下载完成前，`removeBackground` 的 Future 不会返回，因此：
   - 新装 App 的**第一次抠图**会明显变慢
   - **离线时**这次调用会失败（常见错误码：`processingFailed`）
   - 隐式下载过程中**没有进度回调**，UI 层只能展示一个不确定的 loading

2. **显式预热（推荐）** —— 提前调用 `NativeCutout.downloadModel()`
   （比如 App 启动时、或用户首次进入编辑器时）。这条路径会通过
   `NativeCutout.downloadProgress` 推送进度，方便你做一个真正的下载 UI，
   也能消除首次抠图的延迟尖刺。

下面的 [Android 模型预热推荐流程](#android-模型预热推荐流程) 有完整示例代码。

调试时可以用 `NativeCutout.clearModel()` 请求 Google Play Services 释放已下载的模型，从而重新走一遍首次下载流程。

## 快速开始

### 默认流程：返回缓存目录中的 PNG 文件路径

默认情况下 `native_cutout` 会把结果 PNG 写到 App 的缓存目录，并把文件路径返回。

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
    debugPrint('抠图失败: ${code.name} - $message');
    return;
}
```

### 内存字节流程：直接返回 PNG 字节

如果你明确需要在 Dart 层拿到原始字节，关闭缓存写入即可：

```dart
final result = await NativeCutout.removeBackground(
  imagePath,
  options: const CutoutOptions(writeToCache: false),
);
```

## Android 模型预热推荐流程

为了让 Android 端首次抠图更可靠，建议处理前先检查模型：

```dart
final isReady = await NativeCutout.isModelAvailable();

if (!isReady) {
  final downloaded = await NativeCutout.downloadModel();
  if (!downloaded) {
    debugPrint('ML Kit 模型下载失败');
    return;
  }
}

final result = await NativeCutout.removeBackground(imagePath);
```

如果想在 UI 上展示下载进度：

```dart
final sub = NativeCutout.downloadProgress.listen((progress) {
  debugPrint('state=${progress.state} fraction=${progress.fraction}');
});

final ok = await NativeCutout.downloadModel();
await sub.cancel();
```

需要重新测试「首次下载」流程时：

```dart
await NativeCutout.clearModel();
final isStillAvailable = await NativeCutout.isModelAvailable();
debugPrint('清除后是否仍可用: $isStillAvailable');
```

使用文件缓存输出时，也可以清除历史生成的 PNG：

```dart
await NativeCutout.clearCache();
```

iOS 上：

- `isModelAvailable()` 始终返回 `true`
- `downloadModel()` 是空操作，返回 `true`
- `clearModel()` 是空操作，返回 `true`

## API 总览

### `NativeCutout.removeBackground`

去除本地图片文件的背景。

```dart
Future<CutoutResult> NativeCutout.removeBackground(
  String imagePath, {
  CutoutOptions? options,
})
```

参数：

- `imagePath`：设备本地图片文件的绝对路径
- `options`：可选的抠图配置

返回：

- `CutoutFileSuccess`：缓存 PNG 文件路径（默认）
- `CutoutBytesSuccess`：PNG 字节（`writeToCache` 为 `false` 时）
- `CutoutFailure`：包含 `code` 与 `message`

### `CutoutOptions`

```dart
const CutoutOptions(
  cropToSubject: false,
  writeToCache: true,
)
```

可用字段：

- `cropToSubject`：为 `true` 时裁掉透明边、返回贴合主体的紧凑图；为 `false` 时保留原图画布尺寸
- `writeToCache`：为 `true`（默认）时将 PNG 写入 App 缓存目录并返回 `CutoutFileSuccess`；为 `false` 时返回 `CutoutBytesSuccess`

### `NativeCutout.clearCache`

删除插件之前写入 App 缓存目录的 PNG 文件。

```dart
Future<bool> NativeCutout.clearCache()
```

### `NativeCutout.isModelAvailable`

查询底层原生模型 / 运行时是否就绪。

```dart
Future<bool> NativeCutout.isModelAvailable()
```

### `NativeCutout.downloadModel`

在需要时触发 Android ML Kit 分割模块下载。

```dart
Future<bool> NativeCutout.downloadModel()
```

### `NativeCutout.clearModel`

请求释放 Android ML Kit 已下载的模块。

```dart
Future<bool> NativeCutout.clearModel()
```

> **说明**
>
> Android 端底层调用的是 Google Play services 的 `releaseModules(...)`，这是一次**尽力而为**的请求。模型可能不会立刻消失，因此建议随后再调用一次 `isModelAvailable()` 来刷新当前状态。

### `NativeCutout.downloadProgress`

Android 模型下载进度的广播流。

```dart
Stream<ModelDownloadProgress> get NativeCutout.downloadProgress
```

说明：

- 仅在 Android 上、`downloadModel()` 运行期间发出事件
- iOS 上返回空流
- 每个事件包含 `state`、`bytesDownloaded`、`totalBytes`、`errorCode`，以及计算字段 `fraction`

## 结果类型

### `CutoutSuccess.subjectBounds`

每个成功结果都携带主体的包围盒，在原生侧生成蒙版时顺带算出：

```dart
sealed class CutoutSuccess extends CutoutResult {
  /// 主体非透明像素的包围盒，使用返回图像的像素坐标。
  /// 无法确定时为 null。
  final Rect? subjectBounds;
}
```

需要主体位置或大小时（例如让动画对准主体）直接读它，读取零成本——
**不要**在 Dart 里解码 PNG 再逐像素扫 alpha 通道：大图全分辨率扫描
会在主 isolate 上阻塞 UI 线程数秒。

`cropToSubject: true` 时返回图像本身就是主体裁切，
因此 `subjectBounds` 等于整图矩形。

### `CutoutFileSuccess`

带缓存 PNG 路径的成功结果：

```dart
class CutoutFileSuccess extends CutoutSuccess {
  final String path;
}
```

### `CutoutBytesSuccess`

带内存 PNG 字节的成功结果：

```dart
class CutoutBytesSuccess extends CutoutSuccess {
  final Uint8List pngBytes;
}
```

### `CutoutFailure`

带类型化错误码与可读消息的失败结果：

```dart
class CutoutFailure extends CutoutResult {
  final CutoutErrorCode code;
  final String message;
}
```

## 错误码

| 错误码 | 含义 |
| --- | --- |
| `invalidInput` | 图片路径缺失、非法，或文件无法解码 |
| `noSubjectFound` | 图中未识别出明确的前景主体 |
| `processingFailed` | 原生处理因其他原因失败 |

## 输出行为

- 输出始终是**带透明背景的 PNG**
- 默认会写入 App 缓存目录并返回文件路径
- 当 `writeToCache` 为 `false` 时，返回内存中的 PNG 字节
- 背景区域会被设为透明
- 仅当 `cropToSubject` 为 `true` 时才会裁掉透明边
- 可通过 `NativeCutout.clearCache()` 清理已缓存的 PNG

## 怎样得到更好的效果

为了获得更高质量的抠图：

- 使用**主体清晰**的图片
- 主体应与背景有明显的视觉区分
- 避免严重模糊、过暗或分辨率极低的输入

## 已知限制

- 输入必须是**本地文件路径**
- iOS 端需要 **iOS 17+** 且**真机**
- Android 端依赖 Google Play services 与一次**初始模型下载**（首次调用时隐式触发，或通过 `downloadModel()` 显式触发）；模型未缓存时首次调用**对离线不友好**
- 抠图质量取决于平台分割引擎和源图质量

## 可选：揭示动画

包里附带一个可选的「抠出」动画，用来展示抠图结果。它在单独的库里，`native_cutout.dart` 不导出它，也不引入任何额外依赖——需要时才导入：

```dart
import 'package:native_cutout/cutout_reveal.dart';

// originalImage / cutoutImage：原图和抠图 PNG 解码后的 ui.Image。
// 两者分辨率必须一致，所以抠图时用 cropToSubject: false。
CutoutRevealAnimation(
  originalImage: originalImage,
  cutoutImage: cutoutImage,
  subjectBounds: success.subjectBounds, // 传了就不用再扫 alpha
  onCompleted: () {/* 停在最后一帧，或跳转 */},
)
```

时间线（默认 `rippleSpeed: 1.5`，约 2.4 秒）：两道发光波纹扫过主体 → 主体放大到 1.1 倍、背景变暗 → 主体描边呼吸一次。`loop: false` 时停在最后一帧。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `loop` | `false` | 循环播放 |
| `rippleSpeed` | `1.5` | 波纹阶段速度倍率（0.1–8.0） |
| `glowColor` | `#FFE200` | 波纹和描边的发光颜色 |
| `backgroundColor` | `#6A6A6A` | 图片后面的底色 |
| `strokeStyle` | `CutoutStrokeStyle()` | 描边宽度、模糊度、光晕层数 |

传入的 `ui.Image` 不会被这个 widget 释放，需要调用方自己 dispose。

## Example 示例工程

仓库中的 [`example/`](example/) 工程演示了：

- 从相册选图
- 检查 / 下载 Android 模型
- 监听 Android 模型下载进度
- 清除 Android 模型并刷新可用性，便于反复测试
- 执行背景去除
- 在结果页切换 `cropToSubject`
- 切换 `writeToCache`，对比缓存文件输出与内存字节输出
- 预览前后对比
- 比较缓存文件输出尺寸与原图
- 保存生成的透明 PNG
- 对未裁剪的结果播放可选的揭示动画

## License

MIT
