package com.hugo.native_cutout

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import com.google.android.gms.common.moduleinstall.InstallStatusListener
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.android.gms.common.moduleinstall.ModuleInstallStatusUpdate
import com.google.android.gms.common.moduleinstall.ModuleInstallStatusUpdate.InstallState
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.subject.SubjectSegmentation
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenterOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import android.os.Handler
import android.os.Looper
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.FloatBuffer
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.roundToInt

class NativeCutoutPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var progressChannel: EventChannel
    private lateinit var context: android.content.Context
    private var progressSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val workerExecutor = Executors.newSingleThreadExecutor()

    private fun postSuccess(result: Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun postError(result: Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "com.hugo/native_cutout")
        channel.setMethodCallHandler(this)
        progressChannel = EventChannel(
            flutterPluginBinding.binaryMessenger,
            "com.hugo/native_cutout/download_progress"
        )
        progressChannel.setStreamHandler(this)
        context = flutterPluginBinding.applicationContext
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
    }

    override fun onCancel(arguments: Any?) {
        progressSink = null
    }

    private fun emitProgress(update: ModuleInstallStatusUpdate) {
        val sink = progressSink ?: return
        val progress = update.progressInfo
        val payload = mapOf(
            "state" to stateToString(update.installState),
            "bytesDownloaded" to (progress?.bytesDownloaded ?: 0L),
            "totalBytes" to (progress?.totalBytesToDownload ?: 0L),
            "errorCode" to update.errorCode,
        )
        mainHandler.post { sink.success(payload) }
    }

    private fun stateToString(state: Int): String = when (state) {
        InstallState.STATE_PENDING -> "pending"
        InstallState.STATE_DOWNLOADING -> "downloading"
        InstallState.STATE_DOWNLOAD_PAUSED -> "downloadPaused"
        InstallState.STATE_INSTALLING -> "installing"
        InstallState.STATE_COMPLETED -> "completed"
        InstallState.STATE_CANCELED -> "canceled"
        InstallState.STATE_FAILED -> "failed"
        else -> "unknown"
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "isModelAvailable" -> checkModelAvailability(result)
            "downloadModel" -> downloadModel(result)
            "clearModel" -> clearModel(result)
            "clearCache" -> clearCache(result)
            "removeBackground" -> {
                val imagePath = call.argument<String>("imagePath")
                if (imagePath == null) {
                    result.error("INVALID_INPUT", "Missing imagePath argument", null)
                    return
                }

                @Suppress("UNCHECKED_CAST")
                val options = call.argument<Map<String, Any>>("options") ?: emptyMap()
                val cropToSubject = options["cropToSubject"] as? Boolean ?: false
                val writeToCache = options["writeToCache"] as? Boolean ?: true

                removeBackground(imagePath, cropToSubject, writeToCache, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun checkModelAvailability(result: Result) {
        val segmenter = SubjectSegmentation.getClient(
            SubjectSegmenterOptions.Builder().build()
        )
        val moduleInstallClient = ModuleInstall.getClient(context)

        moduleInstallClient.areModulesAvailable(segmenter)
            .addOnSuccessListener { response ->
                result.success(response.areModulesAvailable())
            }
            .addOnFailureListener { e ->
                result.error("CHECK_FAILED", "Failed to check model availability: ${e.message}", null)
            }
    }

    private fun clearCache(result: Result) {
        workerExecutor.execute {
            try {
                val cacheDir = File(context.cacheDir, "native_cutout")
                if (cacheDir.exists()) cacheDir.deleteRecursively()
                postSuccess(result, true)
            } catch (e: Exception) {
                postError(result, "CACHE_CLEAR_FAILED", e.message ?: "Unknown error")
            }
        }
    }

    private fun clearModel(result: Result) {
        val segmenter = SubjectSegmentation.getClient(
            SubjectSegmenterOptions.Builder().build()
        )
        val moduleInstallClient = ModuleInstall.getClient(context)

        moduleInstallClient.releaseModules(segmenter)
            .addOnSuccessListener {
                result.success(true)
            }
            .addOnFailureListener { e ->
                result.error("CLEAR_FAILED", "Failed to clear model: ${e.message}", null)
            }
    }

    private fun downloadModel(result: Result) {
        val segmenter = SubjectSegmentation.getClient(
            SubjectSegmenterOptions.Builder().build()
        )
        val moduleInstallClient = ModuleInstall.getClient(context)

        val listener = InstallStatusListener { update -> emitProgress(update) }

        val moduleInstallRequest = ModuleInstallRequest.newBuilder()
            .addApi(segmenter)
            .setListener(listener)
            .build()

        moduleInstallClient.installModules(moduleInstallRequest)
            .addOnSuccessListener {
                moduleInstallClient.unregisterListener(listener)
                result.success(true)
            }
            .addOnFailureListener { e ->
                moduleInstallClient.unregisterListener(listener)
                result.error("DOWNLOAD_FAILED", "Failed to download model: ${e.message}", null)
            }
    }

    private fun removeBackground(
        imagePath: String,
        cropToSubject: Boolean,
        writeToCache: Boolean,
        result: Result
    ) {
        workerExecutor.execute {
            val file = File(imagePath)
            if (!file.exists()) {
                postError(result, "INVALID_INPUT", "File does not exist: $imagePath")
                return@execute
            }

            val originalBitmap = BitmapFactory.decodeFile(imagePath)
            if (originalBitmap == null) {
                postError(result, "INVALID_INPUT", "Could not decode image: $imagePath")
                return@execute
            }

            val bitmap = fixOrientation(imagePath, originalBitmap)

            val options = SubjectSegmenterOptions.Builder()
                .enableForegroundConfidenceMask()
                .build()

            val segmenter = SubjectSegmentation.getClient(options)
            val inputImage = InputImage.fromBitmap(bitmap, 0)

            segmenter.process(inputImage)
                .addOnSuccessListener(workerExecutor) { segmentationResult ->
                    val mask = segmentationResult.foregroundConfidenceMask
                    if (mask == null) {
                        bitmap.recycle()
                        if (bitmap != originalBitmap) originalBitmap.recycle()
                        postError(result, "NO_SUBJECT", "No foreground mask generated")
                        return@addOnSuccessListener
                    }

                    val width = bitmap.width
                    val height = bitmap.height

                    mask.rewind()
                    var hasSubject = false
                    while (mask.hasRemaining()) {
                        if (mask.get() > 0.1f) {
                            hasSubject = true
                            break
                        }
                    }

                    if (!hasSubject) {
                        bitmap.recycle()
                        if (bitmap != originalBitmap) originalBitmap.recycle()
                        postError(result, "NO_SUBJECT", "No foreground subject detected in image")
                        return@addOnSuccessListener
                    }

                    val maskOutput = applyMask(bitmap, mask, width, height, cropToSubject)
                    bitmap.recycle()
                    if (bitmap != originalBitmap) originalBitmap.recycle()

                    if (maskOutput == null) {
                        postError(result, "PROCESSING_FAILED", "Failed to apply mask")
                        return@addOnSuccessListener
                    }

                    val resultBitmap = maskOutput.bitmap
                    if (writeToCache) {
                        try {
                            val cacheDir = File(context.cacheDir, "native_cutout").apply { mkdirs() }
                            val outFile = File(cacheDir, "cutout_${UUID.randomUUID()}.png")
                            outFile.outputStream().use { os ->
                                resultBitmap.compress(Bitmap.CompressFormat.PNG, 100, os)
                            }
                            resultBitmap.recycle()
                            postSuccess(result, successPayload("path", outFile.absolutePath, maskOutput.subjectBounds))
                        } catch (e: Exception) {
                            resultBitmap.recycle()
                            postError(result, "PROCESSING_FAILED", "Failed to write PNG to cache: ${e.message}")
                        }
                    } else {
                        val outputStream = ByteArrayOutputStream()
                        resultBitmap.compress(Bitmap.CompressFormat.PNG, 100, outputStream)
                        resultBitmap.recycle()
                        postSuccess(result, successPayload("bytes", outputStream.toByteArray(), maskOutput.subjectBounds))
                    }
                }
                .addOnFailureListener(workerExecutor) { e ->
                    bitmap.recycle()
                    if (bitmap != originalBitmap) originalBitmap.recycle()
                    postError(result, "PROCESSING_FAILED", "Segmentation failed: ${e.message}")
                }
        }
    }

    /// Cutout bitmap plus the subject's alpha bounding box (left, top, width,
    /// height) in coordinates of that bitmap. Bounds are null when no
    /// non-transparent pixel was found.
    private class MaskOutput(val bitmap: Bitmap, val subjectBounds: List<Int>?)

    private fun successPayload(key: String, value: Any, bounds: List<Int>?): Map<String, Any> =
        if (bounds != null) mapOf(key to value, "subjectBounds" to bounds)
        else mapOf(key to value)

    private fun applyMask(
        bitmap: Bitmap,
        mask: FloatBuffer,
        maskWidth: Int,
        maskHeight: Int,
        cropToSubject: Boolean
    ): MaskOutput? {
        val width = bitmap.width
        val height = bitmap.height

        // Create output bitmap with alpha channel
        val outputBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)

        // Calculate scaling factors between mask and image
        val scaleX = maskWidth.toFloat() / width
        val scaleY = maskHeight.toFloat() / height

        // Track bounds for cropping
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0

        // Get pixels from source
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)

        // Apply mask
        mask.rewind()
        val maskArray = FloatArray(maskWidth * maskHeight)
        mask.get(maskArray)

        for (y in 0 until height) {
            for (x in 0 until width) {
                // Map image coordinates to mask coordinates
                val maskX = (x * scaleX).roundToInt().coerceIn(0, maskWidth - 1)
                val maskY = (y * scaleY).roundToInt().coerceIn(0, maskHeight - 1)
                val maskIndex = maskY * maskWidth + maskX

                val confidence = maskArray[maskIndex]
                val pixelIndex = y * width + x
                val pixel = pixels[pixelIndex]

                // Apply alpha based on confidence
                val alpha = (confidence * 255).roundToInt().coerceIn(0, 255)

                if (alpha > 0) {
                    val r = Color.red(pixel)
                    val g = Color.green(pixel)
                    val b = Color.blue(pixel)
                    pixels[pixelIndex] = Color.argb(alpha, r, g, b)

                    // Update bounds
                    if (x < minX) minX = x
                    if (y < minY) minY = y
                    if (x > maxX) maxX = x
                    if (y > maxY) maxY = y
                } else {
                    pixels[pixelIndex] = Color.TRANSPARENT
                }
            }
        }

        outputBitmap.setPixels(pixels, 0, width, 0, 0, width, height)

        val hasBounds = maxX >= minX && maxY >= minY
        val bounds = if (hasBounds) {
            listOf(minX, minY, maxX - minX + 1, maxY - minY + 1)
        } else {
            null
        }

        if (!cropToSubject) {
            return MaskOutput(outputBitmap, bounds)
        }

        return if (maxX > minX && maxY > minY) {
            val cropWidth = maxX - minX + 1
            val cropHeight = maxY - minY + 1
            val croppedBitmap = Bitmap.createBitmap(outputBitmap, minX, minY, cropWidth, cropHeight)
            outputBitmap.recycle()
            // Output is the subject crop, so bounds cover the whole bitmap.
            MaskOutput(croppedBitmap, listOf(0, 0, cropWidth, cropHeight))
        } else {
            MaskOutput(outputBitmap, bounds)
        }
    }

    private fun fixOrientation(imagePath: String, bitmap: Bitmap): Bitmap {
        return try {
            val exif = ExifInterface(imagePath)
            val orientation = exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )

            val matrix = Matrix()
            when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
                ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> {
                    matrix.postRotate(90f)
                    matrix.preScale(-1f, 1f)
                }
                ExifInterface.ORIENTATION_TRANSVERSE -> {
                    matrix.postRotate(-90f)
                    matrix.preScale(-1f, 1f)
                }
                else -> return bitmap
            }

            Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        } catch (e: Exception) {
            bitmap
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        progressChannel.setStreamHandler(null)
        progressSink = null
        workerExecutor.shutdown()
    }
}
