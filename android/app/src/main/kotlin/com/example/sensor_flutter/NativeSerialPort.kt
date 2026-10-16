package com.example.sensor_flutter

import java.io.FileDescriptor

object NativeSerialPort {
    init {
        System.loadLibrary("serial_port")
    }

    @JvmStatic
    external fun open(path: String, baud: Int): FileDescriptor?

    @JvmStatic
    external fun readBytes(fd: FileDescriptor, buffer: ByteArray, timeoutMs: Int): Int

    @JvmStatic
    external fun close(fd: FileDescriptor?)
}
