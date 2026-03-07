import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sensor_data_service.dart';
import 'alert_service.dart';
import 'settings_service.dart';
import '../models/node_data.dart';

class CsvLoggerService {
  CsvLoggerService._internal();
  static final CsvLoggerService instance = CsvLoggerService._internal();

  final Map<int, int> _lastWrittenEpochSecondByNode = <int, int>{};
  final Map<int, SensorData> _latestByNode = <int, SensorData>{};
  final Map<int, DateTime?> _currentDateByNode = <int, DateTime?>{}; // 每个节点的当前日期
  final Map<int, File?> _currentFileByNode = <int, File?>{}; // 每个节点的当前文件
  bool _isConnected = false;
  Timer? _flushTimer;
  String? _customLogsPath; // 自定义日志保存路径
  
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
    if (_customLogsPath != null) {
      print('[CSV] 使用自定义日志路径: $_customLogsPath');
    }
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
    
    // 重置当前文件引用
    _currentFileByNode.clear();
    _currentDateByNode.clear();
  }

  void start() {
    if (_flushTimer != null) {
      print('[CSV] 定时器已在运行，跳过重复启动');
      return;
    }
    _flushTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
      try {
        final now = DateTime.now();
        final epochMin = now.millisecondsSinceEpoch ~/ (1000 * 60); // 分钟级别时间戳
        // ignore: avoid_print
        print('[CSV] 定时器触发 - 时间:${now.toIso8601String()}, 分钟时间戳:$epochMin');
        // 为每个节点写入当前快照（每分钟一次）
        for (final entry in _latestByNode.entries) {
          final nodeId = entry.key;
          final snap = entry.value;
          final last = _lastWrittenEpochSecondByNode[nodeId];
          if (last != null && last == epochMin) {
            // ignore: avoid_print
            print('[CSV] skip write (same minute) node=$nodeId min=$epochMin');
            continue;
          }
          _lastWrittenEpochSecondByNode[nodeId] = epochMin;
          final merged = _materializeSnapshot(nodeId, snap);
          final status = _computeStatus(merged);
          final line = await _toCsvLine(now, merged, status);
          final file = await _ensureNodeTodayFile(nodeId);
          await file.writeAsString(line, mode: FileMode.append, flush: true, encoding: utf8);
          // ignore: avoid_print
          print('[CSV] 保存数据到CSV - 节点:$nodeId 状态:$status 时间:${now.toIso8601String()}');
          
          // 不再向远端服务器发送每分钟历史数据（仅本地CSV保存）
        }
      } catch (e) {
        // ignore: avoid_print
        print('[CSV] periodic flush failed: $e');
      }
    });
    // ignore: avoid_print
    print('[CSV] CSV保存定时器已启动 - 每分钟保存一次数据');
  }

  void stop() {
    _flushTimer?.cancel();
    _flushTimer = null;
    print('[CSV] CSV保存定时器已停止');
  }

  Future<Directory> _getLogsDir() async {
    // 如果有自定义路径，使用自定义路径
    if (_customLogsPath != null) {
      final logs = Directory(_customLogsPath!);
      if (!await logs.exists()) {
        await logs.create(recursive: true);
      }
      return logs;
    }
    
    // 否则使用默认路径
    final dir = await getApplicationDocumentsDirectory();
    final logs = Directory('${dir.path}${Platform.pathSeparator}logs');
    if (!await logs.exists()) {
      await logs.create(recursive: true);
    }
    return logs;
  }

  // 获取指定节点的日志目录
  Future<Directory> _getNodeLogsDir(int nodeId) async {
    final baseDir = await _getLogsDir();
    final nodeDir = Directory('${baseDir.path}${Platform.pathSeparator}node_${nodeId.toString().padLeft(2, '0')}');
    if (!await nodeDir.exists()) {
      await nodeDir.create(recursive: true);
    }
    return nodeDir;
  }

  // 为指定节点确保当天文件存在
  Future<File> _ensureNodeTodayFile(int nodeId) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final currentDate = _currentDateByNode[nodeId];
    final currentFile = _currentFileByNode[nodeId];
    
    if (currentDate == null || today.isAfter(currentDate)) {
      // 新的一天或首次
      _currentDateByNode[nodeId] = today;
      final dir = await _getNodeLogsDir(nodeId);
      final name = _dateToName(today);
      final file = File('${dir.path}${Platform.pathSeparator}$name.csv');
      _currentFileByNode[nodeId] = file;
      
      if (!await file.exists()) {
        await file.create(recursive: true);
        await file.writeAsString(_buildHeaderLine(), mode: FileMode.write, flush: true, encoding: utf8);
        // ignore: avoid_print
        print('[CSV] created node file: ${file.path}');
      } else {
        // 检查现有文件是否包含新列
        await _checkAndUpdateNodeHeader(file);
      }
    } else if (currentFile == null) {
      final dir = await _getNodeLogsDir(nodeId);
      final name = _dateToName(today);
      final file = File('${dir.path}${Platform.pathSeparator}$name.csv');
      _currentFileByNode[nodeId] = file;
      
      if (!await file.exists()) {
        await file.create(recursive: true);
        await file.writeAsString(_buildHeaderLine(), mode: FileMode.write, flush: true, encoding: utf8);
        // ignore: avoid_print
        print('[CSV] created node file: ${file.path}');
      } else {
        // 检查现有文件是否包含新列
        await _checkAndUpdateNodeHeader(file);
      }
    }
    // ignore: avoid_print
    print('[CSV] using node file: ${_currentFileByNode[nodeId]!.path}');
    return _currentFileByNode[nodeId]!;
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
    final current = _latestByNode[incoming.nodeId];
    if (current == null) {
      _latestByNode[incoming.nodeId] = incoming;
      return;
    }
    _latestByNode[incoming.nodeId] = SensorData(
      nodeId: incoming.nodeId,
      sensorType: incoming.sensorType, // 最近一次来源
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
    // ignore: avoid_print
    print('[CSV] _toCsvLine被调用 - 节点:${d.nodeId} 时间:${now.toIso8601String()}');
    String fmtNum(num? v) => v == null ? '' : v.toString();
    
    // 格式化函数：根据数据类型应用不同的小数位数
    String fmtTemp(num? v) => v == null ? '' : v.toStringAsFixed(2);
    String fmtH2(num? v) => v == null ? '' : v.toStringAsFixed(2);
    String fmtSmoke(num? v) => v == null ? '' : v.toStringAsFixed(2);
    String fmtHumidity(num? v) => v == null ? '' : v.toStringAsFixed(1);
    String fmtPressure(num? v) => v == null ? '' : v.toStringAsFixed(1);
    String fmtCO(num? v) => v == null ? '' : v.toStringAsFixed(1);
    final timeText = now.toIso8601String();
    final pt = _pt10(d.pt100Temperatures);
    final cores = _computePhaseCores(pt, d.temperature, d.pressureTempC);
    
    // 获取预警和故障信息
    final nodeData = _sensorDataToNodeData(d);
    final alertSvc = AlertService();
    final alertInfo = await alertSvc.analyzeNodeData(nodeData);
    final warnings = alertInfo.warnings.isEmpty ? '无' : alertInfo.warnings.join(';');
    final faults = alertInfo.faults.isEmpty ? '无' : alertInfo.faults.join(';');
    
    // 调试信息
    if (warnings.isNotEmpty || faults.isNotEmpty) {
      // ignore: avoid_print
      print('[CSV] Node ${d.nodeId} - Warnings: $warnings, Faults: $faults');
    }
    
    // 若有预/故障，优先使用异常前快照
    Map<String, num>? preSnap;
    if (alertInfo.level.toString() != 'AlertLevel.normal') {
      preSnap = alertSvc.getLastPreAlertSnapshot(d.nodeId);
    }
    num _pick(Map<String, num>? m, String k, num fallback) {
      if (m == null) return fallback;
      return m[k] ?? fallback;
    }
    // 计算上中下温度
    final defUpper = pt.length >= 10 && pt[9] != null && pt[9] != -999 ? pt[9]! : (d.temperature ?? 25);
    final upperTemp = preSnap != null ? _pick(preSnap, 'upper_temp', defUpper) : defUpper;
    final defMiddle = pt.length >= 12 && pt[11] != null && pt[11] != -999 ? pt[11]! : (d.temperature ?? 25);
    final middleTemp = preSnap != null ? _pick(preSnap, 'middle_temp', defMiddle) : defMiddle;
    final defLower = d.temperature ?? 25; // 下温度=温湿度传感器温度（与详细页面一致）
    final lowerTemp = preSnap != null ? _pick(preSnap, 'lower_temp', defLower) : defLower;
    
    // 烟雾通道处理
    final whiteSmoke = preSnap != null ? _pick(preSnap, 'white_smoke', _processSmokeChannel(d.smokeChannelA) ?? 0) : _processSmokeChannel(d.smokeChannelA);
    final blackSmoke = preSnap != null ? _pick(preSnap, 'black_smoke', _processSmokeChannel(d.smokeChannelB) ?? 0) : _processSmokeChannel(d.smokeChannelB);
    
    // 烟雾通道处理：若有温度（smoke_external_temp_c）与A/B通道，保留原值；
    // 如需"处理后数据"，可在此处应用换算或归一化并替换 channelA/channelB 的输出
    // 湿度修正
    double? humidityCorrected;
    if (d.humidity != null) {
      final nodeSettings = await SettingsService().getAllSettingsForNode(d.nodeId);
      final corr = nodeSettings['humidityCorrection'] as double? ?? 0.0;
      humidityCorrected = ((d.humidity! + corr)).clamp(0, 100).toDouble();
    }

    final row = [
      timeText,                                    // 0: 时间
      now.millisecondsSinceEpoch.toString(),      // 1: 毫秒时间戳
      d.nodeId.toString(),                        // 2: 节点
      d.sensorType.toString(),                    // 3: 传感器类型
      fmtTemp(upperTemp),                         // 4: 上温度(°C)
      fmtTemp(middleTemp),                        // 5: 中温度(°C)
      fmtTemp(lowerTemp),                         // 6: 下温度(°C)
      fmtHumidity(humidityCorrected),             // 7: 湿度(%RH)
      fmtCO(d.coPpm),                             // 8: CO(ppm)
      fmtH2(d.h2Percentage),                      // 9: H2(%LEL)
      fmtPressure(d.pressureKpa),                 // 10: 压力(kPa)
      fmtNum(d.smokeStatus),                      // 11: 烟雾状态(隐藏)
      fmtTemp(d.smokeExternalTempC),              // 12: 烟雾外温(°C)
      fmtSmoke(whiteSmoke),                       // 13: 白烟
      fmtSmoke(blackSmoke),                       // 14: 黑烟
      // 15-23: A/B/C相左中右温度 (PT1-PT9)
      fmtTemp(pt[0]), fmtTemp(pt[1]), fmtTemp(pt[2]),  // A相左外、A相中、A相右外
      fmtTemp(pt[3]), fmtTemp(pt[4]), fmtTemp(pt[5]),  // B相左外、B相中、B相右外
      fmtTemp(pt[6]), fmtTemp(pt[7]), fmtTemp(pt[8]),  // C相左外、C相中、C相右外
      // 24-26: A/B/C相中内温度
      fmtTemp(cores[0]), fmtTemp(cores[1]), fmtTemp(cores[2]), // A/B/C相中内
      // 27-29: 状态、预警信息、故障信息
      status,
      _escapeCsv(warnings),
      _escapeCsv(faults),
    ];
    return row.join(',') + '\n';
  }
  List<num?> _pt10(String? s) {
    try {
      if (s == null || s.isEmpty) return List<num?>.filled(10, null);
      final arr = (jsonDecode(s) as List).cast<num>();
      final out = List<num?>.filled(10, null);
      for (int i = 0; i < out.length && i < arr.length; i++) {
        out[i] = arr[i];
      }
      return out;
    } catch (_) {
      return List<num?>.filled(10, null);
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
      final dir = await _getNodeLogsDir(nodeId);
      final name = _dateToName(today);
      final file = File('${dir.path}${Platform.pathSeparator}$name.csv');
      
      if (await file.exists()) {
        await file.delete();
        // ignore: avoid_print
        print('[CSV] deleted node today file: ${file.path}');
      }
      
      // 重置当前文件引用，下次访问时会重新创建
      _currentFileByNode[nodeId] = null;
      _currentDateByNode[nodeId] = null;
      
      // ignore: avoid_print
      print('[CSV] cleared node $nodeId today data');
    } catch (e) {
      // ignore: avoid_print
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

  // 读取指定节点某天CSV内容
  Future<File> ensureNodeFileForDate(int nodeId, DateTime date) async {
    final dir = await _getNodeLogsDir(nodeId);
    final name = _dateToName(date);
    final f = File('${dir.path}${Platform.pathSeparator}$name.csv');
    if (!await f.exists()) {
      await f.create(recursive: true);
      await f.writeAsString(_buildHeaderLine(), mode: FileMode.write, flush: true, encoding: utf8);
    }
    return f;
  }

  // 读取指定节点某天CSV数据
  Future<List<List<String>>> readNodeCsvByDate(int nodeId, DateTime date) async {
    try {
      final f = await ensureNodeFileForDate(nodeId, date);
      // 尝试以UTF-8编码读取文件
      final text = await f.readAsString(encoding: utf8);
      final lines = LineSplitter.split(text).toList();
      if (lines.isEmpty) return <List<String>>[];
      return lines.skip(1).map((l) => _splitCsvLine(l)).toList();
    } catch (e) {
      // 如果UTF-8读取失败，尝试其他编码
      try {
        final f = await ensureNodeFileForDate(nodeId, date);
        final bytes = await f.readAsBytes();
        final text = utf8.decode(bytes, allowMalformed: true);
        final lines = LineSplitter.split(text).toList();
        if (lines.isEmpty) return <List<String>>[];
        return lines.skip(1).map((l) => _splitCsvLine(l)).toList();
      } catch (e2) {
        print('[CSV] 读取节点文件失败: $e2');
        return <List<String>>[];
      }
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

  // 读取某天CSV内容（兼容旧接口）
  Future<File> ensureFileForDate(DateTime date) async {
    final dir = await _getLogsDir();
    final name = _dateToName(date);
    final f = File('${dir.path}${Platform.pathSeparator}$name.csv');
    if (!await f.exists()) {
      await f.create(recursive: true);
      await f.writeAsString(_buildHeaderLine(), mode: FileMode.write, flush: true, encoding: utf8);
    }
    return f;
  }

  Future<List<List<String>>> readCsvByDate(DateTime date) async {
    try {
      final f = await ensureFileForDate(date);
      // 尝试以UTF-8编码读取文件
      final text = await f.readAsString(encoding: utf8);
      final lines = LineSplitter.split(text).toList();
      if (lines.isEmpty) return <List<String>>[];
      return lines.skip(1).map((l) => _splitCsvLine(l)).toList();
    } catch (e) {
      // 如果UTF-8读取失败，尝试其他编码
      try {
        final f = await ensureFileForDate(date);
        final bytes = await f.readAsBytes();
        final text = utf8.decode(bytes, allowMalformed: true);
        final lines = LineSplitter.split(text).toList();
        if (lines.isEmpty) return <List<String>>[];
        return lines.skip(1).map((l) => _splitCsvLine(l)).toList();
      } catch (e2) {
        print('[CSV] 读取文件失败: $e2');
        return <List<String>>[];
      }
    }
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
    final pt = _pt10(data.pt100Temperatures);
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

  // 保存数据传输日志（发送指令和接收数据）
  Future<void> saveDataTransferLog(int nodeId, String direction, List<int> data, DateTime timestamp) async {
    try {
      if (data.isEmpty) {
        // 如果数据为空，跳过保存
        return;
      }
      
      // 获取日志文件路径（在CSV文件名后加_raw后缀）
      final now = timestamp;
      final today = DateTime(now.year, now.month, now.day);
      final dir = await _getNodeLogsDir(nodeId);
      final name = _dateToName(today);
      final logFile = File('${dir.path}${Platform.pathSeparator}${name}_raw.csv');
      
      // 如果文件不存在，创建文件并写入表头
      if (!await logFile.exists()) {
        await logFile.create(recursive: true);
        // 表头：时间,毫秒时间戳,节点,方向,十六进制数据
        final header = 'time,epoch_ms,node_id,direction,hex_data\n';
        await logFile.writeAsString(header, mode: FileMode.write, flush: true, encoding: utf8);
      }
      
      // 将原始数据转换为十六进制字符串
      final hexData = data.map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
      
      // 格式化时间
      String to2(int n) => n < 10 ? '0$n' : '$n';
      final timeText = '${now.year}-${to2(now.month)}-${to2(now.day)} ${to2(now.hour)}:${to2(now.minute)}:${to2(now.second)}';
      
      // 写入数据行：时间,毫秒时间戳,节点,方向(发送/接收),十六进制数据
      final line = '$timeText,${now.millisecondsSinceEpoch},$nodeId,$direction,"$hexData"\n';
      await logFile.writeAsString(line, mode: FileMode.append, flush: true, encoding: utf8);
      
      print('[CSV] 保存数据传输日志 - 节点:$nodeId 方向:$direction 时间:${now.toIso8601String()} 长度:${data.length}字节');
    } catch (e) {
      print('[CSV] 保存数据传输日志失败: $e');
    }
  }

}


