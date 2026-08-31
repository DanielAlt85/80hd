package com.danielalt.omi_capture

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "omi_capture/service"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        CaptureService.start(this)
                        result.success(null)
                    }
                    "stop" -> {
                        CaptureService.stop(this)
                        result.success(null)
                    }
                    // Rather than path_provider, which pulls in a native jni
                    // build needing CMake and the NDK to answer this one
                    // question. App-private storage: nothing else on the phone
                    // can read it, and it goes away with the app.
                    "filesDir" -> result.success(filesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
    }
}
