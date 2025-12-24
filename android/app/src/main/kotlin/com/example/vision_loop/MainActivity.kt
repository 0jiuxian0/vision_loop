package com.example.vision_loop

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.vision_loop/image_decoder"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "decodeImage" -> {
                    val imagePath = call.argument<String>("path")
                    if (imagePath == null) {
                        result.error("INVALID_ARGUMENT", "Image path is null", null)
                        return@setMethodCallHandler
                    }
                    
                    try {
                        val file = File(imagePath)
                        if (!file.exists()) {
                            result.error("FILE_NOT_FOUND", "Image file does not exist: $imagePath", null)
                            return@setMethodCallHandler
                        }
                        
                        // 使用Android原生BitmapFactory解码图片
                        val bitmap = BitmapFactory.decodeFile(imagePath)
                        if (bitmap == null) {
                            result.error("DECODE_FAILED", "Failed to decode image: $imagePath", null)
                            return@setMethodCallHandler
                        }
                        
                        // 将Bitmap转换为JPEG字节数组
                        val outputStream = java.io.ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 100, outputStream)
                        val jpegBytes = outputStream.toByteArray()
                        
                        result.success(jpegBytes)
                    } catch (e: Exception) {
                        result.error("DECODE_ERROR", "Error decoding image: ${e.message}", e.stackTraceToString())
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}
