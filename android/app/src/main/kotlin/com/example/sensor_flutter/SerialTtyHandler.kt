package com.example.sensor_flutter

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileDescriptor
import java.io.FileOutputStream

class SerialTtyHandler : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var fd: FileDescriptor? = null
    private var output: FileOutputStream? = null
    private var readerThread: Thread? = null
    @Volatile private var running = false
    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, "rs485_tty").setMethodCallHandler(this)
        EventChannel(messenger, "rs485_tty/rx").setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> result.success(listPorts())
            "open" -> {
                val baud = call.argument<Int>("baud") ?: 19200
                result.success(open("/dev/ttyS7", baud))
            }
            "write" -> result.success(write(call.argument<ByteArray>("data")))
            "close" -> {
                close()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.events = events
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private fun listPorts(): List<String> {
        return listOf("/dev/ttyS7")
    }

    private fun open(path: String, baud: Int): Boolean {
        close()
        try {
            try {
                Runtime.getRuntime().exec(arrayOf("sh", "-c", "chmod 666 $path")).waitFor()
            } catch (_: Exception) {
            }
            val opened = NativeSerialPort.open(path, baud) ?: return false
            fd = opened
            output = FileOutputStream(opened)
            running = true
            readerThread = Thread({
                val buf = ByteArray(512)
                while (running) {
                    try {
                        val n = NativeSerialPort.readBytes(opened, buf, 200)
                        if (n > 0) {
                            val copy = buf.copyOf(n)
                            main.post { events?.success(copy) }
                        } else if (n < 0) {
                            if (running) {
                                Log.e("ttyS7", "native read stopped")
                            }
                            break
                        }
                    } catch (e: Exception) {
                        if (running) {
                            Log.e("ttyS7", "reader exception", e)
                        }
                        break
                    }
                }
            }, "rs485-tty-rx").apply { start() }
            return true
        } catch (_: Exception) {
            close()
            return false
        }
    }

    private fun write(data: ByteArray?): Boolean {
        if (data == null) return false
        return try {
            output?.write(data)
            output?.flush()
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun close() {
        running = false
        try {
            NativeSerialPort.close(fd)
        } catch (_: Exception) {
        }
        try {
            readerThread?.join(300)
        } catch (_: Exception) {
        }
        output = null
        fd = null
        readerThread = null
    }
}
