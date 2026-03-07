import 'dart:convert';
import '../services/sensor_data_service.dart';
import '../services/alert_service.dart';

class NodeData {
  final int nodeId;
  final double? temperature;
  final double? humidity;
  final int? coPpm;
  final double? h2Percentage;
  final double? pressureKpa;
  final double? pressureTempC;
  final bool? smokeAlarm;
  final int? smokeStatus; // 烟雾状态
  final double? smokeRatio;
  final int? smokeAlarmCount;
  final double? smokeExternalTempC;
  final int? smokeChannelA;
  final int? smokeChannelB;
  final int? smokeCalibA; // 标定零点A
  final int? smokeCalibB; // 标定零点B
  final int? smokeThreshA; // 报警阈值A
  final int? smokeThreshB; // 报警阈值B
  final List<double>? pt100Temperatures;
  final String? lastUpdate;
  final int? lastUpdateTimestamp;
  
  // 状态帧字段
  final int? stCoLen;
  final int? stSmokeLen;
  final int? stH2Len;
  final int? stPt100Len;
  final int? stThLen;
  final int? stPressureLen;

  NodeData({
    required this.nodeId,
    this.temperature,
    this.humidity,
    this.coPpm,
    this.h2Percentage,
    this.pressureKpa,
    this.pressureTempC,
    this.smokeAlarm,
    this.smokeStatus,
    this.smokeRatio,
    this.smokeAlarmCount,
    this.smokeExternalTempC,
    this.smokeChannelA,
    this.smokeChannelB,
    this.smokeCalibA,
    this.smokeCalibB,
    this.smokeThreshA,
    this.smokeThreshB,
    this.pt100Temperatures,
    this.lastUpdate,
    this.lastUpdateTimestamp,
    this.stCoLen,
    this.stSmokeLen,
    this.stH2Len,
    this.stPt100Len,
    this.stThLen,
    this.stPressureLen,
  });

  // 从传感器数据创建节点数据
  factory NodeData.fromSensorData(SensorData sensorData) {
    return NodeData(
      nodeId: sensorData.nodeId,
      temperature: sensorData.temperature,
      humidity: sensorData.humidity,
      coPpm: sensorData.coPpm,
      h2Percentage: sensorData.h2Percentage,
      pressureKpa: sensorData.pressureKpa,
      pressureTempC: sensorData.pressureTempC,
      smokeAlarm: sensorData.smokeStatus != null ? (sensorData.smokeStatus! & 0x04) != 0 : null,
      smokeStatus: sensorData.smokeStatus,
      smokeExternalTempC: sensorData.smokeExternalTempC,
      smokeChannelA: sensorData.smokeChannelA,
      smokeChannelB: sensorData.smokeChannelB,
      smokeCalibA: sensorData.smokeCalibA,
      smokeCalibB: sensorData.smokeCalibB,
      smokeThreshA: sensorData.smokeThreshA,
      smokeThreshB: sensorData.smokeThreshB,
      pt100Temperatures: sensorData.pt100Temperatures != null 
          ? _parsePt100Temperatures(sensorData.pt100Temperatures!)
          : null,
      lastUpdate: _formatTimestamp(sensorData.timestamp),
      lastUpdateTimestamp: sensorData.timestamp,
      stCoLen: sensorData.stCoLen,
      stSmokeLen: sensorData.stSmokeLen,
      stH2Len: sensorData.stH2Len,
      stPt100Len: sensorData.stPt100Len,
      stThLen: sensorData.stThLen,
      stPressureLen: sensorData.stPressureLen,
    );
  }

  // 解析PT100温度数据
  static List<double>? _parsePt100Temperatures(dynamic data) {
    try {
      if (data is String) {
        final List<dynamic> temps = jsonDecode(data);
        return temps.cast<double>();
      } else if (data is List) {
        return data.cast<double>();
      }
      return null;
    } catch (e) {
      print('Error parsing PT100 temperatures: $e');
      return null;
    }
  }

  // 格式化时间戳
  static String _formatTimestamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    final second = date.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  // 获取连接状态颜色（基于查询判断逻辑，需要传入连接状态）
  String getConnectionStatusColor({bool? isConnectedFromQuery}) {
    // 如果传入了基于查询判断的连接状态，优先使用
    if (isConnectedFromQuery != null) {
      return isConnectedFromQuery ? '#00C853' : '#D50000';
    }
    
    // 否则使用备用判断（基于时间戳和数据）
    final now = DateTime.now().millisecondsSinceEpoch;
    final isStale = lastUpdateTimestamp == null || (now - lastUpdateTimestamp!) > 10000;
    if (isStale) return '#D50000';
    // 有实际传感器数据则绿灯，否则灰灯
    final hasData = temperature != null || humidity != null || coPpm != null || 
        h2Percentage != null || pressureKpa != null || smokeChannelA != null || 
        smokeChannelB != null || (pt100Temperatures != null && pt100Temperatures!.isNotEmpty);
    return hasData ? '#00C853' : '#BDBDBD';
  }

  // 获取连接状态文本（基于查询判断逻辑，需要传入连接状态）
  String getConnectionStatusText({bool? isConnectedFromQuery}) {
    // 如果传入了基于查询判断的连接状态，优先使用
    if (isConnectedFromQuery != null) {
      return isConnectedFromQuery ? '已连接' : '未连接';
    }
    
    // 否则使用备用判断（基于时间戳和数据）
    final now = DateTime.now().millisecondsSinceEpoch;
    final isStale = lastUpdateTimestamp == null || (now - lastUpdateTimestamp!) > 10000;
    if (isStale) return '未连接';
    // 有实际传感器数据则已连接，否则未连接
    final hasData = temperature != null || humidity != null || coPpm != null || 
        h2Percentage != null || pressureKpa != null || smokeChannelA != null || 
        smokeChannelB != null || (pt100Temperatures != null && pt100Temperatures!.isNotEmpty);
    return hasData ? '已连接' : '未连接';
  }

  // 获取系统状态颜色
  Future<String> getSystemStatusColor() async {
    final alertInfo = await AlertService().analyzeNodeData(this);
    switch (alertInfo.level) {
      case AlertLevel.fault:
        return '#D50000'; // 红色
      case AlertLevel.warning:
        return '#FF9800'; // 橙色
      case AlertLevel.normal:
        return '#00C853'; // 绿色
    }
  }

  // 获取系统状态文本
  Future<String> getSystemStatusText() async {
    final alertInfo = await AlertService().analyzeNodeData(this);
    switch (alertInfo.level) {
      case AlertLevel.fault:
        return '⚠️ 故障';
      case AlertLevel.warning:
        return '⚠️ 预警';
      case AlertLevel.normal:
        return '✅ 正常';
    }
  }

  // 获取故障信息
  Future<String> getFaultInfo() async {
    final alertInfo = await AlertService().analyzeNodeData(this);
    return alertInfo.description;
  }

  // 获取PT100摘要
  String getPt100Summary() {
    if (pt100Temperatures == null || pt100Temperatures!.isEmpty) {
      return '—';
    }
    
    final valid = pt100Temperatures!.where((t) => t != -999).toList();
    if (valid.isEmpty) {
      return '全部开路';
    }
    
    final min = valid.reduce((a, b) => a < b ? a : b);
    final max = valid.reduce((a, b) => a > b ? a : b);
    return '${min.toStringAsFixed(1)}~${max.toStringAsFixed(1)}°C (${valid.length})';
  }

  // 复制并更新数据
  NodeData copyWith({
    int? nodeId,
    double? temperature,
    double? humidity,
    int? coPpm,
    double? h2Percentage,
    double? pressureKpa,
    double? pressureTempC,
    bool? smokeAlarm,
    int? smokeStatus,
    double? smokeRatio,
    int? smokeAlarmCount,
    double? smokeExternalTempC,
    int? smokeChannelA,
    int? smokeChannelB,
    int? smokeCalibA,
    int? smokeCalibB,
    int? smokeThreshA,
    int? smokeThreshB,
    List<double>? pt100Temperatures,
    String? lastUpdate,
    int? lastUpdateTimestamp,
    int? stCoLen,
    int? stSmokeLen,
    int? stH2Len,
    int? stPt100Len,
    int? stThLen,
    int? stPressureLen,
  }) {
    return NodeData(
      nodeId: nodeId ?? this.nodeId,
      temperature: temperature ?? this.temperature,
      humidity: humidity ?? this.humidity,
      coPpm: coPpm ?? this.coPpm,
      h2Percentage: h2Percentage ?? this.h2Percentage,
      pressureKpa: pressureKpa ?? this.pressureKpa,
      pressureTempC: pressureTempC ?? this.pressureTempC,
      smokeAlarm: smokeAlarm ?? this.smokeAlarm,
      smokeStatus: smokeStatus ?? this.smokeStatus,
      smokeRatio: smokeRatio ?? this.smokeRatio,
      smokeAlarmCount: smokeAlarmCount ?? this.smokeAlarmCount,
      smokeExternalTempC: smokeExternalTempC ?? this.smokeExternalTempC,
      smokeChannelA: smokeChannelA ?? this.smokeChannelA,
      smokeChannelB: smokeChannelB ?? this.smokeChannelB,
      smokeCalibA: smokeCalibA ?? this.smokeCalibA,
      smokeCalibB: smokeCalibB ?? this.smokeCalibB,
      smokeThreshA: smokeThreshA ?? this.smokeThreshA,
      smokeThreshB: smokeThreshB ?? this.smokeThreshB,
      pt100Temperatures: pt100Temperatures ?? this.pt100Temperatures,
      lastUpdate: lastUpdate ?? this.lastUpdate,
      lastUpdateTimestamp: lastUpdateTimestamp ?? this.lastUpdateTimestamp,
      stCoLen: stCoLen ?? this.stCoLen,
      stSmokeLen: stSmokeLen ?? this.stSmokeLen,
      stH2Len: stH2Len ?? this.stH2Len,
      stPt100Len: stPt100Len ?? this.stPt100Len,
      stThLen: stThLen ?? this.stThLen,
      stPressureLen: stPressureLen ?? this.stPressureLen,
    );
  }
}
