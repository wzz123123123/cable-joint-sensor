import '../models/node_data.dart';
import 'settings_service.dart';
import 'ignore_service.dart';
import 'modbus_tcp_client.dart';
import 'sensor_data_service.dart';
import 'csv_logger_service.dart';
import 'rs485_protocol.dart';

// 预警和故障状态
enum AlertLevel {
  normal,    // 正常
  warning,   // 预警
  fault      // 故障
}

// 预警/故障信息
class AlertInfo {
  final AlertLevel level;
  final List<String> warnings;
  final List<String> faults;
  final String description;

  AlertInfo({
    required this.level,
    required this.warnings,
    required this.faults,
    required this.description,
  });
}

class AlertService {
  static final AlertService _instance = AlertService._internal();
  factory AlertService() => _instance;
  AlertService._internal();

  // 获取设置服务实例
  final SettingsService _settingsService = SettingsService();
  
  // 获取忽略服务实例
  final IgnoreService _ignoreService = IgnoreService();
  
  // Modbus TCP客户端
  final ModbusTcpClient _modbusClient = ModbusTcpClient();
  
  // SensorDataService 实例（用于获取节点连接状态）
  SensorDataService? _sensorDataService;
  
  // 设置 SensorDataService 实例
  void setSensorDataService(SensorDataService service) {
    _sensorDataService = service;
  }
  
  // 防重复发送：记录已发送的预警/故障信息
  final Map<String, DateTime> _lastSentAlerts = {};
  
  // 超阈值持续计时：key = "nodeId|metric|level"
  final Map<String, DateTime?> _overThresholdStartTimes = {};
  // 持续计时开始时的“异常前快照”：key 同上，value 为节点快照 Map
  final Map<String, Map<String, dynamic>?> _preAlertSnapshots = {};
  final Map<int, Map<String, dynamic>?> _lastPreAlertSnapshotByNode = {};

  Map<String, dynamic>? getLastPreAlertSnapshot(int nodeId) => _lastPreAlertSnapshotByNode[nodeId];
  
  // 判断是否达到持续超阈值时间窗口（例如40秒）
  bool _shouldTriggerHold(String key, bool isOverThreshold, int holdMs) {
    final now = DateTime.now();
    final start = _overThresholdStartTimes[key];
    if (isOverThreshold) {
      if (start == null) {
        _overThresholdStartTimes[key] = now;
        return false;
      }
      return now.difference(start).inMilliseconds >= holdMs;
    } else {
      // 条件恢复，清除计时
      _overThresholdStartTimes[key] = null;
      return false;
    }
  }
  
  // 启动Modbus TCP连接监控
  void startModbusConnection() {
    _modbusClient.startConnectionMonitoring();
    print('AlertService: Modbus TCP连接监控已启动');
  }
  
  // 停止Modbus TCP连接监控
  void stopModbusConnection() {
    _modbusClient.stopConnectionMonitoring();
    print('AlertService: Modbus TCP连接监控已停止');
  }
  
  // 判断是否应该发送预警/故障信息（防重复发送）
  bool _shouldSendAlert(String alertKey) {
    final now = DateTime.now();
    final lastSent = _lastSentAlerts[alertKey];
    
    if (lastSent == null) {
      return true; // 首次发送
    }
    
    // 故障信息：5分钟内不重复发送
    if (alertKey.startsWith('fault_')) {
      return now.difference(lastSent).inMinutes >= 5;
    }
    
    // 预警信息：10分钟内不重复发送
    if (alertKey.startsWith('warning_')) {
      return now.difference(lastSent).inMinutes >= 10;
    }
    
    return true;
  }

  // 湿度预警时间记录
  final Map<int, DateTime?> _humidityWarningStartTime = {};
  
  // 烟雾浓度历史记录：节点ID -> 烟雾浓度历史
  final Map<int, List<double>> _smokeHistory = {};
  
  // 温度历史记录：节点ID -> 温度历史（包含中内温度的完整温度数组）
  final Map<int, List<List<double>>> _temperatureHistory = {};
  
  // 上一次不同的温度值：节点ID -> 上一次最高温度
  final Map<int, double> _lastDifferentTemperature = {};
  
  // 温升预警状态：节点ID -> 预警结束时间
  final Map<int, DateTime> _temperatureGrowthAlerts = {};

  // 分析节点数据，返回预警/故障信息
  Future<AlertInfo> analyzeNodeData(NodeData nodeData) async {
    print('=== 开始分析节点${nodeData.nodeId}数据 ===');
    final warnings = <String>[];
    final faults = <String>[];
    
    // 获取节点特定的阈值设置
    final nodeSettings = await _settingsService.getAllSettingsForNode(nodeData.nodeId);
    print('节点${nodeData.nodeId}特定阈值设置: $nodeSettings');
    
    // 预先准备已修正的PT100温度数组（用于所有温度相关判断）
    final correctedPt100 = await _getCorrectedPt100Temps(nodeData);
    print('分析节点数据：原始PT100=${nodeData.pt100Temperatures}');
    print('分析节点数据：修正后PT100=$correctedPt100');
    
    // 1. 温度预警和故障判断（基于修正后的数据）
    await _checkTemperatureAlerts(nodeData, correctedPt100, warnings, faults, nodeSettings);
    
    // 2. 气体浓度和烟雾故障判断
    _checkGasAndSmokeAlerts(nodeData, warnings, faults, nodeSettings);
    
    // 3. 湿度预警和故障判断
    _checkHumidityAlerts(nodeData, warnings, faults, nodeSettings);
    
    // 4. 压力预警和故障判断
    _checkPressureAlerts(nodeData, warnings, faults, nodeSettings);
    
    // 5. 连接状态判断（保留原有逻辑）
    _checkConnectionStatus(nodeData, warnings, faults);
    
    // 6. 应用忽略规则过滤
    final filteredWarnings = _applyIgnoreRules(nodeData.nodeId.toString(), warnings, 'warning');
    final filteredFaults = _applyIgnoreRules(nodeData.nodeId.toString(), faults, 'fault');

    // 7. 预警和故障都需要持续40秒以上才显示
    const int warningHoldMs = 40000; // 预警持续40秒
    const int faultHoldMs = 40000;   // 故障持续40秒
    final String nodeKey = nodeData.nodeId.toString();
    final heldWarnings = <String>[];
    final heldFaults = <String>[];
    for (final w in filteredWarnings) {
      final key = '$nodeKey|warning|${w.hashCode}';
      if (_overThresholdStartTimes[key] == null) {
        // 保存异常前快照
        final snap = CsvLoggerService.instance.getNodeSnapshot(nodeData.nodeId);
        final map = snap?.toMap();
        _preAlertSnapshots[key] = map;
        _lastPreAlertSnapshotByNode[nodeData.nodeId] = map;
      }
      if (_shouldTriggerHold(key, true, warningHoldMs)) heldWarnings.add(w);
    }
    for (final f in filteredFaults) {
      final key = '$nodeKey|fault|${f.hashCode}';
      if (_overThresholdStartTimes[key] == null) {
        final snap = CsvLoggerService.instance.getNodeSnapshot(nodeData.nodeId);
        final map = snap?.toMap();
        _preAlertSnapshots[key] = map;
        _lastPreAlertSnapshotByNode[nodeData.nodeId] = map;
      }
      if (_shouldTriggerHold(key, true, faultHoldMs)) heldFaults.add(f);
    }
    
    // 确定最终状态
    AlertLevel level;
    if (heldFaults.isNotEmpty) {
      level = AlertLevel.fault;
    } else if (heldWarnings.isNotEmpty) {
      level = AlertLevel.warning;
    } else {
      level = AlertLevel.normal;
    }
    
    // 生成描述信息
    final allIssues = [...heldWarnings, ...heldFaults];
    final description = allIssues.isEmpty ? '系统正常' : allIssues.join('；');
    
    print('分析节点数据：原始预警=${warnings.length}条，原始故障=${faults.length}条');
    print('分析节点数据：过滤后预警=${filteredWarnings.length}条，过滤后故障=${filteredFaults.length}条');
    print('分析节点数据：最终状态=$level，描述=$description');
    print('=== 节点${nodeData.nodeId}数据分析完成 ===\n');
    
    // 发送预警和故障（485格式）
    for (final warning in heldWarnings) {
      _sendAlertRS485(nodeData, warning, true);
    }
    for (final fault in heldFaults) {
      _sendAlertRS485(nodeData, fault, false);
    }
    
    return AlertInfo(
      level: level,
      warnings: heldWarnings,
      faults: heldFaults,
      description: description,
    );
  }

  // 温度预警和故障判断
  Future<void> _checkTemperatureAlerts(NodeData nodeData, List<double>? correctedTemps, List<String> warnings, List<String> faults, Map<String, dynamic> nodeSettings) async {
    if (correctedTemps == null) {
      print('温度报警检查：PT100温度数据为空');
      return;
    }
    
    final temps = correctedTemps;
    final validTemps = temps.where((t) => t != -999).toList();
    
    // 获取节点特定的温度阈值
    final tempWarning = nodeSettings['tempWarning'] as double? ?? _settingsService.tempWarning;
    final tempFault = nodeSettings['tempFault'] as double? ?? _settingsService.tempFault;
    final tempStart = nodeSettings['tempStart'] as double? ?? _settingsService.tempStart;
    
    print('温度报警检查：原始温度=$temps');
    print('温度报警检查：有效温度=$validTemps');
    print('温度报警检查：预警阈值=${tempWarning}°C，故障阈值=${tempFault}°C');
    
    if (validTemps.isEmpty) {
      print('温度报警检查：无有效温度数据');
      return;
    }
    
    // 检查所有温度点的阈值（包括计算后的中内温度）
    await _checkAllTemperatureThresholdsWithInnerTemps(nodeData, correctedTemps, warnings, faults, nodeSettings);
    
    // 检查温升增长（基于包含中内温度的完整温度数组）
    final allTemps = await _getAllTemperaturesWithInnerTemps(nodeData, correctedTemps);
    final maxTemp = allTemps.isNotEmpty ? allTemps.reduce((a, b) => a > b ? a : b) : 0.0;
    print('温度报警检查：最高温度=${maxTemp.toStringAsFixed(1)}°C');
    
    // 新增：80-85度范围内温升增长检测
    final double growthBaseline = tempStart; // 节点特定的温度起点
    final double highTempThreshold = tempWarning; // 节点特定的预警阈值
    
    if (maxTemp >= growthBaseline && maxTemp < highTempThreshold) {
      // 在80-85度范围内，检查温升增长
      print('节点${nodeData.nodeId}在80-85度范围内，检查温升增长');
      final growthInfo = _checkTemperatureGrowth(nodeData.nodeId, allTemps);
      if (growthInfo != null) {
        print('节点${nodeData.nodeId}触发温升增长预警：${growthInfo}');
        warnings.add('温度增长预警：${growthInfo}');
      } else {
        print('节点${nodeData.nodeId}温升增长检测未触发预警');
      }
    } else if (maxTemp >= highTempThreshold) {
      // 超过85度，直接预警
      print('节点${nodeData.nodeId}超过85度，直接预警');
      warnings.add('温度预警：温度${maxTemp.toStringAsFixed(1)}°C超过预警阈值${highTempThreshold}°C');
    } else {
      print('节点${nodeData.nodeId}温度${maxTemp.toStringAsFixed(1)}°C不在温升检测范围内');
    }
    
    // 检查局放值高故障：左外或右外温度比中间温度高
    _checkPartialDischargeFaults(correctedTemps, faults);
  }

  // 获取包含中内温度的完整温度数组
  Future<List<double>> _getAllTemperaturesWithInnerTemps(NodeData nodeData, List<double>? correctedTemps) async {
    if (correctedTemps == null || correctedTemps.isEmpty) return [];
    
    final allTemps = <double>[];
    
    // 添加原始PT100温度（9个：左外、中、右外）
    for (int i = 0; i < 9 && i < correctedTemps.length; i++) {
      allTemps.add(correctedTemps[i]);
    }
    
    // 计算并添加中内温度（3个）
    if (correctedTemps.length >= 9) {
      // 计算三相平均值
      final leftAvg = (correctedTemps[0] + correctedTemps[3] + correctedTemps[6]) / 3;   // 左外温度平均值
      final middleAvg = (correctedTemps[1] + correctedTemps[4] + correctedTemps[7]) / 3; // 中外温度平均值  
      final rightAvg = (correctedTemps[2] + correctedTemps[5] + correctedTemps[8]) / 3;  // 右外温度平均值
      
      // 获取环境温度（节点特定）
      final settings = SettingsService();
      final nodeSettings = await settings.getAllSettingsForNode(nodeData.nodeId);
      final upperCorr = nodeSettings['upperTempCorrection'] as double? ?? 0.0;
      final middleCorr = nodeSettings['envTempCorrection'] as double? ?? 0.0;
      final lowerCorr = nodeSettings['lowerTempCorrection'] as double? ?? 0.0;
      
      // 计算环境温度
      double upperTemp = 25.0 + upperCorr;
      double middleTemp = (nodeData.temperature ?? 25.0) + middleCorr;
      double lowerTemp = (nodeData.temperature ?? 25.0) + lowerCorr; // 统一使用温湿度传感器温度
      
      // 如果有PT100数据，使用PT100通道作为上温度：节点1使用通道10，其他节点使用通道9
      if (nodeData.pt100Temperatures != null) {
        if (nodeData.nodeId == 1) {
          // 节点1使用通道10
          final pt10Temp = nodeData.pt100Temperatures![10];
          if (pt10Temp != -999) {
            upperTemp = pt10Temp + upperCorr;
          }
        } else {
          // 其他节点使用通道9
          final pt9Temp = nodeData.pt100Temperatures![9];
          if (pt9Temp != -999) {
            upperTemp = pt9Temp + upperCorr;
          }
        }
      }
      
      // 如果有PT100数据，使用PT100通道11作为中温度
      if (nodeData.pt100Temperatures != null && nodeData.pt100Temperatures!.length >= 12) {
        final pt11Temp = nodeData.pt100Temperatures![11];
        if (pt11Temp != -999) {
          middleTemp = pt11Temp + middleCorr;
        }
      }
      
      // 计算A相中内温度
      final aInner = await _calculateInnerTemp(correctedTemps[1], upperTemp, middleAvg, 'A', nodeData.nodeId);
      allTemps.add(aInner);
      
      // 计算B相中内温度
      final bInner = await _calculateInnerTemp(correctedTemps[4], middleTemp, middleAvg, 'B', nodeData.nodeId);
      allTemps.add(bInner);
      
      // 计算C相中内温度
      final cInner = await _calculateInnerTemp(correctedTemps[7], lowerTemp, middleAvg, 'C', nodeData.nodeId);
      allTemps.add(cInner);
    }
    
    return allTemps;
  }

  // 检查温度增长（80-85度范围内）
  String? _checkTemperatureGrowth(int nodeId, List<double> currentTemps) {
    final currentMax = currentTemps.where((t) => t != -999).reduce((a, b) => a > b ? a : b);
    print('节点${nodeId}温升检测：当前最高温度=${currentMax.toStringAsFixed(1)}°C');
    
    // 检查是否在预警期内（1秒内不重复预警）
    if (_temperatureGrowthAlerts.containsKey(nodeId)) {
      final alertEndTime = _temperatureGrowthAlerts[nodeId]!;
      if (DateTime.now().isBefore(alertEndTime)) {
        print('节点${nodeId}在预警期内，跳过检测');
        // 在预警期内，返回预警信息（不重复设置预警期）
        return '温度增长预警：当前温度${currentMax.toStringAsFixed(1)}°C';
      } else {
        // 预警期已过，清除记录
        _temperatureGrowthAlerts.remove(nodeId);
        print('节点${nodeId}预警期已过，清除记录');
      }
    }
    
    // 检查是否有上一次不同的温度值
    if (!_lastDifferentTemperature.containsKey(nodeId)) {
      // 第一次记录，保存当前温度
      _lastDifferentTemperature[nodeId] = currentMax;
      print('节点${nodeId}首次记录温度：${currentMax.toStringAsFixed(1)}°C');
      return null;
    }
    
    final lastTemp = _lastDifferentTemperature[nodeId]!;
    print('节点${nodeId}温度比较：当前=${currentMax.toStringAsFixed(1)}°C，上次=${lastTemp.toStringAsFixed(1)}°C');
    
    // 如果温度没有变化，不更新记录
    if ((currentMax - lastTemp).abs() < 0.1) {
      print('节点${nodeId}温度变化小于0.1°C，不更新记录');
      return null;
    }
    
    // 温度有变化，检查是否有增长
    final growth = currentMax - lastTemp;
    print('节点${nodeId}温度变化：${growth.toStringAsFixed(1)}°C');
    
    // 更新上一次温度记录
    _lastDifferentTemperature[nodeId] = currentMax;
    
    // 如果有温度增长就触发预警
    if (growth > 0) {
      // 设置1秒预警期
      _temperatureGrowthAlerts[nodeId] = DateTime.now().add(Duration(seconds: 1));
      print('节点${nodeId}触发温升增长预警！');
      return '温度从${lastTemp.toStringAsFixed(1)}°C增长到${currentMax.toStringAsFixed(1)}°C，增长${growth.toStringAsFixed(1)}°C';
    }
    
    print('节点${nodeId}温度下降，不触发预警');
    return null;
  }

  // 检查局放值高故障
  void _checkPartialDischargeFaults(List<double> temps, List<String> faults) {
    if (temps.length < 9) return;
    const double threshold = 0.5; // 0.5℃阈值
    
    // 检查A相：ch1(左外), ch2(中), ch3(右外)
    if (temps[0] != -999 && temps[1] != -999 && (temps[0] - temps[1]) >= threshold) {
      faults.add('A相左外局放值高：${temps[0].toStringAsFixed(1)}°C比中温度${temps[1].toStringAsFixed(1)}°C高${(temps[0] - temps[1]).toStringAsFixed(1)}°C');
    }
    if (temps[2] != -999 && temps[1] != -999 && (temps[2] - temps[1]) >= threshold) {
      faults.add('A相右外局放值高：${temps[2].toStringAsFixed(1)}°C比中温度${temps[1].toStringAsFixed(1)}°C高${(temps[2] - temps[1]).toStringAsFixed(1)}°C');
    }
    
    // 检查B相：ch4(左外), ch5(中), ch6(右外)
    if (temps[3] != -999 && temps[4] != -999 && (temps[3] - temps[4]) >= threshold) {
      faults.add('B相左外局放值高：${temps[3].toStringAsFixed(1)}°C比中温度${temps[4].toStringAsFixed(1)}°C高${(temps[3] - temps[4]).toStringAsFixed(1)}°C');
    }
    if (temps[5] != -999 && temps[4] != -999 && (temps[5] - temps[4]) >= threshold) {
      faults.add('B相右外局放值高：${temps[5].toStringAsFixed(1)}°C比中温度${temps[4].toStringAsFixed(1)}°C高${(temps[5] - temps[4]).toStringAsFixed(1)}°C');
    }
    
    // 检查C相：ch7(左外), ch8(中), ch9(右外)
    if (temps[6] != -999 && temps[7] != -999 && (temps[6] - temps[7]) >= threshold) {
      faults.add('C相左外局放值高：${temps[6].toStringAsFixed(1)}°C比中温度${temps[7].toStringAsFixed(1)}°C高${(temps[6] - temps[7]).toStringAsFixed(1)}°C');
    }
    if (temps[8] != -999 && temps[7] != -999 && (temps[8] - temps[7]) >= threshold) {
      faults.add('C相右外局放值高：${temps[8].toStringAsFixed(1)}°C比中温度${temps[7].toStringAsFixed(1)}°C高${(temps[8] - temps[7]).toStringAsFixed(1)}°C');
    }
  }

  // 检查所有温度点的阈值（包括计算后的中内温度）
  Future<void> _checkAllTemperatureThresholdsWithInnerTemps(NodeData nodeData, List<double> temps, List<String> warnings, List<String> faults, Map<String, dynamic> nodeSettings) async {
    if (temps.isEmpty) return;
    
    // 构建包含中内温度的完整温度数组
    final allTemps = <double>[];
    final tempNames = <String>[];
    
    // 添加原始PT100温度（9个：左外、中、右外）
    for (int i = 0; i < 9; i++) {
      if (i < temps.length) {
        allTemps.add(temps[i]);
        final phase = i < 3 ? 'A' : (i < 6 ? 'B' : 'C');
        final pos = i % 3;
        final posName = pos == 0 ? '左外' : (pos == 1 ? '中' : '右外');
        tempNames.add('${phase}相$posName');
      }
    }
    
    // 计算并添加中内温度（3个）
    if (temps.length >= 9) {
      // 计算三相平均值
      final leftAvg = (temps[0] + temps[3] + temps[6]) / 3;   // 左外温度平均值
      final middleAvg = (temps[1] + temps[4] + temps[7]) / 3; // 中外温度平均值  
      final rightAvg = (temps[2] + temps[5] + temps[8]) / 3;  // 右外温度平均值
      
      // 获取环境温度（节点特定）
      final settings = SettingsService();
      final nodeSettings = await settings.getAllSettingsForNode(nodeData.nodeId);
      final upperCorr = nodeSettings['upperTempCorrection'] as double? ?? 0.0;
      final middleCorr = nodeSettings['envTempCorrection'] as double? ?? 0.0;
      final lowerCorr = nodeSettings['lowerTempCorrection'] as double? ?? 0.0;
      
      // 计算环境温度
      double upperTemp = 25.0 + upperCorr;
      double middleTemp = (nodeData.temperature ?? 25.0) + middleCorr;
      double lowerTemp = (nodeData.temperature ?? 25.0) + lowerCorr; // 统一使用温湿度传感器温度
      
      // 如果有PT100数据，使用PT100通道作为上温度：节点1使用通道10，其他节点使用通道9
      if (nodeData.pt100Temperatures != null) {
        if (nodeData.nodeId == 1) {
          // 节点1使用通道10
          final pt10Temp = nodeData.pt100Temperatures![10];
          if (pt10Temp != -999) {
            upperTemp = pt10Temp + upperCorr;
          }
        } else {
          // 其他节点使用通道9
          final pt9Temp = nodeData.pt100Temperatures![9];
          if (pt9Temp != -999) {
            upperTemp = pt9Temp + upperCorr;
          }
        }
      }
      
      // 如果有PT100数据，使用PT100通道11作为中温度
      if (nodeData.pt100Temperatures != null && nodeData.pt100Temperatures!.length >= 12) {
        final pt11Temp = nodeData.pt100Temperatures![11];
        if (pt11Temp != -999) {
          middleTemp = pt11Temp + middleCorr;
        }
      }
      
      // 计算A相中内温度
      final aInner = await _calculateInnerTemp(temps[1], upperTemp, middleAvg, 'A', nodeData.nodeId);
      allTemps.add(aInner);
      tempNames.add('A相中内');
      
      // 计算B相中内温度
      final bInner = await _calculateInnerTemp(temps[4], middleTemp, middleAvg, 'B', nodeData.nodeId);
      allTemps.add(bInner);
      tempNames.add('B相中内');
      
      // 计算C相中内温度
      final cInner = await _calculateInnerTemp(temps[7], lowerTemp, middleAvg, 'C', nodeData.nodeId);
      allTemps.add(cInner);
      tempNames.add('C相中内');
    }
    
    print('温度判断数组：$allTemps');
    print('温度名称数组：$tempNames');
    
    // 获取节点特定的温度阈值
    final tempWarning = nodeSettings['tempWarning'] as double? ?? _settingsService.tempWarning;
    final tempFault = nodeSettings['tempFault'] as double? ?? _settingsService.tempFault;
    
    // 检查每个温度点
    for (int i = 0; i < allTemps.length && i < tempNames.length; i++) {
      final temp = allTemps[i];
      if (temp == -999) continue; // 跳过开路温度
      
      final tempName = tempNames[i];
      
      if (temp >= tempFault) {
        faults.add('${tempName}温度故障：${temp.toStringAsFixed(1)}°C超过故障阈值${tempFault}°C');
      } else if (temp >= tempWarning) {
        warnings.add('${tempName}温度预警：${temp.toStringAsFixed(1)}°C超过预警阈值${tempWarning}°C');
      }
    }
  }
  
  // 计算内温度：Y = xi + k1·max(0, xi – x0i) + k2·max(0, xi – xia)
  // xi: 外测点温度, x0i: 环境温度, xia: 三相平均值
  // phase: 相别 ('A', 'B', 'C')
  Future<double> _calculateInnerTemp(double xi, double x0i, double xia, String phase, int nodeId) async {
    // 如果外测点温度为开路，内温度也为开路
    if (xi == -999) return -999;
    
    // 当外温度小于环境温度时，中内温度等于中外温度
    if (xi < x0i) {
      return xi;
    }
    
    // 获取对应相的k1、k2参数（节点特定）
    final nodeSettings = await _settingsService.getAllSettingsForNode(nodeId);
    double k1, k2;
    switch (phase) {
      case 'A':
        k1 = nodeSettings['aK1'] as double? ?? 6.42;
        k2 = nodeSettings['aK2'] as double? ?? 2.5;
        break;
      case 'B':
        k1 = nodeSettings['bK1'] as double? ?? 6.42;
        k2 = nodeSettings['bK2'] as double? ?? 2.5;
        break;
      case 'C':
        k1 = nodeSettings['cK1'] as double? ?? 6.42;
        k2 = nodeSettings['cK2'] as double? ?? 2.5;
        break;
      default:
        k1 = 6.42; // 默认值
        k2 = 2.5;  // 默认值
    }
    
    // 输入参数验证（仅记录，不限制）
    if (xi < -50 || xi > 200 || x0i < -50 || x0i > 200 || xia < -50 || xia > 200) {
      print('⚠️ 中内温度计算输入参数异常: xi=$xi, x0i=$x0i, xia=$xia, 相别=$phase, 节点=$nodeId');
    }
    
    // 对差值进行下限截断：若为负则按0计算
    final deltaEnv = xi - x0i;
    final deltaPhaseAvg = xi - xia;
    final nonNegativeEnv = deltaEnv < 0 ? 0 : deltaEnv;
    final nonNegativePhaseAvg = deltaPhaseAvg < 0 ? 0 : deltaPhaseAvg;
    
    // 应用公式：Y = xi + k1·max(0, xi – x0i) + k2·max(0, xi – xia)
    final y = xi + k1 * nonNegativeEnv + k2 * nonNegativePhaseAvg;
    
    // 异常高温检测和调试输出
    if (y > 200 || y < -50) {
      print('🚨 中内温度计算结果异常: $y°C');
      print('   计算公式: Y = xi + k1·max(0, xi – x0i) + k2·max(0, xi – xia)');
      print('   输入参数: xi=$xi, x0i=$x0i, xia=$xia, 相别=$phase, 节点=$nodeId');
      print('   计算参数: k1=$k1, k2=$k2');
      print('   差值计算: deltaEnv=${deltaEnv.toStringAsFixed(6)}, deltaPhaseAvg=${deltaPhaseAvg.toStringAsFixed(6)}');
      print('   非负值: nonNegativeEnv=${nonNegativeEnv.toStringAsFixed(6)}, nonNegativePhaseAvg=${nonNegativePhaseAvg.toStringAsFixed(6)}');
      print('   分步计算: xi=$xi + k1×${nonNegativeEnv.toStringAsFixed(6)} + k2×${nonNegativePhaseAvg.toStringAsFixed(6)}');
      print('   分步结果: $xi + ${(k1 * nonNegativeEnv).toStringAsFixed(6)} + ${(k2 * nonNegativePhaseAvg).toStringAsFixed(6)} = $y');
    }
    
    return y;
  }

  // 检查所有温度点的阈值（保留原方法以防需要）
  // 注意：此方法已不再使用，被_checkAllTemperatureThresholdsWithInnerTemps替代
  // 保留此方法以防需要特殊处理，但建议使用带节点特定阈值的新方法
  void _checkAllTemperatureThresholds(List<double> temps, List<String> warnings, List<String> faults) {
    if (temps.isEmpty) return;
    
    // 温度点名称映射
    final List<String> tempNames = [
      'A相左外', 'A相中', 'A相右外', 'A相中内',
      'B相左外', 'B相中', 'B相右外', 'B相中内',
      'C相左外', 'C相中', 'C相右外', 'C相中内'
    ];
    
    // 检查每个温度点（使用全局阈值，不推荐）
    for (int i = 0; i < temps.length && i < tempNames.length; i++) {
      final temp = temps[i];
      if (temp == -999) continue; // 跳过开路温度
      
      final tempName = tempNames[i];
      
      if (temp >= _settingsService.tempFault) {
        faults.add('${tempName}温度故障：${temp.toStringAsFixed(1)}°C超过故障阈值${_settingsService.tempFault}°C');
      } else if (temp >= _settingsService.tempWarning) {
        warnings.add('${tempName}温度预警：${temp.toStringAsFixed(1)}°C超过预警阈值${_settingsService.tempWarning}°C');
      }
    }
  }

  // 检查中内温度阈值（保留原有逻辑，但现在被_allTemperatureThresholds替代）
  void _checkInnerTemperatureAlerts(List<double> temps, List<String> warnings, List<String> faults) {
    // 这个函数现在被_checkAllTemperatureThresholds替代，保留以防需要特殊处理
    // 中内温度现在已经在_checkAllTemperatureThresholds中统一处理
  }

  // 生成修正后的PT100温度数组（叠加每路修正值；-999保持不变）
  Future<List<double>?> _getCorrectedPt100Temps(NodeData nodeData) async {
    if (nodeData.pt100Temperatures == null) return null;
    final raw = nodeData.pt100Temperatures!;
    
    // 获取节点特定的PT100修正值
    final nodeSettings = await _settingsService.getAllSettingsForNode(nodeData.nodeId);
    final corrections = nodeSettings['pt100Corrections'] as List<dynamic>? ?? List.filled(10, 0.0);
    
    final int n = raw.length;
    final out = <double>[];
    for (int i = 0; i < n; i++) {
      final v = raw[i];
      if (v == -999) {
        out.add(-999);
      } else {
        final c = i < corrections.length ? (corrections[i] as double? ?? 0.0) : 0.0;
        out.add(v + c);
      }
    }
    return out;
  }

  // 气体浓度和烟雾故障判断
  void _checkGasAndSmokeAlerts(NodeData nodeData, List<String> warnings, List<String> faults, Map<String, dynamic> nodeSettings) {
    // 获取节点特定的气体阈值
    final h2Fault = nodeSettings['h2Fault'] as double? ?? _settingsService.h2Fault;
    final coFault = nodeSettings['coFault'] as double? ?? _settingsService.coFault;
    final smokeFault = nodeSettings['smokeFault'] as double? ?? _settingsService.smokeFault;
    
    // 氢气：≥故障阈值 -> 故障；≥预警阈值 -> 预警
    final h2Warning = nodeSettings['h2Warning'] as double? ?? _settingsService.h2Warning;
    if (nodeData.h2Percentage != null) {
      final v = nodeData.h2Percentage!;
      if (v >= h2Fault) {
        faults.add('氢气故障：浓度${v.toStringAsFixed(1)}%LEL超过故障阈值${h2Fault}%LEL');
      } else if (v > 0 && v >= h2Warning) {
        warnings.add('氢气预警：浓度${v.toStringAsFixed(1)}%LEL超过预警阈值${h2Warning}%LEL');
      }
    }
    
    // 一氧化碳：≥故障阈值 -> 故障；≥预警阈值 -> 预警（异常值忽略）
    if (nodeData.coPpm != null) {
      final coValue = nodeData.coPpm!;
      // 检测异常值：负数或超过10000ppm的异常大值
      if (coValue < 0 || coValue > 10000) {
        print('CO异常值检测: 原始值=$coValue, 在预警判断中忽略');
        // 异常值不进行预警和故障判断
      } else {
        final coWarning = nodeSettings['coWarning'] as double? ?? _settingsService.coWarning;
        if (coValue >= coFault) {
          faults.add('一氧化碳故障：浓度${coValue}ppm超过故障阈值${coFault}ppm');
        } else if (coValue > 0 && coValue >= coWarning) {
          warnings.add('一氧化碳预警：浓度${coValue}ppm超过预警阈值${coWarning}ppm');
        }
      }
    }
    
    // 烟雾预警和故障判断（基于增加量）
    _checkSmokeAlerts(nodeData, warnings, faults);
  }

  // 烟雾预警和故障判断（基于通道状态，不再使用阈值判断）
  void _checkSmokeAlerts(NodeData nodeData, List<String> warnings, List<String> faults) {
    final smokeStatus = nodeData.smokeStatus;
    
    if (smokeStatus == null) return;
    
    // 根据烟雾状态判断预警和故障
    // 0x04 = 故障状态, 0x02 = 预警状态, 0x01 = 正常状态
    if (smokeStatus == 0x04) {
      // 故障状态：有故障显示故障
      faults.add('烟雾故障：传感器检测到烟雾故障状态');
    } else if (smokeStatus == 0x02) {
      // 预警状态：有预警显示预警
      warnings.add('烟雾预警：传感器检测到烟雾预警状态');
    }
    // 正常状态 (0x01) 不添加任何预警或故障信息
  }


  // 湿度预警和故障判断
  void _checkHumidityAlerts(NodeData nodeData, List<String> warnings, List<String> faults, Map<String, dynamic> nodeSettings) {
    if (nodeData.humidity == null) return;
    
    // 获取节点特定的湿度阈值
    final humidityWarning = nodeSettings['humidityWarning'] as double? ?? _settingsService.humidityWarning;
    final humidityFault = nodeSettings['humidityFault'] as double? ?? _settingsService.humidityFault;
    final humidityFaultHours = nodeSettings['humidityFaultHours'] as int? ?? _settingsService.humidityFaultHours;
    
    final corr = nodeSettings['humidityCorrection'] as double? ?? _settingsService.humidityCorrection;
    final humidity = ((nodeData.humidity! + corr)).clamp(0, 100).toDouble();
    final nodeId = nodeData.nodeId;
    final now = DateTime.now();
    
    if (humidity >= humidityFault) {
      // 超过故障阈值直接故障
      faults.add('湿度故障：湿度${humidity.toStringAsFixed(1)}%RH超过故障阈值${humidityFault}%RH');
      _humidityWarningStartTime[nodeId] = null; // 清除预警时间记录
    } else if (humidity >= humidityWarning) {
      // 预警阈值和故障阈值之间，检查持续时间
      if (_humidityWarningStartTime[nodeId] == null) {
        _humidityWarningStartTime[nodeId] = now;
        warnings.add('湿度预警：湿度${humidity.toStringAsFixed(1)}%RH超过预警阈值${humidityWarning}%RH');
      } else {
        final duration = now.difference(_humidityWarningStartTime[nodeId]!);
        if (duration.inHours >= humidityFaultHours) {
          faults.add('湿度故障：湿度${humidity.toStringAsFixed(1)}%RH超过预警阈值${humidityWarning}%RH已持续${duration.inHours}小时');
          _humidityWarningStartTime[nodeId] = null;
        } else {
          warnings.add('湿度预警：湿度${humidity.toStringAsFixed(1)}%RH超过预警阈值${humidityWarning}%RH已持续${duration.inHours}小时');
        }
      }
    } else {
      // 低于预警阈值，清除预警时间记录
      _humidityWarningStartTime[nodeId] = null;
    }
  }

  // 压力预警和故障判断
  void _checkPressureAlerts(NodeData nodeData, List<String> warnings, List<String> faults, Map<String, dynamic> nodeSettings) {
    if (nodeData.pressureKpa == null) return;
    
    // 获取节点特定的压力阈值
    final pressureWarning = nodeSettings['pressureWarning'] as double? ?? _settingsService.pressureWarning;
    final pressureFault = nodeSettings['pressureFault'] as double? ?? _settingsService.pressureFault;
    
    final pressure = nodeData.pressureKpa!;
    if (pressure >= pressureFault) {
      faults.add('压力故障：压力${pressure.toStringAsFixed(1)}kPa超过故障阈值${pressureFault}kPa');
    } else if (pressure > pressureWarning) {
      warnings.add('压力预警：压力${pressure.toStringAsFixed(1)}kPa在${pressureWarning}-${pressureFault}kPa预警范围内');
    }
  }

  // 连接状态判断（基于查询判断逻辑）
  void _checkConnectionStatus(NodeData nodeData, List<String> warnings, List<String> faults) {
    // 如果 SensorDataService 可用，使用基于查询判断的连接状态
    if (_sensorDataService != null) {
      final isConnected = _sensorDataService!.isNodeConnected(nodeData.nodeId);
      if (!isConnected) {
        // 从设置获取超时时间用于显示
        final disconnectTimeoutMs = _settingsService.nodeDisconnectTimeoutMs;
        final disconnectTimeoutSec = (disconnectTimeoutMs / 1000).toStringAsFixed(1);
        faults.add('设备未连接：连续查询无响应且超过${disconnectTimeoutSec}秒未收到数据');
      }
      return;
    }
    
    // 备用判断（如果 SensorDataService 不可用）
    final now = DateTime.now().millisecondsSinceEpoch;
    final isStale = (nodeData.lastUpdateTimestamp == null) || 
                   (now - nodeData.lastUpdateTimestamp! > 40000);
    
    if (isStale) {
      faults.add('设备未连接：超过40秒未收到数据更新');
      return;
    }
    
    // 基于实际传感器数据判断连接状态
    final hasData = nodeData.temperature != null || nodeData.humidity != null || nodeData.coPpm != null || 
        nodeData.h2Percentage != null || nodeData.pressureKpa != null || nodeData.smokeChannelA != null || 
        nodeData.smokeChannelB != null || (nodeData.pt100Temperatures != null && nodeData.pt100Temperatures!.isNotEmpty);
    
    if (!hasData) {
      faults.add('设备未连接：无传感器数据');
    }
  }

  // 应用忽略规则过滤预警/故障信息
  List<String> _applyIgnoreRules(String nodeId, List<String> alerts, String alertLevel) {
    final filteredAlerts = <String>[];
    
    for (final alert in alerts) {
      // 解析预警/故障类型
      final alertType = _parseAlertType(alert);
      
      // 检查是否应该忽略
      if (!_ignoreService.shouldIgnoreAlert(
        nodeId: nodeId,
        alertType: alertType,
        alertLevel: alertLevel,
      )) {
        filteredAlerts.add(alert);
      }
    }
    
    return filteredAlerts;
  }

  // 解析预警/故障类型
  String _parseAlertType(String alert) {
    if (alert.contains('温度')) {
      if (alert.contains('故障')) return 'temperature_fault';
      if (alert.contains('预警')) return 'temperature_warning';
      if (alert.contains('局放值高')) return 'partial_discharge';
    }
    if (alert.contains('氢气')) {
      if (alert.contains('故障')) return 'h2_fault';
      if (alert.contains('预警')) return 'h2_warning';
    }
    if (alert.contains('一氧化碳')) {
      if (alert.contains('故障')) return 'co_fault';
      if (alert.contains('预警')) return 'co_warning';
    }
    if (alert.contains('白烟')) {
      if (alert.contains('故障')) return 'white_smoke_fault';
      if (alert.contains('预警')) return 'white_smoke_warning';
    }
    if (alert.contains('黑烟')) {
      if (alert.contains('故障')) return 'black_smoke_fault';
      if (alert.contains('预警')) return 'black_smoke_warning';
    }
    if (alert.contains('湿度')) {
      if (alert.contains('故障')) return 'humidity_fault';
      if (alert.contains('预警')) return 'humidity_warning';
    }
    if (alert.contains('压力')) {
      if (alert.contains('故障')) return 'pressure_fault';
      if (alert.contains('预警')) return 'pressure_warning';
    }
    if (alert.contains('设备未连接')) {
      return 'connection_fault';
    }
    
    return 'unknown';
  }

  // 新变量修正 + 拟合公式（按需求替换原逻辑）
  // 变量修正：x0 = 568 * (xStar - a) / T
  // 浓度拟合：x0 < 568 => m = -1.5e-7 * x0^2 + 0.0007 * x0
  //          x0 >= 568 => m = 0.2772 * ln(x0) - 1.408
  double _calculateSmokeConcentrationFromRaw(double xStar, double a, double T) {
    print('报警服务烟雾计算开始: xStar=$xStar, a=$a, T=$T');
    // 变量修正
    final double tSafe = (T == 0) ? 568.0 : T;
    final double delta = xStar - a;
    print('报警服务烟雾计算: delta=$delta');
    if (delta <= 0) {
      print('报警服务烟雾计算: delta <= 0, 返回0');
      return 0.0;
    }
    final double x0 = 568.0 * (delta / tSafe);
    print('报警服务烟雾计算: x0=$x0');
    double m;
    if (x0 < 568.0) {
      m = -0.00000015 * x0 * x0 + 0.0007 * x0;
      print('报警服务烟雾计算: x0 < 568, 使用二次公式, m=$m');
    } else {
      // x0 >= 568 走对数拟合；对极端值同样处理（与需求一致）
      final double lnX0 = _naturalLog(x0);
      m = 0.2772 * lnX0 - 1.408;
      print('报警服务烟雾计算: x0 >= 568, 使用对数公式, ln(x0)=$lnX0, m=$m');
    }
    if (m < 0) m = 0;
    print('报警服务烟雾计算最终结果: $m');
    return m;
  }

  // 手动实现自然对数
  double _naturalLog(double x) {
    if (x <= 0) return 0;
    if (x == 1) return 0;
    
    if (x > 2) {
      return 0.693147 + _naturalLog(x / 2);
    }
    
    // 使用泰勒级数近似：ln(1+x) = x - x²/2 + x³/3 - x⁴/4 + ...
    double result = 0;
    double term = x - 1;
    double power = term;
    
    for (int i = 1; i <= 20; i++) {
      result += power / i;
      power *= -term;
    }
    
    return result;
  }
  
  /// 发送预警/故障485格式报文
  void _sendAlertRS485(NodeData nodeData, String alertDescription, bool isWarning) {
    try {
      final faultCode = RS485Protocol.getFaultCode(alertDescription);
      if (faultCode == null) {
        print('⚠️ 无法识别故障码: $alertDescription');
        return;
      }
      
      // 防重复发送
      final alertKey = '${isWarning ? 'warning' : 'fault'}_${nodeData.nodeId}_${alertDescription.hashCode}';
      if (!_shouldSendAlert(alertKey)) {
        return;
      }
      _lastSentAlerts[alertKey] = DateTime.now();
      
      // 从描述中提取数值
      double? value;
      if (alertDescription.contains('温度')) {
        // 提取温度值
        final match = RegExp(r'(\d+\.?\d*)°C').firstMatch(alertDescription);
        if (match != null) {
          value = double.tryParse(match.group(1) ?? '');
        } else if (nodeData.temperature != null) {
          value = nodeData.temperature;
        }
      } else if (alertDescription.contains('压力')) {
        final match = RegExp(r'(\d+\.?\d*)kPa').firstMatch(alertDescription);
        if (match != null) {
          value = double.tryParse(match.group(1) ?? '');
        } else if (nodeData.pressureKpa != null) {
          value = nodeData.pressureKpa;
        }
      } else if (alertDescription.contains('CO') || alertDescription.contains('一氧化碳')) {
        final match = RegExp(r'(\d+)ppm').firstMatch(alertDescription);
        if (match != null) {
          value = double.tryParse(match.group(1) ?? '');
        } else if (nodeData.coPpm != null) {
          value = nodeData.coPpm!.toDouble();
        }
      } else if (alertDescription.contains('H2') || alertDescription.contains('氢气')) {
        final match = RegExp(r'(\d+\.?\d*)%').firstMatch(alertDescription);
        if (match != null) {
          value = double.tryParse(match.group(1) ?? '');
        } else if (nodeData.h2Percentage != null) {
          value = nodeData.h2Percentage;
        }
      } else if (alertDescription.contains('湿度')) {
        final match = RegExp(r'(\d+\.?\d*)%RH').firstMatch(alertDescription);
        if (match != null) {
          value = double.tryParse(match.group(1) ?? '');
        } else if (nodeData.humidity != null) {
          value = nodeData.humidity;
        }
      }
      
      // 构建485格式数据：故障码(1) + 数值(2字节，高字节在前，乘以100)
      final data = <int>[];
      data.add(faultCode); // 故障码
      if (value != null) {
        final intValue = (value * 100).round();
        data.add((intValue >> 8) & 0xFF); // 高字节
        data.add(intValue & 0xFF);        // 低字节
      } else {
        data.add(0x00); // 无数值时填充0
        data.add(0x00);
      }
      
      // 使用故障码作为传感器编号发送
      _modbusClient.sendRS485Frame(
        nodeId: nodeData.nodeId,
        sensorId: faultCode, // 使用故障码作为传感器编号
        data: data,
      );
      
      print('📤 发送${isWarning ? '预警' : '故障'}485报文: 节点=${nodeData.nodeId}, 故障码=0x${faultCode.toRadixString(16)}, 描述=$alertDescription');
    } catch (e) {
      print('❌ 发送预警/故障485报文失败: $e');
    }
  }
}
