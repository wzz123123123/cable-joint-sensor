import 'dart:async';
import 'dart:isolate';

import 'upload_isolate.dart';

/// 后台 isolate：编码并上传，不占用 RS485 轮询线程。
class BackgroundCpuService {
  BackgroundCpuService._();
  static final BackgroundCpuService instance = BackgroundCpuService._();

  SendPort? _workerPort;
  Isolate? _isolate;
  final Map<int, Map<String, dynamic>> _settingsByNode = {};

  Future<void> start() async {
    if (_workerPort != null) return;
    final ready = Completer<SendPort>();
    final inbox = ReceivePort();
    inbox.listen((msg) {
      if (msg is SendPort && !ready.isCompleted) ready.complete(msg);
    });
    _isolate = await Isolate.spawn(uploadIsolateMain, inbox.sendPort);
    _workerPort = await ready.future.timeout(const Duration(seconds: 3));
  }

  void updateSettings(int nodeId, Map<String, dynamic> settings) {
    _settingsByNode[nodeId] = settings;
    _workerPort?.send({'cmd': 'settings', 'nodeId': nodeId, 'settings': settings});
  }

  void submitUpload(Map<String, dynamic> snapshot) {
    final port = _workerPort;
    if (port == null) return;
    final nodeId = snapshot['node_id'] as int? ?? 0;
    port.send({
      'cmd': 'upload',
      'snapshot': snapshot,
      'settings': _settingsByNode[nodeId] ?? const <String, dynamic>{},
    });
  }

  void stop() {
    _workerPort?.send({'cmd': 'stop'});
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _workerPort = null;
  }
}
