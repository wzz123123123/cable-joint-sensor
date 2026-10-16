import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 现场串口/连接调试日志，写成普通 txt，方便拷出来。
class SerialDebugLogger {
  SerialDebugLogger._();
  static final SerialDebugLogger instance = SerialDebugLogger._();

  static const String fileName = '电缆接头_串口调试.log';
  static const int _maxBytes = 3 * 1024 * 1024;

  final List<File> _files = [];
  Future<void> _chain = Future.value();
  bool _ready = false;
  String? displayPath;

  Future<void> initialize() async {
    _files.clear();
    final paths = <String>[];

    Future<void> addPath(String path) async {
      try {
        final file = File(path);
        await file.parent.create(recursive: true);
        if (!await file.exists()) {
          await file.create(recursive: true);
        }
        final resolved = file.absolute.path;
        if (paths.any((existing) => File(existing).absolute.path == resolved)) {
          return;
        }
        _files.add(file);
        paths.add(path);
      } catch (_) {}
    }

    try {
      final docs = await getApplicationDocumentsDirectory();
      await addPath('${docs.path}${Platform.pathSeparator}logs${Platform.pathSeparator}$fileName');
    } catch (_) {}

    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        await addPath('${ext.path}${Platform.pathSeparator}$fileName');
      }
    } catch (_) {}

    if (Platform.isAndroid) {
      await addPath('/storage/emulated/0/Download/$fileName');
      await addPath('/storage/emulated/0/Documents/$fileName');
    }

    displayPath = paths.isEmpty ? '日志文件创建失败' : paths.first;
    _ready = _files.isNotEmpty;
    await log('==== 串口调试日志启动 ==== 版本=1.0.22 固定口=/dev/ttyS7 波特率=19200 节点=8/9 等待200ms无返回则询下一站');
    for (final path in paths) {
      await log('日志文件: $path');
    }
  }

  Future<void> log(String message) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts =
        '${now.year}:${two(now.month)}:${two(now.day)}:${two(now.hour)}:${two(now.minute)}:${two(now.second)}.${now.millisecond.toString().padLeft(3, '0')}';
    final line = '[$ts]$message';
    // ignore: avoid_print
    print(line);
    if (!_ready && _files.isEmpty) {
      return Future.value();
    }
    _chain = _chain.then((_) => _append(line));
    return _chain;
  }

  int _txCount = 0;
  int _rxCount = 0;

  void logTx(List<int> data, {int? nodeId}) {
    _txCount++;
    if (_txCount % 20 != 1) return;
    final node = nodeId == null ? '' : ' 节点$nodeId';
    unawaited(log('[发送]$_txCount$node ${toHex(data)}'));
  }

  void logRx(List<int> data) {
    _rxCount++;
    if (_rxCount % 20 != 1) return;
    unawaited(log('[接收]#$_rxCount ${data.length}字节 ${toHex(data)}'));
  }

  static String toHex(List<int> data, {int maxBytes = 180}) {
    final shown = data.length > maxBytes ? data.sublist(0, maxBytes) : data;
    final hex = shown
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    if (data.length > maxBytes) {
      return '$hex ... (共${data.length}字节)';
    }
    return hex;
  }

  Future<void> _append(String line) async {
    final text = '$line\n';
    for (final file in List<File>.from(_files)) {
      try {
        if (await file.exists()) {
          final len = await file.length();
          if (len > _maxBytes) {
            await file.writeAsString(
              '==== 日志过大，已截断后继续 ====\n$text',
              flush: true,
            );
            continue;
          }
        }
        await file.writeAsString(text, mode: FileMode.append, flush: false);
      } catch (_) {}
    }
  }
}
