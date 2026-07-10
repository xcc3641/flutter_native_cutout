import Flutter
import UIKit
import Vision
import CoreImage
import Accelerate

public class NativeCutoutPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.hugo/native_cutout", binaryMessenger: registrar.messenger())
        let instance = NativeCutoutPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "removeBackground":
            guard let args = call.arguments as? [String: Any],
                  let imagePath = args["imagePath"] as? String else {
                result(FlutterError(code: "INVALID_INPUT", message: "Missing imagePath argument", details: nil))
                return
            }

            let options = args["options"] as? [String: Any] ?? [:]
            let cropToSubject = options["cropToSubject"] as? Bool ?? false
            let writeToCache = options["writeToCache"] as? Bool ?? true

            guard #available(iOS 17.0, *) else {
                result(FlutterError(
                    code: "UNSUPPORTED_OS",
                    message: "Background removal requires iOS 17 or later",
                    details: nil
                ))
                return
            }

            removeBackground(
                imagePath: imagePath,
                cropToSubject: cropToSubject,
                writeToCache: writeToCache,
                result: result
            )

        case "clearCache":
            clearCache(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("native_cutout", isDirectory: true)
    }

    private func clearCache(result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let dir = self.cacheDirectory()
            do {
                if fm.fileExists(atPath: dir.path) {
                    try fm.removeItem(at: dir)
                }
                DispatchQueue.main.async { result(true) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "CACHE_CLEAR_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    @available(iOS 17.0, *)
    private func removeBackground(
        imagePath: String,
        cropToSubject: Bool,
        writeToCache: Bool,
        result: @escaping FlutterResult
    ) {
        // Check if running on simulator - Neural Engine not available
        #if targetEnvironment(simulator)
        result(FlutterError(
            code: "PROCESSING_FAILED",
            message: "Background removal requires a real iOS device (Neural Engine not available on Simulator)",
            details: nil
        ))
        return
        #endif

        DispatchQueue.global(qos: .userInitiated).async {
            // Load and fix image orientation
            guard let uiImage = UIImage(contentsOfFile: imagePath),
                  let fixedImage = self.fixImageOrientation(uiImage),
                  let cgImage = fixedImage.cgImage else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "INVALID_INPUT", message: "Could not load image at path: \(imagePath)", details: nil))
                }
                return
            }

            // Create foreground mask request
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PROCESSING_FAILED", message: "Vision request failed: \(error.localizedDescription)", details: nil))
                }
                return
            }

            guard let observation = request.results?.first else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NO_SUBJECT", message: "No foreground subject detected in image", details: nil))
                }
                return
            }

            // Generate mask for all instances
            let allInstances = observation.allInstances
            guard !allInstances.isEmpty else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NO_SUBJECT", message: "No foreground instances found", details: nil))
                }
                return
            }

            do {
                let maskPixelBuffer = try observation.generateScaledMaskForImage(forInstances: allInstances, from: handler)

                let maskBounds = self.subjectBoundingBox(inMask: maskPixelBuffer)

                // Apply mask directly to create cutout image
                guard let cutoutImage = self.applyMask(
                    sourceImage: cgImage,
                    maskBuffer: maskPixelBuffer,
                    cropToSubject: cropToSubject
                ) else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "PROCESSING_FAILED", message: "Could not apply mask", details: nil))
                    }
                    return
                }

                // Bounds are reported in coordinates of the returned image:
                // after cropToSubject the output *is* the subject box.
                let subjectBounds: [Int]?
                if cropToSubject {
                    subjectBounds = [0, 0, cutoutImage.width, cutoutImage.height]
                } else if let box = maskBounds {
                    subjectBounds = [Int(box.minX), Int(box.minY), Int(box.width), Int(box.height)]
                } else {
                    subjectBounds = nil
                }

                // Convert to PNG data
                let outputUIImage = UIImage(cgImage: cutoutImage)
                guard let pngData = outputUIImage.pngData() else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "PROCESSING_FAILED", message: "Could not encode PNG", details: nil))
                    }
                    return
                }

                if writeToCache {
                    do {
                        let dir = self.cacheDirectory()
                        try FileManager.default.createDirectory(
                            at: dir,
                            withIntermediateDirectories: true
                        )
                        let fileUrl = dir.appendingPathComponent("cutout_\(UUID().uuidString).png")
                        try pngData.write(to: fileUrl, options: .atomic)
                        var payload: [String: Any] = ["path": fileUrl.path]
                        if let subjectBounds = subjectBounds {
                            payload["subjectBounds"] = subjectBounds
                        }
                        DispatchQueue.main.async { result(payload) }
                    } catch {
                        DispatchQueue.main.async {
                            result(FlutterError(
                                code: "PROCESSING_FAILED",
                                message: "Failed to write PNG to cache: \(error.localizedDescription)",
                                details: nil
                            ))
                        }
                    }
                } else {
                    var payload: [String: Any] = ["bytes": FlutterStandardTypedData(bytes: pngData)]
                    if let subjectBounds = subjectBounds {
                        payload["subjectBounds"] = subjectBounds
                    }
                    DispatchQueue.main.async { result(payload) }
                }

            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PROCESSING_FAILED", message: "Mask generation failed: \(error.localizedDescription)", details: nil))
                }
            }
        }
    }

    /// Scans the Vision soft mask for the bounding box of subject pixels.
    ///
    /// Threshold is 1/255: the faintest value that survives quantization to
    /// the PNG's 8-bit alpha, so the box matches what a consumer would get by
    /// scanning the decoded image's alpha channel — without paying for that
    /// scan in Dart. Runs on the processing queue; the mask is 1 channel, so
    /// a full pass is a few milliseconds even at 12 MP.
    private func subjectBoundingBox(inMask mask: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        func scanRows(_ subjectPixel: (UnsafeRawPointer, Int) -> Bool) {
            for y in 0..<height {
                let row = base + y * rowBytes
                for x in 0..<width where subjectPixel(row, x) {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    maxY = y
                }
            }
        }

        switch CVPixelBufferGetPixelFormatType(mask) {
        case kCVPixelFormatType_OneComponent32Float:
            let threshold: Float = 1.0 / 255.0
            scanRows { row, x in
                row.assumingMemoryBound(to: Float.self)[x] >= threshold
            }
        case kCVPixelFormatType_OneComponent8:
            scanRows { row, x in
                row.assumingMemoryBound(to: UInt8.self)[x] > 0
            }
        default:
            return nil
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Fixes image orientation based on EXIF data
    private func fixImageOrientation(_ image: UIImage) -> UIImage? {
        guard image.imageOrientation != .up else { return image }

        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return normalizedImage
    }

    /// Applies mask to source image and optionally trims transparent pixels.
    private func applyMask(sourceImage: CGImage, maskBuffer: CVPixelBuffer, cropToSubject: Bool) -> CGImage? {
        // First, create masked image using CIFilter (reliable blending)
        let maskCIImage = CIImage(cvPixelBuffer: maskBuffer)
        let sourceCIImage = CIImage(cgImage: sourceImage)
        let transparentBackground = CIImage.empty()

        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else {
            return nil
        }

        blendFilter.setValue(sourceCIImage, forKey: kCIInputImageKey)
        blendFilter.setValue(transparentBackground, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(maskCIImage, forKey: kCIInputMaskImageKey)

        guard let outputCIImage = blendFilter.outputImage else {
            return nil
        }

        // Render to CGImage
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let maskedImage = context.createCGImage(outputCIImage, from: outputCIImage.extent) else {
            return nil
        }

        guard cropToSubject else {
            return maskedImage
        }

        // Trim transparent pixels using vImage when requested.
        return trimTransparentPixelsWithVImage(maskedImage)
    }

    /// Trims transparent pixels using vImage (Accelerate framework)
    private func trimTransparentPixelsWithVImage(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height

        // Create vImage format for ARGB8888
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        // Create source buffer from CGImage
        var sourceBuffer = vImage_Buffer()
        var error = vImageBuffer_InitWithCGImage(
            &sourceBuffer,
            &format,
            nil,
            image,
            vImage_Flags(kvImageNoFlags)
        )

        guard error == kvImageNoError else {
            return nil
        }
        defer { free(sourceBuffer.data) }

        // Access pixel data to find bounding box
        let data = sourceBuffer.data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = sourceBuffer.rowBytes

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0

        // Alpha threshold (ARGB format, alpha is first byte)
        let alphaThreshold: UInt8 = 10

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * rowBytes + x * 4
                let alpha = data[pixelIndex] // ARGB: alpha is first

                if alpha > alphaThreshold {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }

        // Check if we found any non-transparent pixels
        guard maxX >= minX && maxY >= minY else {
            return nil
        }

        // Calculate crop dimensions
        let cropWidth = maxX - minX + 1
        let cropHeight = maxY - minY + 1
        let cropRect = CGRect(x: minX, y: minY, width: cropWidth, height: cropHeight)

        // Create cropped buffer
        var croppedBuffer = vImage_Buffer()
        error = vImageBuffer_Init(
            &croppedBuffer,
            vImagePixelCount(cropHeight),
            vImagePixelCount(cropWidth),
            32,
            vImage_Flags(kvImageNoFlags)
        )

        guard error == kvImageNoError else {
            return nil
        }
        defer { free(croppedBuffer.data) }

        // Copy cropped region
        let croppedData = croppedBuffer.data.assumingMemoryBound(to: UInt8.self)
        let croppedRowBytes = croppedBuffer.rowBytes

        for y in 0..<cropHeight {
            let srcRow = data.advanced(by: (minY + y) * rowBytes + minX * 4)
            let dstRow = croppedData.advanced(by: y * croppedRowBytes)
            memcpy(dstRow, srcRow, cropWidth * 4)
        }

        // Create CGImage from cropped buffer
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var outputFormat = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(colorSpace),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        var vImageError: vImage_Error = kvImageNoError
        let result = vImageCreateCGImageFromBuffer(
            &croppedBuffer,
            &outputFormat,
            nil,
            nil,
            vImage_Flags(kvImageNoFlags),
            &vImageError
        )

        guard vImageError == kvImageNoError else {
            return nil
        }

        return result?.takeRetainedValue()
    }
}
