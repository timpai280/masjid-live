package com.masjidlive.masjid_live

import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createChannels(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "masjid_live/bg").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val i = Intent(this, LiveService::class.java).apply {
                        putExtra("mic", call.argument<Boolean>("mic") ?: false)
                        putExtra("title", call.argument<String>("title") ?: "Masjid Live")
                        putExtra("text", call.argument<String>("text") ?: "")
                    }
                    try {
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("start_failed", e.message, null)
                    }
                }
                "stop" -> {
                    stopService(Intent(this, LiveService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
