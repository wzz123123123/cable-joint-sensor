import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sensor_data_service.dart';
import 'alert_service.dart';
import 'settings_service.dart';
import 'serial_debug_logger.dart';
import '../models/node_data.dart';

class CsvLoggerService {
  CsvLoggerService._internal();
  static final CsvLoggerService instance = CsvLoggerService._internal();

  final Map<int, int> _lastWrittenEpochSecondByNode = <int, int>{};
  final Map<int, SensorData> _latestByNode = <int, SensorData>{};
  final Map<int, DateTime?> _currentDateByNode = <int, DateTime?>{}; // 每个节点的当前日期
  final Map<int, File?> _currentFileByNode = <int, File?>{};
  final List<Directory> _logDirs = [];
  final Set<int> _flushingNodes = <int>{};
  bool _isConnected = false;
  Timer? _flushTimer;
  String? _customLogsPath;
  String? displayPath;
  
  // 历史数据发送回调
  Function(int nodeId, dynamic data)? _onHistoryDataSend;

  void setConnectionStatus(bool connected) {
    _isConnected = connected;
    // 调试日志
    // ignore: avoid_print
    print('[CSV] setConnectionStatus: $_isConnected');
  }

  // 设置历史数据发送回调
  void setHistoryDataSendCallback(Function(int nodeId, dynamic data)? callback) {
    _onHistoryDataSend = callback;
  }

  // 初始化服务，加载保存的路径设置
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _customLogsPath = prefs.getString('custom_logs_path');
    await _resolveLogDirs();
    for (final nodeId in const [8, 9]) {
      try {
        await _ensureNodeTodayFile(nodeId);
        await _allNodeRawFiles(nodeId, DateTime.now());
      } catch (e) {
        print('[CSV] 预创建节点$nodeId文件失败: $e');
      }
    }
    print('[CSV] 数据记录目录: $displayPath');
  }

  // 设置自定义日志保存路径
  Future<void> setCustomLogsPath(String path) async {
    _customLogsPath = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_logs_path', path);
    print('[CSV] 设置自定义日志路径: $path');
    
    // 重置当前文件引用，下次访问时会使用新路径
    _currentFileByNode.clear();
    _currentDateByNode.clear();
    await _resolveLogDirs();
  }

  // 获取当前日志保存路径
  Future<String> getCurrentLogsPath() async {
    final dir = await _getLogsDir();
    return dir.path;
  }

  // 重置为默认路径
  Future<void> resetToDefaultPath() async {
    _customLogsPath = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('custom_logs_path');
    print('[CSV] 重置为默认路径');
    _currentFileByNode.clear();
    _currentDateByNode.clear();
    await _resolveLogDirs();
  }

  void start() {
    if (_flushTimer != null) {
      print('[CSV] 定时器已在运行，跳过重复启动');
      return;
    }
    unawaited(_resolveLogDirs());
    _flushTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
      try {
        for (final nodeId in _latestByNode.keys.toList()) {
          await _flushNode(nodeId);
        }
      } catch (e) {
        print('[CSV] periodic flush failed: $e');
        unawaited(SerialDebugLogger.instance.log('[CSV] 定时写入失败: $e'));
      }
    });
    print('[CSV] CSV保存已启动 - 有数据立即写首条，之后每分钟一条');
  }

  void stop() {
    _flushTimer?.cancel();
    _flushTimer = null;
    print('[CSV] CSV保存定时器已停止');
  }

  Future<void> _resolveLogDirs() async {
    _logDirs.clear();
    Future<void> addDir(String path) async {
      try {
        final logs = Directory(path);
        await logs.create(recursive: true);
        if (_logDirs.any((d) => d.path == logs.path)) return;
        _logDirs.add(logs);
      } catch (e) {
        print('[CSV] 无法使用目录 $path: $e');
      }
    }

    if (_customLogsPath != null) {
      await addDir(_customLogsPath!);
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      await addDir('${docs.path}${Platform.pathSeparator}logs');
    } catch (_) {}
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        await addDir('${ext.path}${Platform.pathSeparator}电缆接头数据');
      }
    } catch (_) {}
    if (Platform.isAndroid) {
      await addDir('/storage/emulated/0/Download/电缆接头数据');
      await addDir('/storage/emulated/0/Documents/电缆接头数据');
      await addDir('/storage/emulated/0/Android/data/com.example.sensor_flutter/files/电缆接头数据');
    }
    displayPath = _logDirs.isEmpty ? '数据目录创建失败' : _logDirs.map((d) => d.path).join(' | ');
  }

  Future<Directory> _getLogsDir() async {
    if (_logDirs.isEmpty) {
      await _resolveLogDirs();
    }
    if (_logDirs.isNotEmpty) return _logDirs.first;
    final dir = await getApplicationDocumentsDirectory();
    final logs = Directory('${dir.path}${Platform.pathSeparator}logs');
    await logs.create(recursive: true);
    return logs;
  }

  Future<List<File>> _allNodeTodayFiles(int nodeId) async {
    if (_logDirs.isEmpty) {
      await _resolveLogDirs();
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final nodeName = _nodeFolderName(nodeId);
    final files = <File>[];
    for (final base in _logDirs) {
      try {
        final nodeDir = Directory('${base.path}${Platform.pathSeparator}$nodeName');
        await nodeDir.create(recursive: true);
        final file = File('${nodeDir.path}${Platform.pathSeparator}${_nodeCsvName(nodeId, today)}');
        if (!await file.exists()) {
          await file.create(recursive: true);
          await file.writeAsString(_buildHeaderLine(), mode: FileMode.write, flush: true, encoding: utf8);
        }
        files.add(file);
      } catch (e) {
        print('[CSV] 创建${base.path}/$nodeName 失败: $e');
      }
    }
    return files;
  }

  Future<void> _flushNode(int nodeId) async {
    if (_flushingNodes.contains(nodeId)) return;
    final snap = _latestByNode[nodeId];
    if (snap == null) return;
    final now = DateTime.now();
    final epochMin = now.millisecondsSinceEpoch ~/ (1000 * 60);
    final last = _lastWrittenEpochSecondByNode[nodeId];
    if (last != null && last == epochMin) return;
    _flushingNodes.add(nodeId);
    _lastWrittenEpochSecondByNode[nodeId] = epochMin;
    try {
      final merged = _materializeSnapshot(nodeId, snap);
      final status = _computeStatus(merged);
      if (status == 'EMPTY' || status == 'INVALID') {
        _lastWrittenEpochSecondByNode.remove(nodeId);
        return;
      }
      String line;
      try {
        line = await _toCsvLine(now, merged, status);
      } catch (e) {
        unawaited(SerialDebugLogger.instance.log('[CSV] 组装行失败，本分钟跳过: $e'));
        _lastWrittenEpochSecondByNode.remove(nodeId);
        return;
      }
      final files = await _allNodeTodayFiles(nodeId);
      if (files.isEmpty) {
        throw Exception('没有任何可写的数据目录');
      }
      for (final file in files) {
        await file.writeAsString(line, mode: FileMode.append, flush: true, encoding: utf8);
      }
      _currentFileByNode[nodeId] = files.first;
      _currentDateByNode[nodeId] = DateTime(now.year, now.month, now.day);
      unawaited(SerialDebugLogger.instance.log(
          '[CSV] 节点$nodeId 已写入 ${files.length} 个文件 状态=$status 例:${files.first.path}'));
      _sendHistoryDataToServer(nodeId, merged);
    } catch (e) {
      _lastWrittenEpochSecondByNode.remove(nodeId);
      unawaited(SerialDebugLogger.instance.log('[CSV] 节点$nodeId 写入失败: $e'));
    } finally {
      _flushingNodes.remove(nodeId);
    }
  }

  // 获取指定节点的日志目录
  Future<Directory> _getNodeLogsDir(int nodeId) async {
    final baseDir = await _getLogsDir();
    final nodeDir = Directory('${baseDir.path}${Platform.pathSeparator}${_nodeFolderName(nodeId)}');
    if (!await nodeDir.exists()) {
      await nodeDir.create(recursive: true);
    }
    return nodeDir;
  }

  // 为指定节点确保当天文件存在
  Future<File> _ensureNodeTodayFile(int nodeId) async {
    final files = await _allNodeTodayFiles(nodeId);
    if (files.isEmpty) {
      throw Exception('无法创建节点$nodeId数据文件');
    }
    final now = DateTime.now();
    _currentFileByNode[nodeId] = files.first;
    _currentDateByNode[nodeId] = DateTime(now.year, now.month, now.day);
    print('[CSV] using node file: ${files.first.path}');
    return files.first;
  }

  // 检查并更新节点CSV文件头部
  Future<void> _checkAndUpdateNodeHeader(File file) async {
    try {
      final content = await file.readAsString(encoding: utf8);
      final lines = content.split('\n');
      if (lines.isNotEmpty) {
        final header = lines[0];
        // 检查是否包含新的列
        if (!header.contains('warnings') || !header.contains('faults')) {
          // 备份现有数据
          final dataLines = lines.skip(1).where((line) => line.trim().isNotEmpty).toList();
          final backupContent = dataLines.join('\n');
          
          // 重新写入文件，包含新头部
          await file.writeAsString(_buildHeaderLine() + backupContent, mode: FileMode.write, flush: true, encoding: utf8);
          // ignore: avoid_print
          print('[CSV] updated node file header with new columns');
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[CSV] error checking node header: $e');
    }
  }


  String _dateToName(DateTime d) {
    String to2(int n) => n < 10 ? '0$n' : '$n';
    return '${d.year}-${to2(d.month)}-${to2(d.day)}';
  }

  String _nodeFolderName(int nodeId) => '节点$nodeId';

  String _legacyNodeFolderName(int nodeId) =>
      'node_${nodeId.toString().padLeft(2, '0')}';

  String _nodeCsvName(int nodeId, DateTime date) =>
      '节点${nodeId}_${_dateToName(date)}.csv';

  Future<void> _rawWriteChain = Future.value();

  String _nodeRawCsvName(int nodeId, DateTime date) =>
      '节点${nodeId}_${_dateToName(date)}_raw.csv';

  Future<List<File>> _allNodeRawFiles(int nodeId, DateTime date) async {
    if (_logDirs.isEmpty) {
      await _resolveLogDirs();
    }
    final nodeName = _nodeFolderName(nodeId);
    final files = <File>[];
    for (final base in _logDirs) {
      try {
        final nodeDir = Directory('${base.path}${Platform.pathSeparator}$nodeName');
        await nodeDir.create(recursive: true);
        final file = File('${nodeDir.path}${Platform.pathSeparator}${_nodeRawCsvName(nodeId, date)}');
        if (!await file.exists()) {
          await file.create(recursive: true);
          await file.writeAsString(
            'time,epoch_ms,node_id,direction,hex_data\n',
            mode: FileMode.write,
            flush: true,
            encoding: utf8,
          );
        }
        files.add(file);
      } catch (e) {
        print('[CSV] 创建收发记录失败 ${base.path}/$nodeName: $e');
      }
    }
    return files;
  }

  List<String> _nodeCsvRelativeCandidates(int nodeId, DateTime date) {
    final dateName = _dateToName(date);
    final csvName = _nodeCsvName(nodeId, date);
    final folder = _nodeFolderName(nodeId);
    final legacyFolder = _legacyNodeFolderName(nodeId);
    final sep = Platform.pathSeparator;
    return [
      '$folder$sep$csvName',
      '$legacyFolder$sep$dateName.csv',
      '$legacyFolder$sep$csvName',
      '$folder$sep$dateName.csv',
    ];
  }

  String _buildHeaderLine() {
    const headers = [
      'time',
      'epoch_ms',
      'node_id',
      'sensor_type',
      'upper_temp',           // 上温度
      'middle_temp',           // 中温度
      'lower_temp',            // 下温度
      'humidity',
      'co_ppm',
      'h2_percentage',
      'pressure_kpa',
      'smoke_status',
      'smoke_external_temp_c',
      'white_smoke',
      'black_smoke',
      'a_left','a_middle','a_right',    // A相左外、A相中、A相右外
      'b_left','b_middle','b_right',    // B相左外、B相中、B相右外
      'c_left','c_middle','c_right',    // C相左外、C相中、C相右外
      'a_core','b_core','c_core',       // A/B/C相中内温度
      'status', // OK/EMPTY/INVALID/DISCONNECTED
      'warnings', // 预警信息
      'faults',   // 故障信息
    ];
    return headers.join(',') + '\n';
  }

  // 更新节点快照：只更新内存中的数据，不立即写入文件
  Future<void> appendParsedData(SensorData data) async {
    try {
      // 只更新内存中的快照，不写入文件
      updateNodeSnapshot(data);
      // ignore: avoid_print
      print('[CSV] updated snapshot node=${data.nodeId}');
    } catch (e) {
      // 避免影响主流程
      // ignore: avoid_print
      print('CSV更新快照失败: $e');
    }
  }

  // 更新节点快照：把非空字段合并到最新
  void updateNodeSnapshot(SensorData incoming) {
    if (incoming.nodeId != 8 && incoming.nodeId != 9) {
      return;
    }
    final current = _latestByNode[incoming.nodeId];
    if (current == null) {
      _latestByNode[incoming.nodeId] = incoming;
    } else {
      _latestByNode[incoming.nodeId] = SensorData(
        nodeId: incoming.nodeId,
        sensorType: current?.sensorType ?? incoming.sensorType,
        timestamp: incoming.timestamp,
        temperature: incoming.temperature ?? current.temperature,
        humidity: incoming.humidity ?? current.humidity,
        coPpm: incoming.coPpm ?? current.coPpm,
        h2Percentage: incoming.h2Percentage ?? current.h2Percentage,
        pressureKpa: incoming.pressureKpa ?? current.pressureKpa,
        pressureTempC: incoming.pressureTempC ?? current.pressureTempC,
        smokeStatus: incoming.smokeStatus ?? current.smokeStatus,
        smokeExternalTempC: incoming.smokeExternalTempC ?? current.smokeExternalTempC,
        smokeChannelA: incoming.smokeChannelA ?? current.smokeChannelA,
        smokeChannelB: incoming.smokeChannelB ?? current.smokeChannelB,
        pt100Temperatures: _mergePt100(incoming.pt100Temperatures, current.pt100Temperatures),
        fanStatus: incoming.fanStatus ?? current.fanStatus,
        fanTimer: incoming.fanTimer ?? current.fanTimer,
        stCoLen: incoming.stCoLen ?? current.stCoLen,
        stSmokeLen: incoming.stSmokeLen ?? current.stSmokeLen,
        stH2Len: incoming.stH2Len ?? current.stH2Len,
        stPt100Len: incoming.stPt100Len ?? current.stPt100Len,
        stThLen: incoming.stThLen ?? current.stThLen,
        stPressureLen: incoming.stPressureLen ?? current.stPressureLen,
      );
    }
    if (_lastWrittenEpochSecondByNode[incoming.nodeId] == null) {
      unawaited(_flushNode(incoming.nodeId));
    }
  }

  // 获取节点最新快照
  SensorData? getNodeSnapshot(int nodeId) {
    return _latestByNode[nodeId];
  }

  SensorData _materializeSnapshot(int nodeId, SensorData s) {
    // 确保pt100是序列化后的字符串
    if (s.pt100Temperatures != null) return s;
    return s;
  }

  String? _mergePt100(String? incoming, String? current) {
    if (incoming == null && current == null) return null;
    if (incoming == null) return current;
    if (current == null) return incoming;
    try {
      final a = (jsonDecode(incoming) as List).cast<num>().toList();
      final b = (jsonDecode(current) as List).cast<num>().toList();
      final len = a.length > b.length ? a.length : b.length;
      final out = List<num>.generate(len, (i) {
        final av = i < a.length ? a[i] : null;
        final bv = i < b.length ? b[i] : null;
        return av ?? bv ?? -999;
      });
      return jsonEncode(out);
    } catch (_) {
      return incoming;
    }
  }

  Future<String> _toCsvLine(DateTime now, SensorData d, String status) async {
    String fmtNum(num? v) => v == null ? '' : v.toString();
    String fmtTemp(num? v) => v == null || v == -999 ? '' : v.toStringAsFixed(2);
    String fmtH2(num? v) => v == null ? '' : v.toStringAsFixed(2);
    String fmtSmoke(num? v) => v == null ? '' : v.toStringAsFixed(2);
    String fmtHumidity(num? v) => v == null ? '' : v.toStringAsFixed(1);
    String fmtPressure(num? v) => v == null ? '' : v.toStringAsFixed(1);
    String fmtCO(num? v) => v == null ? '' : v.toStringAsFixed(1);
    final timeText = now.toIso8601String();
    final pt = _pt12(d.pt100Temperatures);
    final cores = _computePhaseCores(pt, d.temperature, d.pressureTempC);

    final nodeSettings = await SettingsService().getAllSettingsForNode(d.nodeId);
    double _thr(dynamic v, double fallback) {
      final n = (v as num?)?.toDouble();
      if (n == null || n <= 0) return fallback;
      return n;
    }
    final tempWarning = _thr(nodeSettings['tempWarning'], 85);
    final tempFault = _thr(nodeSettings['tempFault'], 90);

    final defUpper = pt.length >= 10 && pt[9] != null && pt[9] != -999 ? pt[9]! : (d.temperature ?? 25);
    final defMiddle = pt.length >= 12 && pt[11] != null && pt[11] != -999 ? pt[11]! : (d.temperature ?? 25);
    final defLower = d.temperature ?? 25;
    final upperTemp = defUpper;
    final middleTemp = defMiddle;
    final lowerTemp = defLower;

    final whiteSmoke = _processSmokeChannel(d.smokeChannelA);
    final blackSmoke = _processSmokeChannel(d.smokeChannelB);

    double? humidityCorrected;
    if (d.humidity != null) {
      final corr = nodeSettings['humidityCorrection'] as double? ?? 0.0;
      humidityCorrected = ((d.humidity! + corr)).clamp(0, 100).toDouble();
    }

    final names = <String, num?>{
      '上': upperTemp,
      '中': middleTemp,
      '下': lowerTemp,
      'A相左外': pt[0],
      'A相中': pt[1],
      'A相右外': pt[2],
      'B相左外': pt[3],
      'B相中': pt[4],
      'B相右外': pt[5],
      'C相左外': pt[6],
      'C相中': pt[7],
      'C相右外': pt[8],
      'A相中内': cores[0],
      'B相中内': cores[1],
      'C相中内': cores[2],
    };
    final warnings = <String>[];
    final faults = <String>[];
    names.forEach((name, t) {
      if (t == null || t == -999) return;
      if (t >= tempFault) {
        faults.add('$name温度故障：${t.toStringAsFixed(1)}°C');
      } else if (t >= tempWarning) {
        warnings.add('$name温度预警：${t.toStringAsFixed(1)}°C');
      }
    });

    final row = [
      timeText,
      now.millisecondsSinceEpoch.toString(),
      d.nodeId.toString(),
      '',
      fmtTemp(upperTemp),
      fmtTemp(middleTemp),
      fmtTemp(lowerTemp),
      fmtHumidity(humidityCorrected),
      fmtCO(d.coPpm),
      fmtH2(d.h2Percentage),
      fmtPressure(d.pressureKpa),
      fmtNum(d.smokeStatus),
      fmtTemp(d.smokeExternalTempC),
      fmtSmoke(whiteSmoke),
      fmtSmoke(blackSmoke),
      fmtTemp(pt[0]), fmtTemp(pt[1]), fmtTemp(pt[2]),
      fmtTemp(pt[3]), fmtTemp(pt[4]), fmtTemp(pt[5]),
      fmtTemp(pt[6]), fmtTemp(pt[7]), fmtTemp(pt[8]),
      fmtTemp(cores[0]), fmtTemp(cores[1]), fmtTemp(cores[2]),
      status,
      _escapeCsv(warnings.isEmpty ? '无' : warnings.join(';')),
      _escapeCsv(faults.isEmpty ? '无' : faults.join(';')),
    ];
    return row.join(',') + '\n';
  }

  List<num?> _pt12(String? s) {
    try {
      if (s == null || s.isEmpty) return List<num?>.filled(12, null);
      final arr = (jsonDecode(s) as List).cast<num>();
      final out = List<num?>.filled(12, null);
      for (int i = 0; i < out.length && i < arr.length; i++) {
        out[i] = arr[i];
      }
      return out;
    } catch (_) {
      return List<num?>.filled(12, null);
    }
  }

  // 计算A/B/C相中内温度（与详情页一致的公式近似）：
  // core = x + 6.42 * (x - env) + 2.5 * (x - phaseAvg)
  // A相: 使用pt1/pt2/pt3，B相: pt4/pt5/pt6，C相: pt7/pt8/pt9
  // env 参考：上温度取 d.temperature（中温度），下温度取 d.pressureTempC；此处优先用中温度作为环境。
  List<num?> _computePhaseCores(List<num?> pt, num? envMid, num? envLow) {
    num? coreFor(List<num?> tri, num? env) {
      if (tri.any((e) => e == null || e == -999)) return null;
      final xL = tri[0]!; final xM = tri[1]!; final xR = tri[2]!;
      final phaseAvg = (xL + xM + xR) / 3.0;
      final x = xM; // 以中外作为代表
      final envT = (env ?? envMid ?? envLow);
      if (envT == null) return null;
      final dxEnv = x - envT;
      final dxAvg = x - phaseAvg;
      final incEnv = dxEnv > 0 ? dxEnv : 0;
      final incAvg = dxAvg > 0 ? dxAvg : 0;
      return x + 6.42 * incEnv + 2.5 * incAvg;
    }
    final a = coreFor([pt[0], pt[1], pt[2]], envMid);
    final b = coreFor([pt[3], pt[4], pt[5]], envMid);
    final c = coreFor([pt[6], pt[7], pt[8]], envMid);
    return [a, b, c];
  }

  // 烟雾通道处理：可根据实际算法调整
  num? _processSmokeChannel(int? raw) {
    if (raw == null) return null;
    final x0 = raw.toDouble();
    if (x0 < 1610) {
      return 0.0;
    }
    if (x0 > 1610 && x0 < 2178) {
      return -0.0000001371 * x0 * x0 + 0.001136 * x0 - 1.473;
    }
    // x0 >= 2178 使用自然对数
    return 0.6061 * math.log(x0) - 4.308;
  }

  String _escapeCsv(String? s) {
    if (s == null) return '';
    final needsQuote = s.contains(',') || s.contains('"') || s.contains('\n');
    var v = s.replaceAll('"', '""');
    return needsQuote ? '"$v"' : v;
  }

  // 将SensorData转换为NodeData以使用预警服务
  NodeData _sensorDataToNodeData(SensorData data) {
    return NodeData(
      nodeId: data.nodeId,
      temperature: data.temperature,
      humidity: data.humidity,
      coPpm: data.coPpm,
      h2Percentage: data.h2Percentage,
      pressureKpa: data.pressureKpa,
      pressureTempC: data.pressureTempC,
      smokeAlarm: data.smokeStatus == 1,
      smokeRatio: data.smokeStatus?.toDouble(),
      smokeAlarmCount: data.smokeStatus,
      smokeExternalTempC: data.smokeExternalTempC,
      smokeChannelA: data.smokeChannelA,
      smokeChannelB: data.smokeChannelB,
      pt100Temperatures: _parsePt100Temperatures(data.pt100Temperatures),
      lastUpdate: DateTime.now().toIso8601String(),
      lastUpdateTimestamp: DateTime.now().millisecondsSinceEpoch,
      // 状态帧字段 - 这里需要根据实际情况设置
      stCoLen: data.coPpm != null ? 1 : 0,
      stSmokeLen: (data.smokeChannelA != null || data.smokeChannelB != null) ? 1 : 0,
      stH2Len: data.h2Percentage != null ? 1 : 0,
      stPt100Len: _parsePt100Temperatures(data.pt100Temperatures)?.isNotEmpty == true ? 1 : 0,
      stThLen: (data.temperature != null || data.humidity != null) ? 1 : 0,
      stPressureLen: data.pressureKpa != null ? 1 : 0,
    );
  }

  // 解析PT100温度数据
  List<double>? _parsePt100Temperatures(String? pt100Data) {
    if (pt100Data == null || pt100Data.isEmpty) return null;
    try {
      final arr = (jsonDecode(pt100Data) as List).cast<num>();
      return arr.map((e) => e.toDouble()).toList();
    } catch (_) {
      return null;
    }
  }

  String _computeStatus(SensorData d) {
    if (!_isConnected) return 'DISCONNECTED';
    final isAllEmpty = d.temperature == null &&
        d.humidity == null &&
        d.coPpm == null &&
        d.h2Percentage == null &&
        d.pressureKpa == null &&
        d.pressureTempC == null &&
        d.smokeStatus == null &&
        d.smokeExternalTempC == null &&
        d.smokeChannelA == null &&
        d.smokeChannelB == null &&
        (d.pt100Temperatures == null || d.pt100Temperatures!.isEmpty);
    if (isAllEmpty) return 'EMPTY';

    // 检查PT100数据质量：如果所有PT100通道都是-999，则视为无效
    if (d.pt100Temperatures != null) {
      try {
        final arr = (jsonDecode(d.pt100Temperatures!) as List).cast<num>();
        // 检查前9个通道（A/B/C相的主要测点）是否全部为-999
        final mainChannels = arr.take(9).toList();
        if (mainChannels.isNotEmpty && mainChannels.every((e) => e == -999)) {
          return 'INVALID';
        }
        // 如果主要通道有有效数据，即使某些通道是-999也认为是正常的
      } catch (_) {}
    }
    return 'OK';
  }

  // 清空指定节点当天数据
  Future<void> clearNodeTodayData(int nodeId) async {
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      if (_logDirs.isEmpty) {
        await _resolveLogDirs();
      }
      for (final base in _logDirs) {
        for (final rel in _nodeCsvRelativeCandidates(nodeId, today)) {
          final file = File('${base.path}${Platform.pathSeparator}$rel');
          if (await file.exists()) {
            await file.delete();
            print('[CSV] deleted node today file: ${file.path}');
          }
        }
      }

      _currentFileByNode[nodeId] = null;
      _currentDateByNode[nodeId] = null;
      print('[CSV] cleared node $nodeId today data');
    } catch (e) {
      print('[CSV] error clearing node $nodeId today data: $e');
      rethrow;
    }
  }

  // 清空所有节点当天数据
  Future<void> clearTodayData() async {
    try {
      // 清空所有已知节点的数据
      for (final nodeId in _currentFileByNode.keys) {
        await clearNodeTodayData(nodeId);
      }
      
      // ignore: avoid_print
      print('[CSV] cleared all nodes today data');
    } catch (e) {
      // ignore: avoid_print
      print('[CSV] error clearing all nodes today data: $e');
      rethrow;
    }
  }

  Future<File> ensureNodeFileForDate(int nodeId, DateTime date) async {
    final dir = await _getNodeLogsDir(nodeId);
    final f = File('${dir.path}${Platform.pathSeparator}${_nodeCsvName(nodeId, date)}');
    if (!await f.exists()) {
      await f.create(recursive: true);
      await f.writeAsString(_buildHeaderLine(), mode: FileMode.write, flush: true, encoding: utf8);
    }
    return f;
  }

  Future<File?> _findExistingNodeCsv(int nodeId, DateTime date) async {
    if (_logDirs.isEmpty) {
      await _resolveLogDirs();
    }
    for (final base in _logDirs) {
      for (final rel in _nodeCsvRelativeCandidates(nodeId, date)) {
        final f = File('${base.path}${Platform.pathSeparator}$rel');
        if (await f.exists()) {
          return f;
        }
      }
    }
    for (final base in _logDirs) {
      final combined = File('${base.path}${Platform.pathSeparator}${_dateToName(date)}.csv');
      if (await combined.exists()) {
        return combined;
      }
    }
    return null;
  }

  List<List<String>> _parseCsvText(String text, {required int onlyNodeId}) {
    final lines = LineSplitter.split(text).toList();
    if (lines.isEmpty) return <List<String>>[];
    return lines.skip(1).map(_splitCsvLine).where((row) {
      if (row.length < 3) return false;
      return int.tryParse(row[2].trim()) == onlyNodeId;
    }).toList();
  }

  // 读取指定节点某天CSV数据（新路径优先，兼容旧 node_08/日期.csv）
  Future<List<List<String>>> readNodeCsvByDate(int nodeId, DateTime date) async {
    try {
      final f = await _findExistingNodeCsv(nodeId, date);
      if (f == null) return <List<String>>[];
      try {
        final text = await f.readAsString(encoding: utf8);
        return _parseCsvText(text, onlyNodeId: nodeId);
      } catch (_) {
        final bytes = await f.readAsBytes();
        final text = utf8.decode(bytes, allowMalformed: true);
        return _parseCsvText(text, onlyNodeId: nodeId);
      }
    } catch (e) {
      print('[CSV] 读取节点文件失败: $e');
      return <List<String>>[];
    }
  }

  Future<List<List<String>>> readNodeCsvByTimeRange(
    int nodeId,
    DateTime startDateTime,
    DateTime endDateTime,
  ) async {
    try {
      final List<List<String>> allRows = [];
      
      // 获取时间范围内的所有日期
      final startDate = DateTime(startDateTime.year, startDateTime.month, startDateTime.day);
      final endDate = DateTime(endDateTime.year, endDateTime.month, endDateTime.day);
      
      // 遍历时间范围内的每一天
      DateTime currentDate = startDate;
      while (!currentDate.isAfter(endDate)) {
        try {
          final rows = await readNodeCsvByDate(nodeId, currentDate);
          allRows.addAll(rows);
        } catch (e) {
          // 如果某天的文件不存在，跳过
          print('[CSV] 读取节点${nodeId}日期${_dateToName(currentDate)}数据失败: $e');
        }
        currentDate = currentDate.add(const Duration(days: 1));
      }
      
      // 筛选时间范围内的数据
      final startMs = startDateTime.millisecondsSinceEpoch;
      final endMs = endDateTime.millisecondsSinceEpoch;
      
      final filteredRows = allRows.where((row) {
        if (row.length < 2) return false;
        try {
          final epochMs = int.tryParse(row[1]);
          if (epochMs == null) return false;
          return epochMs >= startMs && epochMs <= endMs;
        } catch (e) {
          return false;
        }
      }).toList();
      
      // 按时间戳排序（升序）
      filteredRows.sort((a, b) {
        try {
          final aMs = int.tryParse(a.length > 1 ? a[1] : '0') ?? 0;
          final bMs = int.tryParse(b.length > 1 ? b[1] : '0') ?? 0;
          return aMs.compareTo(bMs);
        } catch (e) {
          return 0;
        }
      });
      
      return filteredRows;
    } catch (e) {
      print('[CSV] 按时间范围读取节点文件失败: $e');
      return <List<String>>[];
    }
  }

  // 读取某天CSV内容（兼容旧接口：分别确保节点8、9文件）
  Future<File> ensureFileForDate(DateTime date) async {
    File? first;
    for (final nodeId in const [8, 9]) {
      final f = await ensureNodeFileForDate(nodeId, date);
      first ??= f;
    }
    return first!;
  }

  Future<List<List<String>>> readCsvByDate(DateTime date) async {
    final all = <List<String>>[];
    for (final nodeId in const [8, 9]) {
      all.addAll(await readNodeCsvByDate(nodeId, date));
    }
    return all;
  }

  List<String> _splitCsvLine(String line) {
    final List<String> out = [];
    final sb = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        out.add(sb.toString());
        sb.clear();
      } else {
        sb.write(ch);
      }
    }
    out.add(sb.toString());
    return out;
  }

  // 发送历史数据到远端服务器
  void _sendHistoryDataToServer(int nodeId, SensorData data) async {
    print('📤 CSV写入后发送历史数据: 节点$nodeId');
    try {
      final computedData = await _computeFullHistoryData(data);
      if (_onHistoryDataSend != null) {
        _onHistoryDataSend!(nodeId, computedData);
      }
    } catch (e) {
      print('❌ 计算历史数据失败: $e');
      if (_onHistoryDataSend != null) {
        _onHistoryDataSend!(nodeId, data); // Fallback to original data if computation fails
      }
    }
  }

  // 计算完整的历史数据
  Future<Map<String, dynamic>> _computeFullHistoryData(SensorData data) async {
    final pt = _pt12(data.pt100Temperatures);
    final cores = _computePhaseCores(pt, data.temperature, data.pressureTempC);

    final nodeData = _sensorDataToNodeData(data);
    final alertInfo = await AlertService().analyzeNodeData(nodeData);
    final warnings = alertInfo.warnings.isEmpty ? '无' : alertInfo.warnings.join(';');
    final faults = alertInfo.faults.isEmpty ? '无' : alertInfo.faults.join(';');

    final upperTemp = pt.length >= 10 && pt[9] != null && pt[9] != -999 ? pt[9]! : (data.temperature ?? 25);
    final middleTemp = pt.length >= 12 && pt[11] != null && pt[11] != -999 ? pt[11]! : (data.temperature ?? 25);
    final lowerTemp = data.pressureTempC ?? (data.temperature ?? 25);

    final whiteSmoke = _processSmokeChannel(data.smokeChannelA);
    final blackSmoke = _processSmokeChannel(data.smokeChannelB);

    final status = _computeStatus(data);

    final fullHistoryData = {
      'node_id': data.nodeId,
      'sensor_type': data.sensorType,
      'timestamp': data.timestamp,
      'temperature': data.temperature,
      'humidity': data.humidity,
      'co_ppm': data.coPpm,
      'h2_percentage': data.h2Percentage,
      'pressure_kpa': data.pressureKpa,
      'pressure_temp_c': data.pressureTempC,
      'smoke_status': data.smokeStatus,
      'smoke_external_temp_c': data.smokeExternalTempC,
      'smoke_channel_a': data.smokeChannelA,
      'smoke_channel_b': data.smokeChannelB,
      'pt100_temperatures': data.pt100Temperatures,

      'upper_temp': upperTemp,
      'middle_temp': middleTemp,
      'lower_temp': lowerTemp,

      'a_left': pt.length > 0 ? pt[0] : null,
      'a_middle': pt.length > 1 ? pt[1] : null,
      'a_right': pt.length > 2 ? pt[2] : null,
      'b_left': pt.length > 3 ? pt[3] : null,
      'b_middle': pt.length > 4 ? pt[4] : null,
      'b_right': pt.length > 5 ? pt[5] : null,
      'c_left': pt.length > 6 ? pt[6] : null,
      'c_middle': pt.length > 7 ? pt[7] : null,
      'c_right': pt.length > 8 ? pt[8] : null,

      'a_core': cores.length > 0 ? cores[0] : null,
      'b_core': cores.length > 1 ? cores[1] : null,
      'c_core': cores.length > 2 ? cores[2] : null,

      'white_smoke': whiteSmoke,
      'black_smoke': blackSmoke,

      'status': status,
      'warnings': warnings,
      'faults': faults,
    };
    return fullHistoryData;
  }

  // 保存数据传输日志（发送指令和接收完整帧），与传感器CSV写到同一批节点目录
  void saveDataTransferLog(int nodeId, String direction, List<int> data, DateTime timestamp) {
    if (nodeId != 8 && nodeId != 9) return;
    if (data.isEmpty) return;
    _rawWriteChain = _rawWriteChain.then((_) => _writeDataTransferLog(nodeId, direction, data, timestamp)).catchError((e) {
      print('[CSV] 收发记录写入链失败: $e');
    });
  }

  Future<void> _writeDataTransferLog(
    int nodeId,
    String direction,
    List<int> data,
    DateTime timestamp,
  ) async {
    try {
      final today = DateTime(timestamp.year, timestamp.month, timestamp.day);
      final files = await _allNodeRawFiles(nodeId, today);
      if (files.isEmpty) return;
      String to2(int n) => n < 10 ? '0$n' : '$n';
      final timeText =
          '${timestamp.year}-${to2(timestamp.month)}-${to2(timestamp.day)} ${to2(timestamp.hour)}:${to2(timestamp.minute)}:${to2(timestamp.second)}';
      final hexData = data
          .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
      final line =
          '$timeText,${timestamp.millisecondsSinceEpoch},$nodeId,$direction,"$hexData"\n';
      for (final file in files) {
        await file.writeAsString(line, mode: FileMode.append, flush: false, encoding: utf8);
      }
    } catch (e) {
      print('[CSV] 保存收发记录失败: $e');
    }
  }

}


