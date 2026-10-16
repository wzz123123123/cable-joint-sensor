package com.example.sensor_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val ttyHandler = SerialTtyHandler()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ttyHandler.attach(flutterEngine.dartExecutor.binaryMessenger)
    }
}
