import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:usb_serial/usb_serial.dart';
import 'serial_debug_logger.dart';

/// 平板 TTL / USB-485 / Windows COM。
/// 现场主板：COMn 对应 /dev/ttySn，当前接 TTL7/COM7，即 /dev/ttyS7，19200 8N1。
class Rs485SerialService {
  static const int baudRate = 19200;
  static const String windowsPort = 'COM7';
  static const String androidTtyPort = '/dev/ttyS7';
  static const _ttyChannel = MethodChannel('rs485_tty');
  static const _ttyRx = EventChannel('rs485_tty/rx');
  static const _winChannel = MethodChannel('rs485_win');
  static const _winRx = EventChannel('rs485_win/rx');

  UsbPort? _usbPort;
  StreamSubscription<Uint8List>? _usbRxSub;
  StreamSubscription<UsbEvent>? _usbEventSub;
  StreamSubscription? _ttyRxSub;
  StreamSubscription? _winRxSub;
  Timer? _reconnectTimer;
  Timer? _rxWatchdog;
  DateTime? _lastRxAt;
  DateTime? _lastTxAt;
  bool _open = false;
  bool _disposed = false;
  bool _opening = false;
  bool _usingTty = false;
  bool _usingWindows = false;

  void Function(Uint8List data)? onData;
  void Function(bool open, String status)? onStatus;

  bool get isOpen => _open;

  Future<void> start() async {
    _disposed = false;
    if (Platform.isWindows) {
      _listenWinRx();
    } else if (Platform.isAndroid) {
      _listenTtyRx();
      try {
        _usbEventSub ??= UsbSerial.usbEventStream?.listen((event) {
          if (_disposed) return;
          if (event.event == UsbEvent.ACTION_USB_ATTACHED) {
            if (!_open) {
              unawaited(open());
            }
          } else if (event.event == UsbEvent.ACTION_USB_DETACHED) {
            if (!_usingTty) {
              unawaited(SerialDebugLogger.instance.log('USB串口已拔出'));
              unawaited(close(status: '串口已拔出'));
            }
          }
        });
      } catch (e) {
        debugPrint('USB事件监听失败: $e');
      }
    }
    unawaited(SerialDebugLogger.instance.log(
        '版本1.0.22 原生层写死打开 /dev/ttyS7(COM7/TTL7)，波特率=$baudRate，发令后等200ms无返回则询下一站'));
    await open();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_disposed && !_open && !_opening) {
        unawaited(open());
      }
    });
    _rxWatchdog?.cancel();
    _rxWatchdog = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_recoverIfRxStopped());
    });
  }

  Future<bool> open() async {
    if (_open || _disposed) return _open;
    if (_opening) return false;
    _opening = true;
    try {
      if (Platform.isWindows) {
        if (await _openWindows()) return true;
        _notify(false, '未打开 $windowsPort，请先关闭串口助手后重试');
        return false;
      }
      if (await _openTty()) return true;
      unawaited(SerialDebugLogger.instance.log('未打开 $androidTtyPort，2秒后重试'));
      _notify(false, '未打开 $androidTtyPort');
      return false;
    } catch (e) {
      unawaited(SerialDebugLogger.instance.log('串口打开异常: $e'));
      _notify(false, '串口打开异常: $e');
      debugPrint('❌ 打开串口失败: $e');
      return false;
    } finally {
      _opening = false;
    }
  }

  Future<bool> _openWindows() async {
    final names = <String>[windowsPort];
    try {
      final listed = await _winChannel.invokeMethod('list');
      if (listed is List) {
        for (final item in listed) {
          final name = item.toString();
          if (!names.contains(name)) names.add(name);
        }
      }
    } catch (e) {
      debugPrint('枚举COM口失败: $e');
    }

    for (final name in names) {
      try {
        final ok = await _winChannel.invokeMethod<bool>('open', {
          'port': name,
          'baud': baudRate,
        });
        if (ok == true) {
          _usingWindows = true;
          _usingTty = false;
          _open = true;
          _notify(true, '串口已打开 $name $baudRate 8N1');
          debugPrint('✅ Windows串口已打开: $name $baudRate');
          return true;
        }
      } catch (e) {
        debugPrint('打开$name失败: $e');
      }
    }
    return false;
  }

  Future<bool> _openUsb() async {
    List<UsbDevice> devices = const [];
    try {
      devices = await UsbSerial.listDevices();
      unawaited(SerialDebugLogger.instance.log(
          'USB串口枚举: ${devices.map((d) => '${d.productName ?? d.deviceName} vid=${d.vid} pid=${d.pid}').join('; ')}'));
    } catch (e) {
      unawaited(SerialDebugLogger.instance.log('USB串口枚举失败: $e'));
      return false;
    }
    if (devices.isEmpty) {
      unawaited(SerialDebugLogger.instance.log('未发现USB串口设备'));
      return false;
    }

    final device = devices.first;
    final port = await device.create();
    if (port == null) {
      unawaited(SerialDebugLogger.instance.log('USB串口权限未授予'));
      _notify(false, 'USB串口权限未授予');
      return false;
    }
    final ok = await port.open();
    if (!ok) {
      unawaited(SerialDebugLogger.instance.log('USB串口打开失败'));
      _notify(false, 'USB串口打开失败');
      return false;
    }
    try {
      await port.setDTR(true);
      await port.setRTS(true);
    } catch (e) {
      debugPrint('设置DTR/RTS失败（可忽略）: $e');
    }
    await port.setPortParameters(
      baudRate,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );
    _usbPort = port;
    _usingTty = false;
    _usbRxSub = port.inputStream?.listen(
      (data) => onData?.call(data),
      onError: (error) {
        debugPrint('USB串口接收错误: $error');
        unawaited(close(status: 'USB串口接收错误'));
      },
      onDone: () {
        unawaited(close(status: 'USB串口已关闭'));
      },
    );
    _open = true;
    final name = device.productName ?? device.deviceName;
    unawaited(SerialDebugLogger.instance.log('USB串口已打开 $name $baudRate 8N1 VID=${device.vid} PID=${device.pid}'));
    _notify(true, '串口已打开 $name $baudRate 8N1');
    return true;
  }

  Future<bool> _openTty() async {
    const path = androidTtyPort;
    try {
      final ok = await _ttyChannel.invokeMethod<bool>('open', {
        'path': path,
        'baud': baudRate,
      });
      if (ok == true) {
        _usingTty = true;
        _open = true;
        unawaited(SerialDebugLogger.instance.log('板载TTL已打开 $path（COM7/TTL7） $baudRate 8N1'));
        _notify(true, '串口已打开 $path（COM7/TTL7） $baudRate 8N1');
        return true;
      }
      unawaited(SerialDebugLogger.instance.log('板载TTL打开失败: $path'));
    } catch (e) {
      unawaited(SerialDebugLogger.instance.log('板载TTL打开异常 $path: $e'));
    }
    return false;
  }

  void _listenTtyRx() {
    _ttyRxSub ??= _ttyRx.receiveBroadcastStream().listen((event) {
      _emitRx(event);
    });
  }

  void _listenWinRx() {
    _winRxSub ??= _winRx.receiveBroadcastStream().listen((event) {
      _emitRx(event);
    });
  }

  void _emitRx(dynamic event) {
    _lastRxAt = DateTime.now();
    if (event is Uint8List) {
      onData?.call(event);
    } else if (event is List) {
      onData?.call(Uint8List.fromList(List<int>.from(event)));
    }
  }

  Future<void> _recoverIfRxStopped() async {
    if (_disposed || !_open || !_usingTty || _opening) return;
    final lastTx = _lastTxAt;
    if (lastTx == null) return;
    final now = DateTime.now();
    if (now.difference(lastTx).inSeconds > 5) return;
    final lastRx = _lastRxAt;
    final silent = lastRx == null ? now.difference(lastTx) : now.difference(lastRx);
    if (silent.inSeconds < 8) return;
    unawaited(SerialDebugLogger.instance.log('超过8秒无接收，重开 /dev/ttyS7'));
    await close(status: '串口读超时，正在重开 /dev/ttyS7');
    if (_disposed) return;
    await open();
  }

  Future<bool> write(List<int> bytes) async {
    if (!_open) return false;
    final data = Uint8List.fromList(bytes);
    try {
      bool ok;
      if (_usingWindows) {
        ok = await _winChannel.invokeMethod<bool>('write', {'data': data}) == true;
      } else if (_usingTty) {
        ok = await _ttyChannel.invokeMethod<bool>('write', {'data': data}) == true;
      } else {
        await _usbPort?.write(data);
        ok = true;
      }
      if (ok) {
        _lastTxAt = DateTime.now();
      }
      return ok;
    } catch (e) {
      unawaited(SerialDebugLogger.instance.log('串口写入失败: $e'));
      return false;
    }
  }

  Future<void> close({String? status}) async {
    final wasOpen = _open;
    _open = false;
    await _usbRxSub?.cancel();
    _usbRxSub = null;
    try {
      await _usbPort?.close();
    } catch (_) {}
    _usbPort = null;
    if (_usingWindows) {
      try {
        await _winChannel.invokeMethod('close');
      } catch (_) {}
    }
    if (_usingTty) {
      try {
        await _ttyChannel.invokeMethod('close');
      } catch (_) {}
    }
    _usingTty = false;
    _usingWindows = false;
    _lastRxAt = null;
    _lastTxAt = null;
    if (wasOpen || status != null) {
      _notify(false, status ?? '串口未打开');
    }
  }

  Future<void> stop() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _rxWatchdog?.cancel();
    _rxWatchdog = null;
    await _usbEventSub?.cancel();
    _usbEventSub = null;
    await _ttyRxSub?.cancel();
    _ttyRxSub = null;
    await _winRxSub?.cancel();
    _winRxSub = null;
    await close(status: '串口已停止');
  }

  void _notify(bool open, String status) {
    onStatus?.call(open, status);
  }
}
