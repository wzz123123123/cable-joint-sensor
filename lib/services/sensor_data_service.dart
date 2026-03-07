import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'csv_logger_service.dart';
import 'modbus_tcp_server.dart';
import 'alert_service.dart';
import 'settings_service.dart';
import 'rs485_protocol.dart';

class SensorData {
  final int nodeId;
  final int sensorType;
  final int timestamp;
  final double? temperature;
  final double? humidity;
  final int? coPpm;
  final double? h2Percentage;
  final double? pressureKpa;
  final double? pressureTempC;
  final int? smokeStatus;
  final double? smokeExternalTempC;
  final int? smokeChannelA;
  final int? smokeChannelB;
  final int? smokeCalibA; // 标定零点A
  final int? smokeCalibB; // 标定零点B
  final int? smokeThreshA; // 报警阈值A
  final int? smokeThreshB; // 报警阈值B
  final String? pt100Temperatures;
  final int? fanStatus;
  final int? fanTimer;
  final int? stCoLen;
  final int? stSmokeLen;
  final int? stH2Len;
  final int? stPt100Len;
  final int? stThLen;
  final int? stPressureLen;

  SensorData({
    required this.nodeId,
    required this.sensorType,
    required this.timestamp,
    this.temperature,
    this.humidity,
    this.coPpm,
    this.h2Percentage,
    this.pressureKpa,
    this.pressureTempC,
    this.smokeStatus,
    this.smokeExternalTempC,
    this.smokeChannelA,
    this.smokeChannelB,
    this.smokeCalibA,
    this.smokeCalibB,
    this.smokeThreshA,
    this.smokeThreshB,
    this.pt100Temperatures,
    this.fanStatus,
    this.fanTimer,
    this.stCoLen,
    this.stSmokeLen,
    this.stH2Len,
    this.stPt100Len,
    this.stThLen,
    this.stPressureLen,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'node_id': nodeId,
      'sensor_type': sensorType,
      'timestamp': timestamp,
    };
    
    // 只添加非null的字段
    if (temperature != null) map['temperature'] = temperature;
    if (humidity != null) map['humidity'] = humidity;
    if (coPpm != null) map['co_ppm'] = coPpm;
    if (h2Percentage != null) map['h2_percentage'] = h2Percentage;
    if (pressureKpa != null) map['pressure_kpa'] = pressureKpa;
    if (pressureTempC != null) map['pressure_temp_c'] = pressureTempC;
    if (smokeStatus != null) map['smoke_status'] = smokeStatus;
    if (smokeExternalTempC != null) map['smoke_external_temp_c'] = smokeExternalTempC;
    if (smokeChannelA != null) map['smoke_channel_a'] = smokeChannelA;
    if (smokeChannelB != null) map['smoke_channel_b'] = smokeChannelB;
    if (smokeCalibA != null) map['smoke_calib_a'] = smokeCalibA;
    if (smokeCalibB != null) map['smoke_calib_b'] = smokeCalibB;
    if (smokeThreshA != null) map['smoke_thresh_a'] = smokeThreshA;
    if (smokeThreshB != null) map['smoke_thresh_b'] = smokeThreshB;
    if (pt100Temperatures != null) map['pt100_temperatures'] = pt100Temperatures;
    if (fanStatus != null) map['fan_status'] = fanStatus;
    if (fanTimer != null) map['fan_timer'] = fanTimer;
    if (stCoLen != null) map['st_co_len'] = stCoLen;
    if (stSmokeLen != null) map['st_smoke_len'] = stSmokeLen;
    if (stH2Len != null) map['st_h2_len'] = stH2Len;
    if (stPt100Len != null) map['st_pt100_len'] = stPt100Len;
    if (stThLen != null) map['st_th_len'] = stThLen;
    if (stPressureLen != null) map['st_pressure_len'] = stPressureLen;
    
    return map;
  }

  static SensorData fromMap(Map<String, dynamic> map) {
    return SensorData(
      nodeId: map['node_id'],
      sensorType: map['sensor_type'],
      timestamp: map['timestamp'],
      temperature: map['temperature'],
      humidity: map['humidity'],
      coPpm: map['co_ppm'],
      h2Percentage: map['h2_percentage'],
      pressureKpa: map['pressure_kpa'],
      pressureTempC: map['pressure_temp_c'],
      smokeStatus: map['smoke_status'],
      smokeExternalTempC: map['smoke_external_temp_c'],
      smokeChannelA: map['smoke_channel_a'],
      smokeChannelB: map['smoke_channel_b'],
      smokeCalibA: map['smoke_calib_a'],
      smokeCalibB: map['smoke_calib_b'],
      smokeThreshA: map['smoke_thresh_a'],
      smokeThreshB: map['smoke_thresh_b'],
      pt100Temperatures: map['pt100_temperatures'],
      fanStatus: map['fan_status'],
      fanTimer: map['fan_timer'],
      stCoLen: map['st_co_len'],
      stSmokeLen: map['st_smoke_len'],
      stH2Len: map['st_h2_len'],
      stPt100Len: map['st_pt100_len'],
      stThLen: map['st_th_len'],
      stPressureLen: map['st_pressure_len'],
    );
  }
}

// CO值历史记录条目
class CoHistoryEntry {
  final int value;
  final int timestamp;
  
  CoHistoryEntry(this.value, this.timestamp);
}

// 温度值历史记录条目
class TempHistoryEntry {
  final double value;
  final int timestamp;
  
  TempHistoryEntry(this.value, this.timestamp);
}

// 压力值历史记录条目
class PressureHistoryEntry {
  final double value;
  final int timestamp;
  
  PressureHistoryEntry(this.value, this.timestamp);
}

// 氢气值历史记录条目
class H2HistoryEntry {
  final double value;
  final int timestamp;
  
  H2HistoryEntry(this.value, this.timestamp);
}

// 烟雾值历史记录条目
class SmokeHistoryEntry {
  final int value;
  final int timestamp;
  
  SmokeHistoryEntry(this.value, this.timestamp);
}

// 湿度值历史记录条目
class HumidityHistoryEntry {
  final double value;
  final int timestamp;
  
  HumidityHistoryEntry(this.value, this.timestamp);
}

// CO突变状态
class CoSpikeState {
  final int spikeValue;           // 突变的CO值
  final int spikeTimestamp;       // 突变发生的时间戳
  final int previousValue;        // 突变前的正常值
  final List<int> spikeWindow;    // 突变后1-2秒内的值窗口
  
  CoSpikeState({
    required this.spikeValue,
    required this.spikeTimestamp,
    required this.previousValue,
    List<int>? spikeWindow,
  }) : spikeWindow = spikeWindow ?? [];
  
  // 检查突变是否稳定（在1-2秒内保持在一定范围内）
  bool isStableSpike(int currentValue, int currentTimestamp, {int stabilityWindowMs = 1500}) {
    // 收集当前值到窗口
    spikeWindow.add(currentValue);
    
    if (currentTimestamp - spikeTimestamp < stabilityWindowMs) {
      // 还在观察期内，继续收集数据
      return false;
    }
    
    // 观察期结束，判断是否稳定
    if (spikeWindow.isEmpty) {
      return false;
    }
    
    // 计算突变后值的范围和变化
    final maxSpike = spikeWindow.reduce((a, b) => a > b ? a : b);
    final minSpike = spikeWindow.reduce((a, b) => a < b ? a : b);
    final avgSpike = spikeWindow.reduce((a, b) => a + b) / spikeWindow.length;
    
    // 判断是否稳定：
    // 1. 值都在突变值的合理范围内（±20%或±50，取较大值）
    final threshold = (spikeValue * 0.2).round().clamp(50, 200);
    final rangeDiff = maxSpike - minSpike;
    final avgDiff = (avgSpike - previousValue).abs();
    
    // 如果范围差异小（稳定）且平均值明显大于之前的值（真实突变）
    return rangeDiff < threshold && avgDiff > threshold;
  }
  
  // 检查是否是传感器故障（突变后很快恢复）
  bool isSensorFault(int currentValue, int currentTimestamp, {int faultWindowMs = 2000}) {
    if (currentTimestamp - spikeTimestamp > faultWindowMs) {
      // 超过故障检测窗口，认为是稳定状态
      return false;
    }
    
    // 如果当前值已经恢复到接近之前的值（±10%），认为是传感器故障
    final recoveryThreshold = (previousValue * 0.1).round().clamp(10, 30);
    final diff = (currentValue - previousValue).abs();
    
    return diff < recoveryThreshold;
  }
}

// 温度突变状态
class TempSpikeState {
  final double spikeValue;           // 突变的温度值
  final int spikeTimestamp;          // 突变发生的时间戳
  final double previousValue;        // 突变前的正常值
  final List<double> spikeWindow;    // 突变后1-2秒内的值窗口
  
  TempSpikeState({
    required this.spikeValue,
    required this.spikeTimestamp,
    required this.previousValue,
    List<double>? spikeWindow,
  }) : spikeWindow = spikeWindow ?? [];
  
  // 检查突变是否稳定（在1-2秒内保持在一定范围内）
  bool isStableSpike(double currentValue, int currentTimestamp, {int stabilityWindowMs = 1500}) {
    // 收集当前值到窗口
    spikeWindow.add(currentValue);
    
    if (currentTimestamp - spikeTimestamp < stabilityWindowMs) {
      // 还在观察期内，继续收集数据
      return false;
    }
    
    // 观察期结束，判断是否稳定
    if (spikeWindow.isEmpty) {
      return false;
    }
    
    // 计算突变后值的范围和变化
    final maxSpike = spikeWindow.reduce((a, b) => a > b ? a : b);
    final minSpike = spikeWindow.reduce((a, b) => a < b ? a : b);
    final avgSpike = spikeWindow.reduce((a, b) => a + b) / spikeWindow.length;
    
    // 判断是否稳定：
    // 1. 值都在突变值的合理范围内（±20%或±10°C，取较大值）
    final threshold = (spikeValue.abs() * 0.2).clamp(10.0, 50.0);
    final rangeDiff = maxSpike - minSpike;
    final avgDiff = (avgSpike - previousValue).abs();
    
    // 如果范围差异小（稳定）且平均值明显大于之前的值（真实突变）
    return rangeDiff < threshold && avgDiff > threshold;
  }
  
  // 检查是否是传感器故障（突变后很快恢复）
  bool isSensorFault(double currentValue, int currentTimestamp, {int faultWindowMs = 2000}) {
    if (currentTimestamp - spikeTimestamp > faultWindowMs) {
      // 超过故障检测窗口，认为是稳定状态
      return false;
    }
    
    // 如果当前值已经恢复到接近之前的值（±10%或±5°C），认为是传感器故障
    final recoveryThreshold = (previousValue.abs() * 0.1).clamp(5.0, 20.0);
    final diff = (currentValue - previousValue).abs();
    
    return diff < recoveryThreshold;
  }
}

class SensorDataService {
  bool _isConnected = false;
  bool _isClientConnected = false;
  String _connectionStatus = '未连接';
  int _rxPackets = 0;
  int _rxBytes = 0;
  int _framesExtracted = 0;
  String _lastRawHex = '';
  String _lastFrameHex = '';
  String _lastTxHex = '';
  int? _lastTxTargetNode;
  
  // 数据更新回调
  Function(int sensorType, SensorData data)? _onDataUpdate;
  
  // 获取节点数据的回调
  Function(int nodeId)? _onGetNodeData;
  
  // 内存中的数据存储
  final List<SensorData> _dataList = [];
  
  // 网络状态检测
  bool _isNetworkAvailable = true;
  Timer? _networkCheckTimer;

  // Modbus TCP服务器
  final ModbusTcpServer _modbusServer = ModbusTcpServer();
  
  // AlertService实例
  final AlertService _alertService = AlertService();
  
  // SettingsService实例
  final SettingsService _settingsService = SettingsService();
  
  // 节点连接状态跟踪
  final Map<int, bool> _nodeConnectionStates = {};
  Timer? _minuteDataTimer;
  
  // 移除测试故障计数器，只检测真实故障
  
  // 每秒汇总日志
  int _dataProcessedCount = 0;
  Timer? _summaryTimer;

  // 设置数据更新回调
  void setDataUpdateCallback({required Function(int sensorType, SensorData data) onDataUpdate}) {
    _onDataUpdate = onDataUpdate;
  }
  
  // 设置获取节点数据的回调
  void setGetNodeDataCallback({required Function(int nodeId) onGetNodeData}) {
    _onGetNodeData = onGetNodeData;
  }

  // 检查网络连接状态（改为检查本地TCP服务器状态，与HarmonyOS版本一致）
  Future<bool> _checkNetworkConnection() async {
    // 检查服务器是否运行和有客户端连接
    if (!_isConnected || !_isClientConnected) {
      return false;
    }
    
    // 检查是否有最近的数据更新（2秒内有数据更新说明连接正常）
    final now = DateTime.now().millisecondsSinceEpoch;
    final hasRecentData = _dataList.any((data) => 
      (now - data.timestamp) < 3000); // 3秒内有数据更新
    
    return hasRecentData;
  }

  // 启动网络状态检测
  void _startNetworkMonitoring() {
    _networkCheckTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final isConnected = await _checkNetworkConnection();
      if (isConnected != _isNetworkAvailable) {
        _isNetworkAvailable = isConnected;
        // 通知CSV服务连接状态
        CsvLoggerService.instance.setConnectionStatus(_isNetworkAvailable);
        if (!_isNetworkAvailable) {
          print('TCP服务器连接断开，停止数据接收');
          _connectionStatus = '服务器未启动';
        } else {
          print('TCP服务器连接恢复');
          _connectionStatus = '客户端已连接';
        }
      }
    });
  }

  // 停止网络状态检测
  void _stopNetworkMonitoring() {
    _networkCheckTimer?.cancel();
    _networkCheckTimer = null;
  }

  // 启动数据接收（真实TCP服务器）
  Future<void> startReceiving() async {
    try {
      _isConnected = true;
      _connectionStatus = '等待客户端连接...';
      print('传感器服务已启动，等待设备连接...');
      // 预创建当天CSV并标记为未连接（等待真正连接/数据到达再变更）
      unawaited(CsvLoggerService.instance.ensureFileForDate(DateTime.now()));
      CsvLoggerService.instance.setConnectionStatus(false);

      // 启动网络状态监控
      _startNetworkMonitoring();
      // 启动CSV聚合与周期写入
      CsvLoggerService.instance.start();
      
      // 不再在CSV保存后向远端服务器发送历史数据

    // 启动Modbus TCP服务器，等待客户端连接
    print('🚀 准备启动Modbus TCP服务器...');
    _modbusServer.start();
    print('✅ Modbus TCP服务器启动完成');
    // 设置 SensorDataService 引用，使 AlertService 可以使用查询判断逻辑
    _alertService.setSensorDataService(this);
    print('✅ AlertService Modbus连接启动完成');

      // 启动每秒汇总日志
      print('🚀 准备启动每秒汇总日志...');
      _startSummaryTimer();
      print('✅ 每秒汇总日志启动完成');

      // 启动真实的TCP服务器
      print('🚀 准备启动TCP服务器...');
      await _startTcpServer();
      print('✅ TCP服务器启动完成');
    } catch (e) {
      print('启动传感器服务失败: $e');
      _isConnected = false;
      _connectionStatus = '启动失败';
    }
  }

  // 启动TCP服务器
  Future<void> _startTcpServer() async {
    try {
      final server = await ServerSocket.bind(InternetAddress('0.0.0.0'), 10123);
      print('TCP服务器已启动，监听地址: 0.0.0.0:10123');
      _connectionStatus = '等待客户端连接...';
      
      server.listen((clientSocket) {
        final clientAddress = clientSocket.remoteAddress.address;
        final clientInfo = '$clientAddress:${clientSocket.remotePort}';
        
        print('客户端已连接: $clientInfo');
        _isClientConnected = true;
        _connectionStatus = '客户端已连接';
        // 通知CSV服务：已连接
        CsvLoggerService.instance.setConnectionStatus(true);
        
        // 发送Modbus TCP连接通知
        _sendModbusConnectionChange(true);
        
        // 保存客户端连接引用
        _currentClientSocket = clientSocket;
        
        // 处理客户端数据
        clientSocket.listen(
          (data) {
            print('收到数据，长度: ${data.length}');
            _rxPackets++;
            _rxBytes += data.length;
            
            // 处理接收到的数据
            _processReceivedData(data);
          },
          onError: (error) {
            print('客户端连接错误: $error');
            _isClientConnected = false;
            _connectionStatus = '客户端断开';
            _currentClientSocket = null;
            // 通知CSV服务：断开
            CsvLoggerService.instance.setConnectionStatus(false);
            
            // 发送Modbus TCP断开通知
            _sendModbusConnectionChange(false);
          },
          onDone: () {
            print('客户端连接关闭');
            _isClientConnected = false;
            _connectionStatus = '等待客户端连接...';
            _currentClientSocket = null;
            // 通知CSV服务：断开
            CsvLoggerService.instance.setConnectionStatus(false);
            
            // 发送Modbus TCP断开通知
            _sendModbusConnectionChange(false);
          },
        );
        
        // 启动主动查询定时器
        _startActiveQuery();
      });
      
      // 保存服务器引用以便后续关闭
      _tcpServer = server;
    } catch (e) {
      print('启动TCP服务器失败: $e');
      _isConnected = false;
      _connectionStatus = '启动失败';
    }
  }

  ServerSocket? _tcpServer;
  Socket? _currentClientSocket;
  Timer? _queryTimer;
  // 动态观测到的节点集合（最多5个用于主动查询）
  final Set<int> _observedNodeIds = <int>{};
  
  // 节点连接状态跟踪：记录每个节点是否已响应
  final Map<int, bool> _nodeResponseStatus = <int, bool>{};
  // 节点连续未收到响应的次数
  final Map<int, int> _nodeNoResponseCount = <int, int>{};
  // 当前正在查询的节点ID（用于响应匹配）
  int? _currentQueryingNodeId;
  // 节点响应等待的Completer
  final Map<int, Completer<bool>> _nodeResponseCompleters = <int, Completer<bool>>{};
  // 是否正在轮询中
  bool _isPolling = false;
  // 当前轮询的节点索引（用于1-5轮流发送）
  int _currentPollingIndex = 0;
  
  // 保留用于兼容的变量
  final Map<int, int> _nodeLastDataTime = {}; // 每个节点的最后数据时间戳
  final Map<int, int> _nodeLastSuccessTime = {}; // 每个节点的最后成功时间戳（用于判断是否真的断开）
  
  // CO值历史记录（用于传感器故障检测）
  // 每个节点维护一个滑动窗口，记录最近3秒内的CO值和时间戳
  final Map<int, List<CoHistoryEntry>> _coHistory = <int, List<CoHistoryEntry>>{};
  
  // CO突变检测状态
  // 用于跟踪可能的突变值，判断是真实预警还是传感器故障
  final Map<int, CoSpikeState> _coSpikeStates = <int, CoSpikeState>{};
  
  // 温度值历史记录（用于传感器故障检测）
  // 每个节点每个通道维护一个滑动窗口，记录最近3秒内的温度值和时间戳
  // key格式: "nodeId_channelIndex"
  final Map<String, List<TempHistoryEntry>> _tempHistory = <String, List<TempHistoryEntry>>{};
  
  // 温度突变检测状态
  // 用于跟踪可能的突变值，判断是真实预警还是传感器故障
  // key格式: "nodeId_channelIndex"
  final Map<String, TempSpikeState> _tempSpikeStates = <String, TempSpikeState>{};
  
  // 压力值历史记录（用于传感器故障检测）
  // 每个节点维护一个滑动窗口，记录最近3秒内的压力值和时间戳
  final Map<int, List<PressureHistoryEntry>> _pressureHistory = <int, List<PressureHistoryEntry>>{};
  
  // 压力突变检测状态
  final Map<int, TempSpikeState> _pressureSpikeStates = <int, TempSpikeState>{};
  
  // 氢气值历史记录（用于传感器故障检测）
  // 每个节点维护一个滑动窗口，记录最近3秒内的氢气值和时间戳
  final Map<int, List<H2HistoryEntry>> _h2History = <int, List<H2HistoryEntry>>{};
  
  // 氢气突变检测状态
  final Map<int, TempSpikeState> _h2SpikeStates = <int, TempSpikeState>{};
  
  // 湿度值历史记录（用于传感器故障检测）
  // 每个节点维护一个滑动窗口，记录最近3秒内的湿度值和时间戳
  final Map<int, List<HumidityHistoryEntry>> _humidityHistory = <int, List<HumidityHistoryEntry>>{};
  
  // 湿度突变检测状态
  final Map<int, TempSpikeState> _humiditySpikeStates = <int, TempSpikeState>{};
  
  // 烟雾值历史记录（用于传感器故障检测）
  // 每个节点每个通道维护一个滑动窗口，记录最近3秒内的烟雾值和时间戳
  // key格式: "nodeId_channelA" 或 "nodeId_channelB"
  final Map<String, List<SmokeHistoryEntry>> _smokeHistory = <String, List<SmokeHistoryEntry>>{};
  
  // 烟雾突变检测状态
  // key格式: "nodeId_channelA" 或 "nodeId_channelB"
  final Map<String, CoSpikeState> _smokeSpikeStates = <String, CoSpikeState>{};

  // 故障/预警保持计时（上报用）：key = "nodeId|faultKey"
  final Map<String, DateTime?> _alertHoldStarts = {};

  bool _shouldHoldTrigger(String key, bool over, int holdMs) {
    final now = DateTime.now();
    final start = _alertHoldStarts[key];
    if (over) {
      if (start == null) {
        _alertHoldStarts[key] = now;
        return false;
      }
      return now.difference(start).inMilliseconds >= holdMs;
    } else {
      _alertHoldStarts[key] = null;
      return false;
    }
  }

  // 处理接收到的数据
  void _processReceivedData(List<int> data) {
    try {
      // 一旦收到任何数据，标记为已连接，避免CSV写入DISCONNECTED
      CsvLoggerService.instance.setConnectionStatus(true);
      // 将数据转换为十六进制字符串用于调试
      final hexData = data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');
      print('收到原始数据: $hexData');
      
      _lastRawHex = hexData;
      
      // 检查是否为查询确认响应 (A5 [nodeId] 0D 0A 00 [CRC16])
      if (data.length >= 7 && data[0] == 0xA5 && data[2] == 0x0D && data[3] == 0x0A && data[4] == 0x00) {
        final nodeId = data[1];
        if (nodeId >= 1 && nodeId <= 9) {
          print('收到查询确认响应: 节点=$nodeId');
          // 保存接收到的原始数据（收到一次记录一次）
          unawaited(CsvLoggerService.instance.saveDataTransferLog(nodeId, '接收', data, DateTime.now()));
          
          // 通知节点响应（如果在等待该节点的响应）
          if (_nodeResponseCompleters.containsKey(nodeId)) {
            final completer = _nodeResponseCompleters[nodeId];
            if (!completer!.isCompleted) {
              completer.complete(true);
              print('节点$nodeId: 收到查询确认响应');
            }
          }
          
          // 节点有响应，重置计数器并标记为已连接
          _nodeNoResponseCount[nodeId] = 0;
          _nodeResponseStatus[nodeId] = true;
          
          // 记录观测到的节点（最多5个）
          _observedNodeIds.add(nodeId);
          if (_observedNodeIds.length > 5) {
            _observedNodeIds.remove(_observedNodeIds.first);
          }
          
          return; // 查询确认响应处理完成，不再继续处理
        }
      }
      
      // 根据HarmonyOS协议解析数据帧
      if (data.length >= 5) {
        final rawNodeId = data[0];
        final frameType = data[1]; // 0x0D=数据帧, 0x0C=状态帧
        final totalLen = data[2];
        
        // 验证节点ID范围（1-9），如果超出范围则跳过处理
        if (rawNodeId < 1 || rawNodeId > 9) {
          print('⚠️ 无效的节点ID: $rawNodeId (范围应为1-9)，跳过处理');
          print('   原始数据: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
          return;
        }
        
        final nodeId = rawNodeId;
        
        // 保存接收到的原始数据（收到一次记录一次）
        unawaited(CsvLoggerService.instance.saveDataTransferLog(nodeId, '接收', data, DateTime.now()));
        
        // 记录观测到的节点（最多5个）
        _observedNodeIds.add(nodeId);
        if (_observedNodeIds.length > 5) {
          // 保持集合不超过5个：移除最早的一个（将Set转List按插入顺序不可保证，这里简单移除一个任意元素）
          _observedNodeIds.remove(_observedNodeIds.first);
        }

        // print('解析帧头: 节点=$nodeId, 类型=0x${frameType.toRadixString(16)}, 长度=$totalLen');
        
        if (frameType == 0x0D) {
          // 数据帧 - 解析传感器数据
          _parseDataFrame(nodeId, data);
        } else if (frameType == 0x0C) {
          // 状态帧 - 解析连接状态
          _parseStatusFrame(nodeId, data);
        }
      }
    } catch (e) {
      print('处理接收数据失败: $e');
    }
  }

  // 解析数据帧 - 根据HarmonyOS原项目逻辑
  void _parseDataFrame(int nodeId, List<int> data) {
    try {
      // print('解析数据帧: 节点=$nodeId, 长度=${data.length}');
      
      // 节点有数据接收，重置计数器并标记为已连接
      _nodeNoResponseCount[nodeId] = 0;
      _nodeResponseStatus[nodeId] = true;
      
      // 通知节点响应（如果在等待该节点的响应）
      if (_nodeResponseCompleters.containsKey(nodeId)) {
        final completer = _nodeResponseCompleters[nodeId];
        if (!completer!.isCompleted) {
          completer.complete(true);
          print('节点$nodeId: 收到数据帧响应');
        }
      }
      
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      
      // 检查是否为复合数据帧 (0x0D)
      if (data.length >= 5 && data[1] == 0x0D) {
        print('检测到复合数据帧，开始解析字段...');
        _parseCompositeDataFrame(nodeId, data, timestamp);
      } else {
        print('非复合数据帧，跳过解析');
      }
      
      // print('数据帧解析完成: 节点=$nodeId');
    } catch (e) {
      print('解析数据帧失败: $e');
    }
  }

  // 解析复合数据帧 - 根据HarmonyOS原项目逻辑
  void _parseCompositeDataFrame(int nodeId, List<int> frame, int timestamp) {
    try {
      int idx = 3; // 从第3个字节开始解析字段
      
      while (idx + 2 <= frame.length - 2) {
        final fieldId = frame[idx++];
        print('发现字段: ID=0x${fieldId.toRadixString(16).padLeft(2, '0')} (idx=${idx - 1})');
        
        if (fieldId < 0x02 || fieldId > 0x07) {
          print('字段解析结束，遇到字段ID: 0x${fieldId.toRadixString(16).padLeft(2, '0')}');
          break;
        }
        
        if (idx >= frame.length - 2) break;
        final fieldLen = frame[idx++];
        
        // 检查字段长度是否足够
        if (idx + fieldLen + 2 > frame.length - 2) {
          print('字段长度越界: id=0x${fieldId.toRadixString(16)} len=$fieldLen idx=$idx 总长=${frame.length}');
          break;
        }
        
        final payloadStart = idx;
        final payload = frame.sublist(payloadStart, payloadStart + fieldLen);
        print('字段开始: id=0x${fieldId.toRadixString(16)} len=$fieldLen at=$payloadStart..${payloadStart + fieldLen - 1}');
        idx += fieldLen;
        
        // 跳过填充字节
        while (idx < frame.length && frame[idx] == 0x00) {
          idx++;
        }
        
        // 可选分隔符 0x0D 0x0A：仅当紧随其后才消费
        if (idx + 1 < frame.length && frame[idx] == 0x0D && frame[idx + 1] == 0x0A) {
          idx += 2;
        }
        while (idx < frame.length && frame[idx] == 0x00) idx++;
        
        // 根据字段ID解析数据
        _parseFieldData(nodeId, fieldId, payload, timestamp);
      }
      
      // 复合数据帧解析完成（不再主动发送，等待客户端请求）
    } catch (e) {
      print('解析复合数据帧失败: $e');
    }
  }

  // 解析字段数据
  void _parseFieldData(int nodeId, int fieldId, List<int> payload, int timestamp) {
    try {
      switch (fieldId) {
        case 0x02: // CO传感器
          if (payload.length >= 2) {
            final rawCo = (payload[0] << 8) | payload[1];
            // 使用时间窗口检测过滤CO值，区分真实预警和传感器故障
            final co = _filterCoValueWithTimeWindow(nodeId, rawCo, timestamp);
            if (rawCo != co) {
              print('CO值过滤: 节点=$nodeId, 原始值=$rawCo, 过滤后=$co ppm');
            } else {
              print('复合帧-CO: 节点=$nodeId, CO=$co ppm');
            }
            final coData = SensorData(
              nodeId: nodeId,
              sensorType: 2, // CO_SENSOR
              timestamp: timestamp,
              coPpm: co,
            );
            _notifyDataUpdate(2, coData);
          }
          break;
          
        case 0x03: // 烟雾传感器
          if (payload.length == 0x14) { // 20字节
            final t0a = payload[0];
            final t0b = payload[1];
            // 协议定义：通道采样/热敏温度均为低字节在前、 高字节在后
            final channelA = (payload[3] << 8) | payload[2];
            final channelB = (payload[5] << 8) | payload[4];
            
            // 标定零点：通道A标定零点[7:0] + 通道A标定零点[15:8]
            final calibALow = payload[6];   // 通道A标定零点[7:0]
            final calibAHigh = payload[7];  // 通道A标定零点[15:8]
            final calibA = (calibAHigh << 8) | calibALow;
            
            final calibBLow = payload[8];  // 通道B标定零点[7:0]
            final calibBHigh = payload[9]; // 通道B标定零点[15:8]
            final calibB = (calibBHigh << 8) | calibBLow;
            
            // 报警阈值：通道A报警阈值[7:0] + 通道A报警阈值[15:8]
            final threshALow = payload[10];  // 通道A报警阈值[7:0]
            final threshAHigh = payload[11]; // 通道A报警阈值[15:8]
            final threshA = (threshAHigh << 8) | threshALow;
            
            final threshBLow = payload[12];  // 通道B报警阈值[7:0]
            final threshBHigh = payload[13]; // 通道B报警阈值[15:8]
            final threshB = (threshBHigh << 8) | threshBLow;
            
            // 比值和报警计数
            final ratio = payload[14];
            final alarmCount = payload[15];
            
            // 热敏电阻A/D采样值（外部温度）
            final tempRaw = (payload[17] << 8) | payload[16];
            // 处理可能的负值：>32768 代表负数，两补码还原
            final signedTempRaw = tempRaw > 32768 ? (tempRaw - 65536) : tempRaw;
            final tempC = signedTempRaw * 0.01; // 实际值=返回值×0.01(°C)
            print('烟雾外部温度解析: 原始值=$tempRaw (0x${tempRaw.toRadixString(16)}) 有符号=$signedTempRaw -> ${tempC.toStringAsFixed(2)}°C');
            
            // 解析通道状态：T0A和T0B状态字节
            // Bit 0: 通道已标定为1,否则为0
            // Bit 1: 预警状态 (从右到左第二位)
            // Bit 2: 故障状态 (从右到左第三位) 
            // Bit 3: 传感器状态 (从右到左第四位)
            final t0aCalibrated = (t0a & 0x01) != 0;  // Bit 0: 通道A已标定
            final t0aWarning = (t0a & 0x02) != 0;     // Bit 1: 通道A预警
            final t0aFault = (t0a & 0x04) != 0;       // Bit 2: 通道A故障
            final t0aSensorStatus = (t0a & 0x08) != 0; // Bit 3: 通道A传感器状态
            
            final t0bCalibrated = (t0b & 0x01) != 0;  // Bit 0: 通道B已标定
            final t0bWarning = (t0b & 0x02) != 0;     // Bit 1: 通道B预警
            final t0bFault = (t0b & 0x04) != 0;       // Bit 2: 通道B故障
            final t0bSensorStatus = (t0b & 0x08) != 0; // Bit 3: 通道B传感器状态
            
            // 构建烟雾状态：基于通道状态判断
            // 优先级：故障 > 预警 > 正常
            int smokeStatus = 0;
            if (t0aFault || t0bFault) {
              // 有故障显示故障
              smokeStatus = 0x04; // 故障状态
            } else if (t0aWarning || t0bWarning) {
              // 有预警显示预警
              smokeStatus = 0x02; // 预警状态
            } else {
              // 正常状态
              smokeStatus = 0x01; // 正常状态
            }
            
            // 应用烟雾过滤
            final filteredChannelA = _filterSmokeValueWithTimeWindow(nodeId, 'A', channelA, timestamp);
            final filteredChannelB = _filterSmokeValueWithTimeWindow(nodeId, 'B', channelB, timestamp);
            
            print('复合帧-烟雾: A=$channelA B=$channelB aA=$calibA aB=$calibB TA=$threshA TB=$threshB 比=$ratio 报警=$alarmCount 温度=${tempC.toStringAsFixed(2)}');
            print('烟雾通道状态: T0A=0x${t0a.toRadixString(16)} (标定=$t0aCalibrated, 预警=$t0aWarning, 故障=$t0aFault, 传感器=$t0aSensorStatus)');
            print('烟雾通道状态: T0B=0x${t0b.toRadixString(16)} (标定=$t0bCalibrated, 预警=$t0bWarning, 故障=$t0bFault, 传感器=$t0bSensorStatus)');
            print('烟雾状态判断: 最终状态=0x${smokeStatus.toRadixString(16)} (${smokeStatus == 0x04 ? '故障' : smokeStatus == 0x02 ? '预警' : '正常'})');
            print('烟雾参数解析: calibA=0x${calibA.toRadixString(16)}($calibA), calibB=0x${calibB.toRadixString(16)}($calibB)');
            print('烟雾参数解析: threshA=0x${threshA.toRadixString(16)}($threshA), threshB=0x${threshB.toRadixString(16)}($threshB)');
            print('烟雾计算参数验证: channelA=$channelA, calibA=$calibA, threshA=$threshA');
            print('烟雾计算参数验证: channelB=$channelB, calibB=$calibB, threshB=$threshB');
            print('烟雾原始数据解析: payload[0-19]=${payload.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');
            final smokeData = SensorData(
              nodeId: nodeId,
              sensorType: 5, // SMOKE_SENSOR
              timestamp: timestamp,
              smokeStatus: smokeStatus,
              smokeChannelA: filteredChannelA,
              smokeChannelB: filteredChannelB,
              smokeCalibA: calibA,
              smokeCalibB: calibB,
              smokeThreshA: threshA,
              smokeThreshB: threshB,
              smokeExternalTempC: tempC,
            );
            _notifyDataUpdate(5, smokeData);
          } else {
            print('烟雾字段长度异常: 期望=20 实际=${payload.length}');
          }
          break;
          
        case 0x04: // H2传感器（表9 字段4：1字节%LEL，不做范围限制）
          if (payload.length >= 1) {
            final raw = payload[0];
            double h2 = raw.toDouble();
            // 应用氢气过滤
            h2 = _filterH2ValueWithTimeWindow(nodeId, h2, timestamp);
            print('复合帧-H2: 原始值=$raw, 解析值=${h2.toStringAsFixed(1)}%LEL');
            final h2Data = SensorData(
              nodeId: nodeId,
              sensorType: 3, // H2_SENSOR
              timestamp: timestamp,
              h2Percentage: h2,
            );
            _notifyDataUpdate(3, h2Data);
          } else {
            print('H2字段长度异常: 期望>=1 实际=${payload.length}');
          }
          break;
          
        case 0x05: // PT100传感器
          final temps = <double>[];
          final rawTemps = <int>[];
          final useLen = (payload.length & ~1).clamp(0, 24); // 取偶数，最多24字节(12个通道)
          print('PT100解析: payload长度=${payload.length}, useLen=$useLen');
          
          for (int p = 0; p < useLen; p += 2) {
            final raw = (payload[p] << 8) | payload[p + 1];
            rawTemps.add(raw);
            double temp;
            if (raw == 0x8066) {
              temp = -999.0; // 开路标记
            } else {
              final signedRaw = raw > 32768 ? (raw - 65536) : raw;
              temp = signedRaw * 0.01;
              // 精度控制：保留2位小数
              temp = double.parse(temp.toStringAsFixed(2));
            }
            
            // 应用温度过滤（排除开路值）
            final channelIndex = p ~/ 2;
            if (temp != -999.0) {
              temp = _filterTempValueWithTimeWindow(nodeId, channelIndex, temp, timestamp);
            }
            
            temps.add(temp);
            print('PT100[$p/2]: 原始=0x${raw.toRadixString(16).padLeft(4, '0')}($raw) ${raw == 0x8066 ? '开路' : '有符号=${raw > 32768 ? (raw - 65536) : raw}'} -> ${temp == -999.0 ? '开路' : '${temp.toStringAsFixed(2)}°C'}');
          }
          // 确保有12个通道
          while (temps.length < 12) {
            temps.add(-999.0);
          }
          print('复合帧-PT100原始值: ${rawTemps.map((r) => '0x${r.toRadixString(16).padLeft(4, '0')}($r)').join(', ')}');
          print('复合帧-PT100温度: ${temps.map((t) => t == -999 ? '开路' : '${t.toStringAsFixed(1)}°C').join(', ')}');
          final pt100Data = SensorData(
            nodeId: nodeId,
            sensorType: 7, // PT100_SENSOR
            timestamp: timestamp,
            pt100Temperatures: jsonEncode(temps),
          );
          _notifyDataUpdate(7, pt100Data);
          break;
          
        case 0x06: // 温湿度传感器
          if (payload.length == 0x04) {
            final tRaw = (payload[0] << 8) | payload[1];
            final hRaw = (payload[2] << 8) | payload[3];
            final rawT = -45 + 175 * (tRaw / 65535);
            final rawH = 100 * (hRaw / 65535);
            
            // 应用温度过滤（使用通道索引-1表示环境温度）
            final filteredT = _filterTempValueWithTimeWindow(nodeId, -1, rawT, timestamp);
            // 应用湿度过滤
            final filteredH = _filterHumidityValueWithTimeWindow(nodeId, rawH, timestamp);
            
            if (rawT != filteredT || rawH != filteredH) {
              print('温湿度值过滤: 节点=$nodeId, 温度: $rawT→$filteredT°C, 湿度: $rawH→$filteredH%');
            } else {
              print('复合帧-温湿度: T=${filteredT.toStringAsFixed(1)}°C H=${filteredH.toStringAsFixed(1)}%');
            }
            
            final tempHumidityData = SensorData(
              nodeId: nodeId,
              sensorType: 1, // TEMP_HUMIDITY_SENSOR
              timestamp: timestamp,
              temperature: filteredT,
              humidity: filteredH,
            );
            _notifyDataUpdate(1, tempHumidityData);
          }
          break;
          
        case 0x07: // 压力传感器
          if (payload.length == 0x05) {
            final pRaw = (payload[0] << 16) | (payload[1] << 8) | payload[2];
            final tempRaw = (payload[3] << 8) | payload[4];
            
            double pressure;
            if (pRaw > 8388608) {
              pressure = 1000 * ((pRaw - 16777216) / 8388608.0) - 50;
            } else {
              pressure = 1000 * (pRaw / 8388608.0) - 50;
            }
            
            double temperature;
            if (tempRaw > 32768) {
              temperature = (tempRaw - 65536) / 256.0;
            } else {
              temperature = tempRaw / 256.0;
            }
            
            // 应用压力过滤
            pressure = _filterPressureValueWithTimeWindow(nodeId, pressure, timestamp);
            
            // 应用温度突变过滤（使用通道索引-2表示压力传感器温度）
            final filteredTemp = _filterTempValueWithTimeWindow(nodeId, -2, temperature, timestamp);
            if (temperature != filteredTemp) {
              print('压力传感器温度过滤: 节点=$nodeId, 原始值=$temperature→过滤值=$filteredTemp°C');
            }
            
            print('复合帧-压力: ${pressure.toStringAsFixed(1)} kPa, 温度: ${filteredTemp.toStringAsFixed(1)}°C');
            final pressureData = SensorData(
              nodeId: nodeId,
              sensorType: 4, // PRESSURE_SENSOR
              timestamp: timestamp,
              pressureKpa: pressure,
              pressureTempC: filteredTemp,
            );
            _notifyDataUpdate(4, pressureData);
          }
          break;
      }
    } catch (e) {
      print('解析字段数据失败: $e');
    }
  }

  // 解析状态帧（0x0C）
  void _parseStatusFrame(int nodeId, List<int> data) {
    try {
      // print('解析状态帧: 节点=$nodeId');
      
      // 状态帧包含各传感器的连接状态
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      
      // 创建状态数据
      final statusData = SensorData(
        nodeId: nodeId,
        sensorType: 8, // STATUS_OVERVIEW
        timestamp: timestamp,
        stCoLen: 2,      // CO传感器连接
        stSmokeLen: 20,  // 烟雾传感器连接
        stH2Len: 1,      // H2传感器连接
        stPt100Len: 20,  // PT100传感器连接
        stThLen: 4,      // 温湿度传感器连接
        stPressureLen: 5, // 压力传感器连接
      );
      
      _notifyDataUpdate(8, statusData);
      // print('状态帧解析完成: 节点=$nodeId');
    } catch (e) {
      print('解析状态帧失败: $e');
    }
  }

  // 通知数据更新
  void _notifyDataUpdate(int sensorType, SensorData data) {
    // 数据已经在_processRealSensorData中添加，这里不需要重复添加
    // 精简日志：只在调试模式下输出详细信息
    // print('处理传感器数据: 节点=${data.nodeId}, 类型=$sensorType, 列表长度=${_dataList.length}');
    
    // 增加数据处理计数器
    _dataProcessedCount++;
    
    // 更新节点最后数据时间戳
    final now = DateTime.now().millisecondsSinceEpoch;
    _nodeLastDataTime[data.nodeId] = now;
    _nodeLastSuccessTime[data.nodeId] = now; // 更新最后成功时间
    
    if (_onDataUpdate != null) {
      _onDataUpdate!(sensorType, data);
      // print('通知数据更新: 节点=${data.nodeId}, 类型=$sensorType');
    }
    // 有有效数据即视为在线
    CsvLoggerService.instance.setConnectionStatus(true);
    // 聚合为节点快照，交由定时任务每秒统一写入一次
    CsvLoggerService.instance.updateNodeSnapshot(data);
    
    // 检查节点连接状态变化（有数据时标记为已连接）
    _checkNodeConnectionChange(data.nodeId, true);
    
    // 检查故障信息
    _checkFaultInfo(data);
    
      // 通知节点响应（如果在等待该节点的响应）
      if (_nodeResponseCompleters.containsKey(data.nodeId)) {
        final completer = _nodeResponseCompleters[data.nodeId];
        if (!completer!.isCompleted) {
          completer.complete(true);
          print('节点${data.nodeId}: 收到数据帧响应');
        }
      }
  }

  // 启动主动查询
  void _startActiveQuery() {
    // 节点1-5轮流发送，间隔200毫秒
    _queryTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) async {
      if (!_isClientConnected || _currentClientSocket == null) {
        timer.cancel();
        return;
      }

      // 如果正在轮询中，跳过本次
      if (_isPolling) {
        return;
      }

      // 节点1-5轮流发送
      final List<int> targetIds = [1, 2, 3, 4, 5];
      final nodeId = targetIds[_currentPollingIndex % targetIds.length];
      _currentPollingIndex++;
      
      _isPolling = true;
      try {
        // 创建Completer等待响应
        final completer = Completer<bool>();
        _nodeResponseCompleters[nodeId] = completer;
        _currentQueryingNodeId = nodeId;
        
        // 发送数据传送指令
        _sendDataTransferCommand(nodeId);
        print('节点$nodeId: 发送数据传输指令');
        
        // 等待响应，最多等待150毫秒
        try {
          final hasResponse = await completer.future.timeout(
            const Duration(milliseconds: 150),
            onTimeout: () {
              print('节点$nodeId: 等待超时（150毫秒内无响应）');
              return false;
            },
          );
          
          if (hasResponse) {
            // 收到响应，重置计数器并标记为已连接
            _nodeNoResponseCount[nodeId] = 0;
            _nodeResponseStatus[nodeId] = true;
            print('节点$nodeId: 收到响应，标记为已连接');
          } else {
            // 未收到响应，增加计数器
            final count = (_nodeNoResponseCount[nodeId] ?? 0) + 1;
            _nodeNoResponseCount[nodeId] = count;
            print('节点$nodeId: 未收到响应，连续未响应次数: $count');
            
            // 如果连续10次未收到响应，标记为未连接
            if (count >= 10) {
              _nodeResponseStatus[nodeId] = false;
              print('节点$nodeId: 连续10次未收到响应，标记为未连接');
            }
          }
        } catch (e) {
          print('节点$nodeId: 等待异常: $e');
          // 异常也视为未收到响应
          final count = (_nodeNoResponseCount[nodeId] ?? 0) + 1;
          _nodeNoResponseCount[nodeId] = count;
          if (count >= 10) {
            _nodeResponseStatus[nodeId] = false;
            print('节点$nodeId: 连续10次未收到响应，标记为未连接');
          }
        }
        
        // 清理Completer
        _nodeResponseCompleters.remove(nodeId);
        _currentQueryingNodeId = null;
      } finally {
        _isPolling = false;
      }
    });
  }

  // 对外暴露已观测到的节点（调试/使用）
  List<int> getObservedNodeIds() => _observedNodeIds.take(5).toList();


  // 发送数据传送指令
  void _sendDataTransferCommand(int nodeId) {
    try {
      if (_currentClientSocket == null) return;
      
      // 根据HarmonyOS协议：A5 [addr] 0D 0A 00 + CRC16
      final payload = [0xA5, nodeId, 0x0D, 0x0A, 0x00];
      final crc = _calculateCRC16(payload);
      final frame = [...payload, crc & 0xFF, (crc >> 8) & 0xFF];
      
      _currentClientSocket!.add(frame);
      
      // 保存发送的指令（发送一次记录一次）
      unawaited(CsvLoggerService.instance.saveDataTransferLog(nodeId, '发送', frame, DateTime.now()));
      
      // print('发送数据传送指令到节点$nodeId: ${frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    } catch (e) {
      print('发送数据传送指令失败: $e');
    }
  }

  // 计算CRC16
  int _calculateCRC16(List<int> data) {
    int crc = 0xFFFF;
    for (int i = 0; i < data.length; i++) {
      crc ^= data[i];
      for (int j = 0; j < 8; j++) {
        if ((crc & 0x0001) != 0) {
          crc = (crc >> 1) ^ 0xA001;
        } else {
          crc = crc >> 1;
        }
      }
    }
    return crc & 0xFFFF;
  }


  // 停止数据接收
  void stopReceiving() {
    _isConnected = false;
    _isClientConnected = false;
    _connectionStatus = '已停止';
    _stopNetworkMonitoring();
    
    // 停止查询定时器
    _queryTimer?.cancel();
    _queryTimer = null;
    
    // 停止每分钟数据保存定时器
    _minuteDataTimer?.cancel();
    _minuteDataTimer = null;
    
    // 停止Modbus TCP服务器
    _modbusServer.stop();
    
    // 停止AlertService的Modbus TCP连接
    _alertService.stopModbusConnection();
    
    // 停止汇总定时器
    _summaryTimer?.cancel();
    _summaryTimer = null;
    
    // 关闭客户端连接
    _currentClientSocket?.close();
    _currentClientSocket = null;
    
    // 关闭TCP服务器
    _tcpServer?.close();
    _tcpServer = null;
    
    print('传感器服务已停止');
  }

  // 处理真实传感器数据
  void processRealData(int nodeId, int sensorType, Map<String, dynamic> data) async {
    try {
      print('Processing real sensor data for node $nodeId, type $sensorType');
      
      final sensorData = SensorData(
        nodeId: nodeId,
        sensorType: sensorType,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        temperature: data['temperature'],
        humidity: data['humidity'],
        coPpm: data['co_ppm'],
        h2Percentage: data['h2_percentage'],
        pressureKpa: data['pressure_kpa'],
        pressureTempC: data['pressure_temp_c'],
        smokeStatus: data['smoke_status'],
        smokeExternalTempC: data['smoke_external_temp_c'],
        smokeChannelA: data['smoke_channel_a'],
        smokeChannelB: data['smoke_channel_b'],
        pt100Temperatures: data['pt100_temperatures'],
        fanStatus: data['fan_status'],
        fanTimer: data['fan_timer'],
        stCoLen: data['st_co_len'],
        stSmokeLen: data['st_smoke_len'],
        stH2Len: data['st_h2_len'],
        stPt100Len: data['st_pt100_len'],
        stThLen: data['st_th_len'],
        stPressureLen: data['st_pressure_len'],
      );
      
      print('Created SensorData with PT100: ${sensorData.pt100Temperatures}');
      
      // 存储数据到列表
      _dataList.add(sensorData);
      print('📝 数据已添加到列表: 节点${sensorData.nodeId}, 类型=$sensorType, 当前列表长度=${_dataList.length}');
      
      // 通知数据更新
      if (_onDataUpdate != null) {
        _onDataUpdate!(sensorType, sensorData);
      }
    } catch (e) {
      print('处理真实传感器数据失败: $e');
    }
  }

  // 获取所有节点数据
  Future<List<SensorData>> getAllNodeData() async {
    return List.from(_dataList)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  // 获取温度历史正常值（用于节点详细页面计算）
  // 如果当前值异常，返回该通道最近的历史正常值
  double? getTempHistoryValue(int nodeId, int channelIndex, double currentValue) {
    // 检查当前值是否异常（超出合理范围）
    if (currentValue < -50 || currentValue > 200 || currentValue == -999) {
      final historyKey = '${nodeId}_$channelIndex';
      final history = _tempHistory[historyKey];
      if (history != null && history.isNotEmpty) {
        // 返回最近的有效值
        return history.last.value;
      }
      // 没有历史值，返回null（让调用者决定使用什么默认值）
      return null;
    }
    // 当前值正常，返回null（使用当前值）
    return null;
  }

  // 获取连接状态
  bool isConnected() => _isConnected;
  bool isClientConnected() => _isClientConnected;
  String getConnectionStatus() => _connectionStatus;
  
  // 获取节点连接状态（基于查询判断逻辑）
  bool isNodeConnected(int nodeId) {
    // 从节点连接状态映射中获取
    final connectionState = _nodeConnectionStates[nodeId] ?? false;
    
    // 如果状态为未连接，直接返回false
    if (!connectionState) {
      return false;
    }
    
    // 如果状态为已连接，再检查最后一次成功时间
    final lastSuccessTime = _nodeLastSuccessTime[nodeId] ?? 0;
    if (lastSuccessTime == 0) {
      return false;
    }
    
    // 检查距离最后一次成功是否超过配置的超时时间
    final now = DateTime.now().millisecondsSinceEpoch;
    final timeSinceLastSuccess = now - lastSuccessTime;
    final disconnectTimeoutMs = _settingsService.nodeDisconnectTimeoutMs;
    
    // 只有距离最后一次成功未超过超时时间，才认为已连接
    return timeSinceLastSuccess < disconnectTimeoutMs;
  }
  
  // 获取网络连接状态
  bool isNetworkConnected() => _isNetworkAvailable;

  // 获取Modbus TCP服务器连接状态
  bool isModbusServerConnected() => _modbusServer.isRunning;

  // 检测Modbus TCP服务器连接
  Future<bool> checkModbusServerConnection() async {
    return _modbusServer.isRunning;
  }

  // 获取Modbus TCP服务器信息
  String getModbusServerInfo() => 'Modbus TCP服务器: 端口${_modbusServer.listenPort}, 客户端数: ${_modbusServer.clientCount}';

  // 获取运行时统计
  String getRuntimeStats() {
    return '接收包数: $_rxPackets, 接收字节: $_rxBytes, 提取帧数: $_framesExtracted';
  }

  // 获取提取的帧数
  int getFramesExtracted() => _framesExtracted;

  // 获取最后的十六进制样本
  Map<String, String> getLastHexSamples() {
    return {
      'raw': _lastRawHex,
      'frame': _lastFrameHex,
      'tx': _lastTxHex,
    };
  }

  // 重置所有数据
  Future<Map<String, int>> resetAllData() async {
    try {
      print('⚠️ 重置所有数据被调用！当前数据列表长度: ${_dataList.length}');
      _dataList.clear();
      _rxPackets = 0;
      _rxBytes = 0;
      _framesExtracted = 0;
      _lastRawHex = '';
      _lastFrameHex = '';
      _lastTxHex = '';
      _lastTxTargetNode = null;
      
      print('所有数据已重置');
      return {'dbResult': _dataList.length};
    } catch (e) {
      print('重置数据失败: $e');
      return {'dbResult': 0};
    }
  }

  // 发送状态查询命令
  void sendStatusQueryCommand(int nodeId) {
    try {
      print('发送状态查询命令到节点 $nodeId');
      // 这里应该实现真实的命令发送逻辑
      // 目前只是打印日志
    } catch (e) {
      print('发送状态查询命令失败: $e');
    }
  }

  // 启动每秒汇总日志
  void _startSummaryTimer() {
    _summaryTimer?.cancel();
    _summaryTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (_dataProcessedCount > 0) {
        print('📊 数据处理汇总: 本秒处理了$_dataProcessedCount条数据，当前数据列表长度: ${_dataList.length}');
        _dataProcessedCount = 0; // 重置计数器
      }
    });
    print('每秒汇总日志已启动');
  }




  // 获取节点的最新数据
  SensorData? _getLatestNodeData(int nodeId) {
    print('🔍 查询节点${nodeId}的最新数据...');
    
    // 直接从当前存储的数据中获取最新数据
    // 查找该节点的最新数据
    SensorData? latestData;
    int? latestTimestamp;
    
    for (final data in _dataList) {
      if (data.nodeId == nodeId) {
        if (latestTimestamp == null || data.timestamp > latestTimestamp) {
          latestData = data;
          latestTimestamp = data.timestamp;
        }
      }
    }
    
    if (latestData != null) {
      print('✅ 找到节点${nodeId}的最新数据: ${latestData.timestamp}');
      return latestData;
    } else {
      print('⚠️ 节点${nodeId}暂无数据');
      return null;
    }
  }

  // 发送Modbus TCP连接状态变化（已废弃，不再主动发送）
  void _sendModbusConnectionChange(bool isConnected) {
    // 不再主动发送连接状态变化，等待客户端请求
    print('Modbus TCP连接状态变化: $isConnected (不再主动发送)');
  }

  // 检查节点连接状态变化（带状态确认机制，避免频繁切换）
  void _checkNodeConnectionChange(int nodeId, bool isConnected) {
    final wasConnected = _nodeConnectionStates[nodeId] ?? false;
    
    if (isConnected) {
      // 标记为已连接：立即生效（有数据证明已连接）
      if (!wasConnected) {
        _nodeConnectionStates[nodeId] = true;
        _nodeLastSuccessTime[nodeId] = DateTime.now().millisecondsSinceEpoch;
      
      final timestamp = DateTime.now().toIso8601String();
      // 不再主动发送节点连接状态变化
      print('节点$nodeId连接状态变化: $isConnected (不再主动发送)');
      // _modbusClient.sendNodeConnectionChange(
      //   nodeId: nodeId,
      //   isConnected: true,
      //   timestamp: timestamp,
      // );
      
      print('节点$nodeId连接状态变化: 已连接');
      } else {
        // 已连接状态下收到数据，更新最后成功时间
        _nodeLastSuccessTime[nodeId] = DateTime.now().millisecondsSinceEpoch;
      }
    } else {
      // 标记为未连接：需要确认机制，避免短暂延迟导致的误判
      if (wasConnected) {
        final lastSuccessTime = _nodeLastSuccessTime[nodeId] ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        final timeSinceLastSuccess = now - lastSuccessTime;
        
        // 从设置服务获取断开连接判断超时时间（默认10秒）
        final disconnectTimeoutMs = _settingsService.nodeDisconnectTimeoutMs;
        
        // 只有在距离最后一次成功超过配置的超时时间，才真正标记为未连接
        // 这样可以避免因短暂的数据延迟导致频繁切换
        if (timeSinceLastSuccess >= disconnectTimeoutMs) {
          _nodeConnectionStates[nodeId] = false;
          
          final timestamp = DateTime.now().toIso8601String();
          // 不再主动发送节点连接状态变化
    print('节点$nodeId连接状态变化: $isConnected (不再主动发送)');
    // _modbusClient.sendNodeConnectionChange(
    //   nodeId: nodeId,
    //   isConnected: false,
    //   timestamp: timestamp,
    // );
    
    print('节点$nodeId连接状态变化: 已断开 (距离最后成功: ${timeSinceLastSuccess}ms >= ${disconnectTimeoutMs}ms)');
        } else {
          // 还在保护期内，不切换状态，但记录日志
          print('节点$nodeId 无响应但仍在保护期内 (距离最后成功: ${timeSinceLastSuccess}ms < ${disconnectTimeoutMs}ms)，保持已连接状态');
        }
      }
    }
  }

  // 发送历史数据到远端服务器（已废弃，不再主动发送）
  void _sendHistoryDataToServer(dynamic data) {
    // 不再主动发送历史数据，等待客户端请求
    print('历史数据已准备: 节点${data.nodeId} (不再主动发送)');
    return;
    // if (!_modbusServer.isRunning) {
    //   print('⚠️ Modbus TCP服务器未运行，跳过历史数据发送');
    //   return;
    // }
    
    final timestamp = DateTime.now().toIso8601String();
    
    // 判断数据类型：如果是SensorData，转换为Map；如果已经是Map，直接使用
    Map<String, dynamic> sensorDataMap;
    int nodeId;
    
    if (data is SensorData) {
      sensorDataMap = data.toMap();
      nodeId = data.nodeId;
    } else if (data is Map<String, dynamic>) {
      sensorDataMap = data;
      nodeId = data['node_id'] as int? ?? 0;
    } else {
      print('❌ 未知的数据类型: ${data.runtimeType}');
      return;
    }
    
    print('📤 发送完整历史数据到远端服务器: 节点$nodeId');
    print('📊 历史数据包含字段: ${sensorDataMap.keys.join(', ')}');
    
    // 不再主动发送历史数据，等待客户端请求
    print('历史数据已准备: 节点$nodeId (不再主动发送)');
    // _modbusClient.sendMinuteHistoryData(
    //   nodeId: nodeId,
    //   sensorData: sensorDataMap,
    //   timestamp: timestamp,
    // );
  }

  // CO值时间窗口过滤方法
  // 使用时间窗口检测区分真实预警和传感器故障
  int _filterCoValueWithTimeWindow(int nodeId, int rawCo, int timestamp) {
    // 1. 基本范围检查：负数或超过10000ppm认为无效
    if (rawCo < 0 || rawCo > 10000) {
      print('CO基本范围检查: 节点=$nodeId, 原始值=$rawCo超出范围[0, 10000]');
      // 如果有历史值，返回最近的有效值
      final history = _coHistory[nodeId];
      if (history != null && history.isNotEmpty) {
        final lastValidValue = history.last.value;
        print('CO使用历史值: 节点=$nodeId, 使用最近有效值=$lastValidValue ppm');
        return lastValidValue;
      }
      // 没有历史值，返回0
      return 0;
    }
    
    // 2. 获取历史记录
    final history = _coHistory.putIfAbsent(nodeId, () => <CoHistoryEntry>[]);
    
    // 3. 清理过期历史记录（只保留最近3秒的数据）
    final expireTime = timestamp - 3000; // 3秒
    history.removeWhere((entry) => entry.timestamp < expireTime);
    
    // 4. 如果没有历史数据，直接使用当前值并记录
    if (history.isEmpty) {
      history.add(CoHistoryEntry(rawCo, timestamp));
      return rawCo;
    }
    
    // 5. 获取最近的有效值
    final lastEntry = history.last;
    final lastValue = lastEntry.value;
    
    // 6. 检查是否存在正在观察的突变状态
    final spikeState = _coSpikeStates[nodeId];
    
    if (spikeState != null) {
      // 正在观察一个突变状态
      
      // 检查突变值是否超过固定范围（具体数值范围）
      final fixedRange = 500.0; // 固定范围：500ppm
      final spikeAbsValue = rawCo.abs();
      final previousAbsValue = spikeState.previousValue.abs();
      
      // 如果当前突变值的绝对值超过异常值前的数值绝对值的固定范围，使用异常前的值
      if (spikeAbsValue > previousAbsValue + fixedRange) {
        print('CO观察期内突变值超过固定范围: 节点=$nodeId, 当前值=$rawCo, 异常前值=${spikeState.previousValue}, 固定范围=$fixedRange, 使用异常前值');
        // 清除突变状态
        _coSpikeStates.remove(nodeId);
        // 使用异常前的值
        history.add(CoHistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查是否是传感器故障（突变后很快恢复）
      if (spikeState.isSensorFault(rawCo, timestamp)) {
        print('CO传感器故障检测: 节点=$nodeId, 突变值=${spikeState.spikeValue}, 当前值=$rawCo, 已恢复到${spikeState.previousValue}附近，判定为传感器故障');
        // 清除突变状态
        _coSpikeStates.remove(nodeId);
        // 使用之前的正常值
        history.add(CoHistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查突变是否稳定（在1-2秒内保持在一定范围内）
      if (spikeState.isStableSpike(rawCo, timestamp)) {
        print('CO稳定突变检测: 节点=$nodeId, 突变值=${spikeState.spikeValue}在观察期内保持稳定，判定为真实预警/故障');
        // 清除突变状态，确认是真实的值
        _coSpikeStates.remove(nodeId);
        // 使用突变后的值（真实预警/故障）
        history.add(CoHistoryEntry(rawCo, timestamp));
        return rawCo;
      }
      
      // 还在观察期内，继续收集数据
      spikeState.spikeWindow.add(rawCo);
      // 暂时使用之前的正常值，等待观察期结束
      return spikeState.previousValue;
    }
    
    // 7. 检测是否发生突变
    // 突变定义为：值突然增大超过阈值（相对变化超过50%或绝对值变化超过100）
    final absDiff = (rawCo - lastValue).abs();
    final relativeDiff = lastValue > 0 ? (absDiff / lastValue) : 0;
    
    // 突变阈值：绝对值变化超过100 或 相对变化超过50%
    final isSpike = absDiff > 100 || (relativeDiff > 0.5 && absDiff > 50);
    
    if (isSpike && rawCo > lastValue) {
      // 检测到向上突变，检查是否超过固定范围
      // 固定范围：500ppm（具体数值范围）
      final fixedRange = 500.0; // 固定范围：500ppm
      final spikeAbsValue = rawCo.abs();
      final previousAbsValue = lastValue.abs();
      
      // 如果突变值的绝对值超过异常值前的数值绝对值的固定范围，使用异常前的值
      if (spikeAbsValue > previousAbsValue + fixedRange) {
        print('CO突变值超过固定范围: 节点=$nodeId, 突变值=$rawCo, 异常前值=$lastValue, 固定范围=$fixedRange, 使用异常前值');
        // 不创建突变状态，直接使用异常前的值
        history.add(CoHistoryEntry(lastValue, timestamp));
        return lastValue;
      }
      
      // 检测到向上突变，开始观察
      print('CO突变检测: 节点=$nodeId, 检测到突变: 从$lastValue到$rawCo (变化: ${(relativeDiff * 100).toStringAsFixed(1)}%)');
      
      // 创建突变状态并开始观察
      _coSpikeStates[nodeId] = CoSpikeState(
        spikeValue: rawCo,
        spikeTimestamp: timestamp,
        previousValue: lastValue,
      );
      
      // 暂时使用之前的正常值，等待观察期结束再决定
      return lastValue;
    }
    
    // 8. 正常变化（非突变），直接使用当前值
    history.add(CoHistoryEntry(rawCo, timestamp));
    
    // 限制历史记录长度（最多保留20个）
    if (history.length > 20) {
      history.removeAt(0);
    }
    
    return rawCo;
  }

  // 温度值时间窗口过滤方法
  // 使用时间窗口检测区分真实预警和传感器故障
  double _filterTempValueWithTimeWindow(int nodeId, int channelIndex, double rawTemp, int timestamp) {
    // 1. 基本范围检查：温度值超出合理范围（-50°C以下）认为无效（去掉上限）
    if (rawTemp < -50) {
      print('温度基本范围检查: 节点=$nodeId, 通道=$channelIndex, 原始值=$rawTemp超出范围[-50, +∞]');
      // 如果有历史值，返回最近的有效值
      final historyKey = '${nodeId}_$channelIndex';
      final history = _tempHistory[historyKey];
      if (history != null && history.isNotEmpty) {
        final lastValidValue = history.last.value;
        print('温度使用历史值: 节点=$nodeId, 通道=$channelIndex, 使用最近有效值=$lastValidValue°C');
        return lastValidValue;
      }
      // 没有历史值，返回25°C（默认值）
      return 25.0;
    }
    
    // 2. 获取历史记录
    final historyKey = '${nodeId}_$channelIndex';
    final history = _tempHistory.putIfAbsent(historyKey, () => <TempHistoryEntry>[]);
    
    // 3. 清理过期历史记录（只保留最近3秒的数据）
    final expireTime = timestamp - 3000; // 3秒
    history.removeWhere((entry) => entry.timestamp < expireTime);
    
    // 4. 如果没有历史数据，直接使用当前值并记录
    if (history.isEmpty) {
      history.add(TempHistoryEntry(rawTemp, timestamp));
      return rawTemp;
    }
    
    // 5. 获取最近的有效值
    final lastEntry = history.last;
    final lastValue = lastEntry.value;
    
    // 6. 检查是否存在正在观察的突变状态
    final spikeState = _tempSpikeStates[historyKey];
    
    if (spikeState != null) {
      // 正在观察一个突变状态
      
      // 检查突变值是否超过固定范围（具体数值范围）
      // 固定范围：±10°C（具体数值范围）
      final fixedRange = 10.0; // 固定范围：±10°C
      final previousValue = spikeState.previousValue;
      
      // 如果当前突变值超过异常值前的数值的±10°C范围，使用异常前的值
      if (rawTemp > previousValue + fixedRange || rawTemp < previousValue - fixedRange) {
        print('温度观察期内突变值超过固定范围: 节点=$nodeId, 通道=$channelIndex, 当前值=$rawTemp, 异常前值=$previousValue, 固定范围=±$fixedRange°C, 使用异常前值');
        // 清除突变状态
        _tempSpikeStates.remove(historyKey);
        // 使用异常前的值
        history.add(TempHistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查是否是传感器故障（突变后很快恢复）
      if (spikeState.isSensorFault(rawTemp, timestamp)) {
        print('温度传感器故障检测: 节点=$nodeId, 通道=$channelIndex, 突变值=${spikeState.spikeValue}, 当前值=$rawTemp, 已恢复到${spikeState.previousValue}附近，判定为传感器故障');
        // 清除突变状态
        _tempSpikeStates.remove(historyKey);
        // 使用之前的正常值
        history.add(TempHistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查突变是否稳定（在1-2秒内保持在一定范围内）
      if (spikeState.isStableSpike(rawTemp, timestamp)) {
        print('温度稳定突变检测: 节点=$nodeId, 通道=$channelIndex, 突变值=${spikeState.spikeValue}在观察期内保持稳定，判定为真实预警/故障');
        // 清除突变状态，确认是真实的值
        _tempSpikeStates.remove(historyKey);
        // 使用突变后的值（真实预警/故障）
        history.add(TempHistoryEntry(rawTemp, timestamp));
        return rawTemp;
      }
      
      // 还在观察期内，继续收集数据
      spikeState.spikeWindow.add(rawTemp);
      // 暂时使用之前的正常值，等待观察期结束
      return spikeState.previousValue;
    }
    
    // 7. 检测是否发生突变
    // 突变定义为：值突然变化超过阈值（正负10°C）
    final absDiff = (rawTemp - lastValue).abs();
    
    // 突变阈值：绝对值变化超过10°C
    final isSpike = absDiff > 10.0;
    
    if (isSpike) {
      // 检测到突变（向上或向下），检查是否超过固定范围
      // 固定范围：±10°C（具体数值范围）
      final fixedRange = 10.0; // 固定范围：±10°C
      
      // 如果突变值超过异常值前的数值的±10°C范围，使用异常前的值
      if (rawTemp > lastValue + fixedRange || rawTemp < lastValue - fixedRange) {
        print('温度突变值超过固定范围: 节点=$nodeId, 通道=$channelIndex, 突变值=$rawTemp, 异常前值=$lastValue, 固定范围=±$fixedRange°C, 使用异常前值');
        // 不创建突变状态，直接使用异常前的值
        history.add(TempHistoryEntry(lastValue, timestamp));
        return lastValue;
      }
      
      // 检测到突变（向上或向下），开始观察
      print('温度突变检测: 节点=$nodeId, 通道=$channelIndex, 检测到突变: 从$lastValue到$rawTemp (变化=${absDiff.toStringAsFixed(1)}°C)');
      
      // 创建突变状态并开始观察
      _tempSpikeStates[historyKey] = TempSpikeState(
        spikeValue: rawTemp,
        spikeTimestamp: timestamp,
        previousValue: lastValue,
      );
      
      // 暂时使用之前的正常值，等待观察期结束再决定
      return lastValue;
    }
    
    // 8. 正常变化（非突变），直接使用当前值
    history.add(TempHistoryEntry(rawTemp, timestamp));
    
    // 限制历史记录长度（最多保留20个）
    if (history.length > 20) {
      history.removeAt(0);
    }
    
    return rawTemp;
  }

  // 压力值时间窗口过滤方法
  // 使用时间窗口检测区分真实预警和传感器故障
  double _filterPressureValueWithTimeWindow(int nodeId, double rawPressure, int timestamp) {
    // 1. 基本范围检查：压力值超出合理范围（0-1000kPa）认为无效
    if (rawPressure < 0 || rawPressure > 1000) {
      print('压力基本范围检查: 节点=$nodeId, 原始值=$rawPressure超出范围[0, 1000]');
      // 如果有历史值，返回最近的有效值
      final history = _pressureHistory[nodeId];
      if (history != null && history.isNotEmpty) {
        final lastValidValue = history.last.value;
        print('压力使用历史值: 节点=$nodeId, 使用最近有效值=$lastValidValue kPa');
        return lastValidValue;
      }
      // 没有历史值，返回100kPa（默认值）
      return 100.0;
    }
    
    // 2. 获取历史记录
    final history = _pressureHistory.putIfAbsent(nodeId, () => <PressureHistoryEntry>[]);
    
    // 3. 清理过期历史记录（只保留最近3秒的数据）
    final expireTime = timestamp - 3000; // 3秒
    history.removeWhere((entry) => entry.timestamp < expireTime);
    
    // 4. 如果没有历史数据，直接使用当前值并记录
    if (history.isEmpty) {
      history.add(PressureHistoryEntry(rawPressure, timestamp));
      return rawPressure;
    }
    
    // 5. 获取最近的有效值
    final lastEntry = history.last;
    final lastValue = lastEntry.value;
    
    // 6. 检查是否存在正在观察的突变状态
    final spikeState = _pressureSpikeStates[nodeId];
    
    if (spikeState != null) {
      // 正在观察一个突变状态
      
      // 检查突变值是否超过固定范围（具体数值范围）
      // 固定范围：100kPa（具体数值范围）
      final fixedRange = 100.0; // 固定范围：100kPa
      final spikeAbsValue = rawPressure.abs();
      final previousAbsValue = spikeState.previousValue.abs();
      
      // 如果当前突变值的绝对值超过异常值前的数值绝对值的固定范围，使用异常前的值
      if (spikeAbsValue > previousAbsValue + fixedRange) {
        print('压力观察期内突变值超过固定范围: 节点=$nodeId, 当前值=$rawPressure, 异常前值=${spikeState.previousValue}, 固定范围=$fixedRange, 使用异常前值');
        // 清除突变状态
        _pressureSpikeStates.remove(nodeId);
        // 使用异常前的值
        history.add(PressureHistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查是否是传感器故障（突变后很快恢复）
      if (spikeState.isSensorFault(rawPressure, timestamp)) {
        print('压力传感器故障检测: 节点=$nodeId, 突变值=${spikeState.spikeValue}, 当前值=$rawPressure, 已恢复到${spikeState.previousValue}附近，判定为传感器故障');
        // 清除突变状态
        _pressureSpikeStates.remove(nodeId);
        // 使用之前的正常值
        history.add(PressureHistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查突变是否稳定（在1-2秒内保持在一定范围内）
      if (spikeState.isStableSpike(rawPressure, timestamp)) {
        print('压力稳定突变检测: 节点=$nodeId, 突变值=${spikeState.spikeValue}在观察期内保持稳定，判定为真实预警/故障');
        // 清除突变状态，确认是真实的值
        _pressureSpikeStates.remove(nodeId);
        // 使用突变后的值（真实预警/故障）
        history.add(PressureHistoryEntry(rawPressure, timestamp));
        return rawPressure;
      }
      
      // 还在观察期内，继续收集数据
      spikeState.spikeWindow.add(rawPressure);
      // 暂时使用之前的正常值，等待观察期结束
      return spikeState.previousValue;
    }
    
    // 7. 检测是否发生突变
    // 突变定义为：值突然增大超过阈值（相对变化超过50%或绝对值变化超过20kPa）
    final absDiff = (rawPressure - lastValue).abs();
    final relativeDiff = lastValue.abs() > 0.1 ? (absDiff / lastValue.abs()) : 0;
    
    // 突变阈值：绝对值变化超过20kPa 或 相对变化超过50%
    final isSpike = absDiff > 20.0 || (relativeDiff > 0.5 && absDiff > 10.0);
    
    if (isSpike && rawPressure > lastValue) {
      // 检测到向上突变，检查是否超过固定范围
      // 固定范围：100kPa（具体数值范围）
      final fixedRange = 100.0; // 固定范围：100kPa
      final spikeAbsValue = rawPressure.abs();
      final previousAbsValue = lastValue.abs();
      
      // 如果突变值的绝对值超过异常值前的数值绝对值的固定范围，使用异常前的值
      if (spikeAbsValue > previousAbsValue + fixedRange) {
        print('压力突变值超过固定范围: 节点=$nodeId, 突变值=$rawPressure, 异常前值=$lastValue, 固定范围=$fixedRange, 使用异常前值');
        // 不创建突变状态，直接使用异常前的值
        history.add(PressureHistoryEntry(lastValue, timestamp));
        return lastValue;
      }
      
      // 检测到向上突变，开始观察
      print('压力突变检测: 节点=$nodeId, 检测到突变: 从$lastValue到$rawPressure (变化: ${(relativeDiff * 100).toStringAsFixed(1)}%)');
      
      // 创建突变状态并开始观察
      _pressureSpikeStates[nodeId] = TempSpikeState(
        spikeValue: rawPressure,
        spikeTimestamp: timestamp,
        previousValue: lastValue,
      );
      
      // 暂时使用之前的正常值，等待观察期结束再决定
      return lastValue;
    }
    
    // 8. 正常变化（非突变），直接使用当前值
    history.add(PressureHistoryEntry(rawPressure, timestamp));
    
    // 限制历史记录长度（最多保留20个）
    if (history.length > 20) {
      history.removeAt(0);
    }
    
    return rawPressure;
  }

  // 氢气值时间窗口过滤方法
  // 使用时间窗口检测区分真实预警和传感器故障
  double _filterH2ValueWithTimeWindow(int nodeId, double rawH2, int timestamp) {
    // 1. 基本范围检查：氢气值超出合理范围（0-100%LEL）认为无效
    if (rawH2 < 0 || rawH2 > 100) {
      print('氢气基本范围检查: 节点=$nodeId, 原始值=$rawH2超出范围[0, 100]');
      // 如果有历史值，返回最近的有效值
      final history = _h2History[nodeId];
      if (history != null && history.isNotEmpty) {
        final lastValidValue = history.last.value;
        print('氢气使用历史值: 节点=$nodeId, 使用最近有效值=$lastValidValue %LEL');
        return lastValidValue;
      }
      // 没有历史值，返回0
      return 0.0;
    }
    
    // 2. 获取历史记录
    final history = _h2History.putIfAbsent(nodeId, () => <H2HistoryEntry>[]);
    
    // 3. 清理过期历史记录（只保留最近3秒的数据）
    final expireTime = timestamp - 3000; // 3秒
    history.removeWhere((entry) => entry.timestamp < expireTime);
    
    // 4. 如果没有历史数据，直接使用当前值并记录
    if (history.isEmpty) {
      history.add(H2HistoryEntry(rawH2, timestamp));
      return rawH2;
    }
    
    // 5. 获取最近的有效值
    final lastEntry = history.last;
    final lastValue = lastEntry.value;
    
    // 6. 检查是否存在正在观察的突变状态
    final spikeState = _h2SpikeStates[nodeId];
    
    if (spikeState != null) {
      // 正在观察一个突变状态
      
      // 检查突变值是否超过固定范围（具体数值范围）
      // 固定范围：10%LEL（具体数值范围）
      final fixedRange = 10.0; // 固定范围：10%LEL
      final spikeAbsValue = rawH2.abs();
      final previousAbsValue = spikeState.previousValue.abs();
      
      // 如果当前突变值的绝对值超过异常值前的数值绝对值的固定范围，使用异常前的值
      if (spikeAbsValue > previousAbsValue + fixedRange) {
        print('氢气观察期内突变值超过固定范围: 节点=$nodeId, 当前值=$rawH2, 异常前值=${spikeState.previousValue}, 固定范围=$fixedRange, 使用异常前值');
        // 清除突变状态
        _h2SpikeStates.remove(nodeId);
        // 使用异常前的值
        history.add(H2HistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查是否是传感器故障（突变后很快恢复）
      if (spikeState.isSensorFault(rawH2, timestamp)) {
        print('氢气传感器故障检测: 节点=$nodeId, 突变值=${spikeState.spikeValue}, 当前值=$rawH2, 已恢复到${spikeState.previousValue}附近，判定为传感器故障');
        // 清除突变状态
        _h2SpikeStates.remove(nodeId);
        // 使用之前的正常值
        history.add(H2HistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查突变是否稳定（在1-2秒内保持在一定范围内）
      if (spikeState.isStableSpike(rawH2, timestamp)) {
        print('氢气稳定突变检测: 节点=$nodeId, 突变值=${spikeState.spikeValue}在观察期内保持稳定，判定为真实预警/故障');
        // 清除突变状态，确认是真实的值
        _h2SpikeStates.remove(nodeId);
        // 使用突变后的值（真实预警/故障）
        history.add(H2HistoryEntry(rawH2, timestamp));
        return rawH2;
      }
      
      // 还在观察期内，继续收集数据
      spikeState.spikeWindow.add(rawH2);
      // 暂时使用之前的正常值，等待观察期结束
      return spikeState.previousValue;
    }
    
    // 7. 检测是否发生突变
    // 突变定义为：值突然增大超过阈值（相对变化超过50%或绝对值变化超过2%LEL）
    final absDiff = (rawH2 - lastValue).abs();
    final relativeDiff = lastValue.abs() > 0.1 ? (absDiff / lastValue.abs()) : 0;
    
    // 突变阈值：绝对值变化超过2%LEL 或 相对变化超过50%
    final isSpike = absDiff > 2.0 || (relativeDiff > 0.5 && absDiff > 1.0);
    
    if (isSpike && rawH2 > lastValue) {
      // 检测到向上突变，检查是否超过固定范围
      // 固定范围：10%LEL（具体数值范围）
      final fixedRange = 10.0; // 固定范围：10%LEL
      final spikeAbsValue = rawH2.abs();
      final previousAbsValue = lastValue.abs();
      
      // 如果突变值的绝对值超过异常值前的数值绝对值的固定范围，使用异常前的值
      if (spikeAbsValue > previousAbsValue + fixedRange) {
        print('氢气突变值超过固定范围: 节点=$nodeId, 突变值=$rawH2, 异常前值=$lastValue, 固定范围=$fixedRange, 使用异常前值');
        // 不创建突变状态，直接使用异常前的值
        history.add(H2HistoryEntry(lastValue, timestamp));
        return lastValue;
      }
      
      // 检测到向上突变，开始观察
      print('氢气突变检测: 节点=$nodeId, 检测到突变: 从$lastValue到$rawH2 (变化: ${(relativeDiff * 100).toStringAsFixed(1)}%)');
      
      // 创建突变状态并开始观察
      _h2SpikeStates[nodeId] = TempSpikeState(
        spikeValue: rawH2,
        spikeTimestamp: timestamp,
        previousValue: lastValue,
      );
      
      // 暂时使用之前的正常值，等待观察期结束再决定
      return lastValue;
    }
    
    // 8. 正常变化（非突变），直接使用当前值
    history.add(H2HistoryEntry(rawH2, timestamp));
    
    // 限制历史记录长度（最多保留20个）
    if (history.length > 20) {
      history.removeAt(0);
    }
    
    return rawH2;
  }

  // 烟雾值时间窗口过滤方法
  // 使用时间窗口检测区分真实预警和传感器故障
  int _filterSmokeValueWithTimeWindow(int nodeId, String channel, int rawSmoke, int timestamp) {
    // 1. 基本范围检查：烟雾值超出合理范围（0-65535）认为无效
    if (rawSmoke < 0 || rawSmoke > 65535) {
      print('烟雾基本范围检查: 节点=$nodeId, 通道=$channel, 原始值=$rawSmoke超出范围[0, 65535]');
      // 如果有历史值，返回最近的有效值
      final historyKey = '${nodeId}_channel$channel';
      final history = _smokeHistory[historyKey];
      if (history != null && history.isNotEmpty) {
        final lastValidValue = history.last.value;
        print('烟雾使用历史值: 节点=$nodeId, 通道=$channel, 使用最近有效值=$lastValidValue');
        return lastValidValue;
      }
      // 没有历史值，返回0
      return 0;
    }
    
    // 2. 获取历史记录
    final historyKey = '${nodeId}_channel$channel';
    final history = _smokeHistory.putIfAbsent(historyKey, () => <SmokeHistoryEntry>[]);
    
    // 3. 清理过期历史记录（只保留最近3秒的数据）
    final expireTime = timestamp - 3000; // 3秒
    history.removeWhere((entry) => entry.timestamp < expireTime);
    
    // 4. 如果没有历史数据，直接使用当前值并记录
    if (history.isEmpty) {
      history.add(SmokeHistoryEntry(rawSmoke, timestamp));
      return rawSmoke;
    }
    
    // 5. 获取最近的有效值
    final lastEntry = history.last;
    final lastValue = lastEntry.value;
    
    // 6. 检查是否存在正在观察的突变状态
    final spikeState = _smokeSpikeStates[historyKey];
    
    if (spikeState != null) {
      // 正在观察一个突变状态
      
      // 检查突变值是否超过固定范围（具体数值范围）
      // 固定范围：1000（具体数值范围）
      final fixedRange = 1000.0; // 固定范围：1000
      final spikeAbsValue = rawSmoke.abs();
      final previousAbsValue = spikeState.previousValue.abs();
      
      // 如果当前突变值的绝对值超过异常值前的数值绝对值的固定范围，使用异常前的值
      if (spikeAbsValue > previousAbsValue + fixedRange) {
        print('烟雾观察期内突变值超过固定范围: 节点=$nodeId, 通道=$channel, 当前值=$rawSmoke, 异常前值=${spikeState.previousValue}, 固定范围=$fixedRange, 使用异常前值');
        // 清除突变状态
        _smokeSpikeStates.remove(historyKey);
        // 使用异常前的值
        history.add(SmokeHistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查是否是传感器故障（突变后很快恢复）
      if (spikeState.isSensorFault(rawSmoke, timestamp)) {
        print('烟雾传感器故障检测: 节点=$nodeId, 通道=$channel, 突变值=${spikeState.spikeValue}, 当前值=$rawSmoke, 已恢复到${spikeState.previousValue}附近，判定为传感器故障');
        // 清除突变状态
        _smokeSpikeStates.remove(historyKey);
        // 使用之前的正常值
        history.add(SmokeHistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查突变是否稳定（在1-2秒内保持在一定范围内）
      if (spikeState.isStableSpike(rawSmoke, timestamp)) {
        print('烟雾稳定突变检测: 节点=$nodeId, 通道=$channel, 突变值=${spikeState.spikeValue}在观察期内保持稳定，判定为真实预警/故障');
        // 清除突变状态，确认是真实的值
        _smokeSpikeStates.remove(historyKey);
        // 使用突变后的值（真实预警/故障）
        history.add(SmokeHistoryEntry(rawSmoke, timestamp));
        return rawSmoke;
      }
      
      // 还在观察期内，继续收集数据
      spikeState.spikeWindow.add(rawSmoke);
      // 暂时使用之前的正常值，等待观察期结束
      return spikeState.previousValue;
    }
    
    // 7. 检测是否发生突变
    // 突变定义为：值突然增大超过阈值（相对变化超过50%或绝对值变化超过500）
    final absDiff = (rawSmoke - lastValue).abs();
    final relativeDiff = lastValue > 0 ? (absDiff / lastValue) : 0;
    
    // 突变阈值：绝对值变化超过500 或 相对变化超过50%
    final isSpike = absDiff > 500 || (relativeDiff > 0.5 && absDiff > 200);
    
    if (isSpike && rawSmoke > lastValue) {
      // 检测到向上突变，检查是否超过固定范围
      // 固定范围：1000（具体数值范围）
      final fixedRange = 1000.0; // 固定范围：1000
      final spikeAbsValue = rawSmoke.abs();
      final previousAbsValue = lastValue.abs();
      
      // 如果突变值的绝对值超过异常值前的数值绝对值的固定范围，使用异常前的值
      if (spikeAbsValue > previousAbsValue + fixedRange) {
        print('烟雾突变值超过固定范围: 节点=$nodeId, 通道=$channel, 突变值=$rawSmoke, 异常前值=$lastValue, 固定范围=$fixedRange, 使用异常前值');
        // 不创建突变状态，直接使用异常前的值
        history.add(SmokeHistoryEntry(lastValue, timestamp));
        return lastValue;
      }
      
      // 检测到向上突变，开始观察
      print('烟雾突变检测: 节点=$nodeId, 通道=$channel, 检测到突变: 从$lastValue到$rawSmoke (变化: ${(relativeDiff * 100).toStringAsFixed(1)}%)');
      
      // 创建突变状态并开始观察
      _smokeSpikeStates[historyKey] = CoSpikeState(
        spikeValue: rawSmoke,
        spikeTimestamp: timestamp,
        previousValue: lastValue,
      );
      
      // 暂时使用之前的正常值，等待观察期结束再决定
      return lastValue;
    }
    
    // 8. 正常变化（非突变），直接使用当前值
    history.add(SmokeHistoryEntry(rawSmoke, timestamp));
    
    // 限制历史记录长度（最多保留20个）
    if (history.length > 20) {
      history.removeAt(0);
    }
    
    return rawSmoke;
  }

  // 湿度值时间窗口过滤方法
  // 使用时间窗口检测区分真实预警和传感器故障
  double _filterHumidityValueWithTimeWindow(int nodeId, double rawHumidity, int timestamp) {
    // 1. 基本范围检查：湿度值超出合理范围（0-100%）认为无效
    if (rawHumidity < 0 || rawHumidity > 100) {
      print('湿度基本范围检查: 节点=$nodeId, 原始值=$rawHumidity超出范围[0, 100]');
      // 如果有历史值，返回最近的有效值
      final history = _humidityHistory[nodeId];
      if (history != null && history.isNotEmpty) {
        final lastValidValue = history.last.value;
        print('湿度使用历史值: 节点=$nodeId, 使用最近有效值=$lastValidValue%');
        return lastValidValue;
      }
      // 没有历史值，返回50%（默认值）
      return 50.0;
    }
    
    // 2. 获取历史记录
    final history = _humidityHistory.putIfAbsent(nodeId, () => <HumidityHistoryEntry>[]);
    
    // 3. 清理过期历史记录（只保留最近3秒的数据）
    final expireTime = timestamp - 3000; // 3秒
    history.removeWhere((entry) => entry.timestamp < expireTime);
    
    // 4. 如果没有历史数据，直接使用当前值并记录
    if (history.isEmpty) {
      history.add(HumidityHistoryEntry(rawHumidity, timestamp));
      return rawHumidity;
    }
    
    // 5. 获取最近的有效值
    final lastEntry = history.last;
    final lastValue = lastEntry.value;
    
    // 6. 检查是否存在正在观察的突变状态
    final spikeState = _humiditySpikeStates[nodeId];
    
    if (spikeState != null) {
      // 正在观察一个突变状态
      
      // 检查突变值是否超过固定范围（具体数值范围）
      // 固定范围：±20%（具体数值范围）
      final fixedRange = 20.0; // 固定范围：±20%
      final previousValue = spikeState.previousValue;
      
      // 如果当前突变值超过异常值前的数值的±20%范围，使用异常前的值
      if (rawHumidity > previousValue + fixedRange || rawHumidity < previousValue - fixedRange) {
        print('湿度观察期内突变值超过固定范围: 节点=$nodeId, 当前值=$rawHumidity, 异常前值=$previousValue, 固定范围=±$fixedRange%, 使用异常前值');
        // 清除突变状态
        _humiditySpikeStates.remove(nodeId);
        // 使用异常前的值
        history.add(HumidityHistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查是否是传感器故障（突变后很快恢复）
      if (spikeState.isSensorFault(rawHumidity, timestamp)) {
        print('湿度传感器故障检测: 节点=$nodeId, 突变值=${spikeState.spikeValue}, 当前值=$rawHumidity, 已恢复到${spikeState.previousValue}附近，判定为传感器故障');
        // 清除突变状态
        _humiditySpikeStates.remove(nodeId);
        // 使用之前的正常值
        history.add(HumidityHistoryEntry(spikeState.previousValue, timestamp));
        return spikeState.previousValue;
      }
      
      // 检查突变是否稳定（在1-2秒内保持在一定范围内）
      if (spikeState.isStableSpike(rawHumidity, timestamp)) {
        print('湿度稳定突变检测: 节点=$nodeId, 突变值=${spikeState.spikeValue}在观察期内保持稳定，判定为真实预警/故障');
        // 清除突变状态，确认是真实的值
        _humiditySpikeStates.remove(nodeId);
        // 使用突变后的值（真实预警/故障）
        history.add(HumidityHistoryEntry(rawHumidity, timestamp));
        return rawHumidity;
      }
      
      // 还在观察期内，继续收集数据
      spikeState.spikeWindow.add(rawHumidity);
      // 暂时使用之前的正常值，等待观察期结束
      return spikeState.previousValue;
    }
    
    // 7. 检测是否发生突变
    // 突变定义为：值突然增大超过阈值（相对变化超过50%或绝对值变化超过10%）
    final absDiff = (rawHumidity - lastValue).abs();
    final relativeDiff = lastValue.abs() > 0.1 ? (absDiff / lastValue.abs()) : 0;
    
    // 突变阈值：绝对值变化超过10% 或 相对变化超过50%
    final isSpike = absDiff > 10.0 || (relativeDiff > 0.5 && absDiff > 5.0);
    
    if (isSpike && rawHumidity > lastValue) {
      // 检测到向上突变，检查是否超过固定范围
      // 固定范围：±20%（具体数值范围）
      final fixedRange = 20.0; // 固定范围：±20%
      
      // 如果突变值超过异常值前的数值的±20%范围，使用异常前的值
      if (rawHumidity > lastValue + fixedRange || rawHumidity < lastValue - fixedRange) {
        print('湿度突变值超过固定范围: 节点=$nodeId, 突变值=$rawHumidity, 异常前值=$lastValue, 固定范围=±$fixedRange%, 使用异常前值');
        // 不创建突变状态，直接使用异常前的值
        history.add(HumidityHistoryEntry(lastValue, timestamp));
        return lastValue;
      }
      
      // 检测到向上突变，开始观察
      print('湿度突变检测: 节点=$nodeId, 检测到突变: 从$lastValue到$rawHumidity (变化: ${(relativeDiff * 100).toStringAsFixed(1)}%)');
      
      // 创建突变状态并开始观察
      _humiditySpikeStates[nodeId] = TempSpikeState(
        spikeValue: rawHumidity,
        spikeTimestamp: timestamp,
        previousValue: lastValue,
      );
      
      // 暂时使用之前的正常值，等待观察期结束再决定
      return lastValue;
    }
    
    // 8. 正常变化（非突变），直接使用当前值
    history.add(HumidityHistoryEntry(rawHumidity, timestamp));
    
    // 限制历史记录长度（最多保留20个）
    if (history.length > 20) {
      history.removeAt(0);
    }
    
    return rawHumidity;
  }

  // 发送实时信息到远端服务器（03类型报文）（已废弃，不再主动发送）
  void _sendRealtimeDataToServer(int nodeId) {
    // 不再主动发送实时数据，等待客户端请求
    print('实时数据已准备: 节点$nodeId (不再主动发送)');
    return;
    // if (!_modbusClient.isServerConnected) {
    //   print('⚠️ Modbus TCP服务器未连接，跳过实时信息发送');
    //   return;
    // }
    
    // 获取节点最新快照
    final snapshot = CsvLoggerService.instance.getNodeSnapshot(nodeId);
    if (snapshot == null) {
      print('⚠️ 节点$nodeId快照不存在，跳过实时信息发送');
      return;
    }
    
    final timestamp = DateTime.now().toIso8601String();
    final sensorDataMap = snapshot.toMap();
    
    print('📤 发送实时信息（03类型）到远端服务器: 节点$nodeId');
    print('📊 实时数据包含字段: ${sensorDataMap.keys.join(', ')}');
    
    // 不再主动发送实时数据，等待客户端请求
    print('实时数据已准备: 节点$nodeId (不再主动发送)');
    // _modbusClient.sendRealtimeData(
    //   nodeId: nodeId,
    //   sensorData: sensorDataMap,
    //   timestamp: timestamp,
    // );
  }

  // 发送处理后的数据（485格式）到远端服务器（已废弃，不再主动发送）
  // 使用与节点详细页面相同的修正逻辑
  Future<void> _sendProcessedDataRS485(int nodeId) async {
    // 不再主动发送数据，等待客户端请求
    print('处理后数据已准备: 节点$nodeId (不再主动发送)');
    return;
    // 以下代码已废弃，不再主动发送数据，全部注释掉
    /*
    try {
      if (!_modbusServer.isRunning) {
        return;
      }
      
      // 获取节点最新快照
      final snapshot = CsvLoggerService.instance.getNodeSnapshot(nodeId);
      if (snapshot == null) {
        return;
      }
      
      // 获取节点设置（修正值）
      final settingsService = SettingsService();
      final nodeSettings = await settingsService.getAllSettingsForNode(nodeId);
      
      // 手动实现自然对数（用于烟雾计算）
      double _naturalLog(double x) {
        if (x <= 0) return 0;
        double result = 0.0;
        double term = (x - 1) / (x + 1);
        double termSquared = term * term;
        for (int i = 0; i < 100; i++) {
          result += term / (2 * i + 1);
          term *= termSquared;
        }
        return 2 * result;
      }
      
      // 计算烟雾浓度（与页面显示一致）
      double _calculateSmokeConcentration(double xStar, double a, double T) {
        final tSafe = (T == 0) ? 568.0 : T;
        final delta = xStar - a;
        if (delta <= 0) return 0.0;
        final x0 = 568.0 * (delta / tSafe);
        double m;
        if (x0 < 568.0) {
          m = -0.00000015 * x0 * x0 + 0.0007 * x0;
        } else {
          final lnX0 = _naturalLog(x0);
          m = 0.2772 * lnX0 - 1.408;
        }
        return m < 0 ? 0 : m;
      }
      
      // 获取修正值
      final upperCorr = nodeSettings['upperTempCorrection'] as double? ?? 0.0;
      final middleCorr = nodeSettings['envTempCorrection'] as double? ?? 0.0;
      final lowerCorr = nodeSettings['lowerTempCorrection'] as double? ?? 0.0;
      final humidityCorr = nodeSettings['humidityCorrection'] as double? ?? 0.0;
      
      // 计算上中下温度（与页面显示一致）
      double upperTemp = (snapshot.temperature ?? 25) + upperCorr;
      double middleTemp = (snapshot.temperature ?? 25) + middleCorr;
      double lowerTemp = (snapshot.temperature ?? 25) + lowerCorr;
      
      // 计算防爆盒内环境参数
      double correctedHumidity = (snapshot.humidity ?? 0) + humidityCorr;
      correctedHumidity = correctedHumidity.clamp(0, 100);
      final pressure = snapshot.pressureKpa ?? 0;
      final h2Concentration = snapshot.h2Percentage ?? 0;
      final rawCo = snapshot.coPpm?.toDouble() ?? 0;
      final coConcentration = (rawCo < 0 || rawCo > 10000) ? 0 : rawCo;
      double whiteSmoke = 0.1;
      double blackSmoke = 0.1;
      // smokeRatio 不在快照中，使用默认值0或从其他数据计算
      final smokeRatio = 0; // 快照中没有此字段，使用默认值
      final smokeExternalTemp = snapshot.smokeExternalTempC ?? 0;
      
      // 计算白烟和黑烟浓度
      if (snapshot.smokeChannelA != null) {
        final aA = (snapshot.smokeCalibA ?? 0).toDouble();
        final tA = (snapshot.smokeThreshA ?? 568).toDouble();
        whiteSmoke = _calculateSmokeConcentration(snapshot.smokeChannelA!.toDouble(), aA, tA);
      }
      if (snapshot.smokeChannelB != null) {
        final aB = (snapshot.smokeCalibB ?? 0).toDouble();
        final tB = (snapshot.smokeThreshB ?? 568).toDouble();
        blackSmoke = _calculateSmokeConcentration(snapshot.smokeChannelB!.toDouble(), aB, tB);
      }
      
      // ========== 第一部分：电缆接头测点温度（PT100数据） ==========
      if (snapshot.pt100Temperatures != null) {
        try {
          final temps = jsonDecode(snapshot.pt100Temperatures!) as List;
          if (temps.length < 9) {
            print('PT100数据不足9个通道');
            return;
          }
          
          final pt100Corrections = nodeSettings['pt100Corrections'] as List<dynamic>? ?? List.filled(10, 0.0);
          
          // 应用误差修正：开路(-999)保持不变，否则加上修正值
          final corrected = List<double>.generate(
            temps.length,
            (i) {
              final base = temps[i] as double;
              if (base == -999) return -999;
              final delta = i < pt100Corrections.length ? (pt100Corrections[i] as double? ?? 0.0) : 0.0;
              return base + delta;
            },
          );
          
          // 更新上中下温度（如果有PT100数据）
          // 上温度：节点1使用通道10，其他节点使用通道9
          if (nodeId == 1 && corrected.length >= 11) {
            upperTemp = corrected[10] + upperCorr;
          } else if (corrected.length >= 10) {
            upperTemp = corrected[9] + upperCorr;
          }
          
          // 中温度：通道11
          if (corrected.length >= 12 && corrected[11] != -999) {
            middleTemp = corrected[11] + middleCorr;
          }
          
          // A相：ch0,ch1,ch2 -> 左外,中外,右外
          final aL = corrected[0];
          final aM = corrected[1];
          final aR = corrected[2];
          
          // B相：ch3,ch4,ch5 -> 左外,中外,右外
          final bL = corrected[3];
          final bM = corrected[4];
          final bR = corrected[5];
          
          // C相：ch6,ch7,ch8 -> 左外,中外,右外
          final cL = corrected[6];
          final cM = corrected[7];
          final cR = corrected[8];
          
          // 计算三相平均值（sensor_flutter5使用中外温度平均值作为xia）
          final middleAvg = (aM + bM + cM) / 3; // 中外温度平均值
          
          // 获取k1、k2参数
          final aK1 = nodeSettings['aK1'] as double? ?? 6.42;
          final aK2 = nodeSettings['aK2'] as double? ?? 2.5;
          final bK1 = nodeSettings['bK1'] as double? ?? 6.42;
          final bK2 = nodeSettings['bK2'] as double? ?? 2.5;
          final cK1 = nodeSettings['cK1'] as double? ?? 6.42;
          final cK2 = nodeSettings['cK2'] as double? ?? 2.5;
          
          // 计算内温度：Y = xi + k1·max(0, xi – x0i) + k2·max(0, xi – xia)
          double _calculateInnerTemp(double xi, double x0i, double xia, double k1, double k2) {
            if (xi == -999) return -999;
            if (xi < x0i) return xi;
            final deltaEnv = (xi - x0i) < 0 ? 0 : (xi - x0i);
            final deltaPhaseAvg = (xi - xia) < 0 ? 0 : (xi - xia);
            return xi + k1 * deltaEnv + k2 * deltaPhaseAvg;
          }
          
          // A相内温度（环境温度为上温度，使用中外温度平均值）
          final aLInner = _calculateInnerTemp(aL, upperTemp, middleAvg, aK1, aK2);
          final aMInner = _calculateInnerTemp(aM, upperTemp, middleAvg, aK1, aK2);
          final aRInner = _calculateInnerTemp(aR, upperTemp, middleAvg, aK1, aK2);
          
          // B相内温度（环境温度为中温度，使用中外温度平均值）
          final bLInner = _calculateInnerTemp(bL, middleTemp, middleAvg, bK1, bK2);
          final bMInner = _calculateInnerTemp(bM, middleTemp, middleAvg, bK1, bK2);
          final bRInner = _calculateInnerTemp(bR, middleTemp, middleAvg, bK1, bK2);
          
          // C相内温度（环境温度为下温度，使用中外温度平均值）
          final cLInner = _calculateInnerTemp(cL, lowerTemp, middleAvg, cK1, cK2);
          final cMInner = _calculateInnerTemp(cM, lowerTemp, middleAvg, cK1, cK2);
          final cRInner = _calculateInnerTemp(cR, lowerTemp, middleAvg, cK1, cK2);
          
          // 按照页面显示顺序发送：A相6个值 + B相6个值 + C相6个值 = 18个值（36字节）
          // A相：[左外, 左内, 中外, 中内, 右外, 右内]
          // B相：[左外, 左内, 中外, 中内, 右外, 右内]
          // C相：[左外, 左内, 中外, 中内, 右外, 右内]
          final phaseTemps = [
            aL, aLInner, aM, aMInner, aR, aRInner,  // A相
            bL, bLInner, bM, bMInner, bR, bRInner,  // B相
            cL, cLInner, cM, cMInner, cR, cRInner,  // C相
          ];
          
          final data = <int>[];
          for (final temp in phaseTemps) {
            int raw;
            if (temp == -999.0) {
              raw = 0x8066; // 开路标记
            } else {
              final signedRaw = (temp / 0.01).round();
              raw = signedRaw < 0 ? (signedRaw + 65536) : signedRaw;
            }
            data.add((raw >> 8) & 0xFF);
            data.add(raw & 0xFF);
          }
          
          // 不再主动发送数据，等待客户端请求
          print('电缆接头测点温度数据已准备: 节点$nodeId (不再主动发送)');
          // _modbusClient.sendRS485Frame(
          //   nodeId: nodeId,
          //   sensorId: RS485Protocol.SENSOR_CABLE_TEMP,
          //   data: data,
          // );
        } catch (e) {
          print('PT100数据解析失败: $e');
        }
      }
      
      // ========== 第二部分：防爆盒内环境参数 ==========
      // 包含：上温度、中温度、下温度、湿度、压力、白烟、黑烟、H2、CO、烟雾比值、外部温度
      final envData = <int>[];
      
      // 上温度（2字节，高字节在前，乘以100）
      final upperTempRaw = (upperTemp * 100).round();
      envData.add((upperTempRaw >> 8) & 0xFF);
      envData.add(upperTempRaw & 0xFF);
      
      // 中温度（2字节，高字节在前，乘以100）
      final middleTempRaw = (middleTemp * 100).round();
      envData.add((middleTempRaw >> 8) & 0xFF);
      envData.add(middleTempRaw & 0xFF);
      
      // 下温度（2字节，高字节在前，乘以100）
      final lowerTempRaw = (lowerTemp * 100).round();
      envData.add((lowerTempRaw >> 8) & 0xFF);
      envData.add(lowerTempRaw & 0xFF);
      
      // 湿度（2字节，高字节在前，乘以100）
      final humidityRaw = (correctedHumidity * 100).round();
      envData.add((humidityRaw >> 8) & 0xFF);
      envData.add(humidityRaw & 0xFF);
      
      // 压力（2字节，高字节在前，乘以100）
      final pressureRaw = (pressure * 100).round();
      envData.add((pressureRaw >> 8) & 0xFF);
      envData.add(pressureRaw & 0xFF);
      
      // 白烟浓度（2字节，高字节在前，乘以1000）
      final whiteSmokeRaw = (whiteSmoke * 1000).round().clamp(0, 65535);
      envData.add((whiteSmokeRaw >> 8) & 0xFF);
      envData.add(whiteSmokeRaw & 0xFF);
      
      // 黑烟浓度（2字节，高字节在前，乘以1000）
      final blackSmokeRaw = (blackSmoke * 1000).round().clamp(0, 65535);
      envData.add((blackSmokeRaw >> 8) & 0xFF);
      envData.add(blackSmokeRaw & 0xFF);
      
      // H2浓度（1字节，百分比值）
      envData.add(h2Concentration.round().clamp(0, 255));
      
      // CO浓度（2字节，高字节在前，ppm值）
      final coRaw = coConcentration.round();
      envData.add((coRaw >> 8) & 0xFF);
      envData.add(coRaw & 0xFF);
      
      // 烟雾比值（1字节）- 使用上面声明的smokeRatio变量（已在1529行声明）
      envData.add(smokeRatio.round().clamp(0, 255));
      
      // 外部温度（2字节，低字节在前，乘以100）
      final extTempRaw = (smokeExternalTemp * 100).round().clamp(-32768, 32767);
      final signedExtTempRaw = extTempRaw < 0 ? (extTempRaw + 65536) : extTempRaw;
      envData.add(signedExtTempRaw & 0xFF);
      envData.add((signedExtTempRaw >> 8) & 0xFF);
      
      // 不再主动发送数据，等待客户端请求
      print('防爆盒内环境参数数据已准备: 节点$nodeId (不再主动发送)');
      // _modbusClient.sendRS485Frame(
      //   nodeId: nodeId,
      //   sensorId: RS485Protocol.SENSOR_ENV_PARAMS,
      //   data: envData,
      // );
      
    } catch (e) {
      print('发送处理后数据失败: $e');
    }
    */
  }

  // 检查故障信息
  void _checkFaultInfo(SensorData data) {
    final faults = <String>[];
    final faultData = <String, dynamic>{};

    // print('检查节点${data.nodeId}的故障信息...');

    // 检查烟雾传感器故障
    if (data.smokeStatus != null && (data.smokeStatus! & 0x04) != 0) {
      final key = '${data.nodeId}|smoke_fault';
      if (_shouldHoldTrigger(key, true, 5000)) {
        faults.add('烟雾传感器故障');
      }
      faultData['smoke_status'] = data.smokeStatus;
      faultData['smoke_channel_a'] = data.smokeChannelA;
      faultData['smoke_channel_b'] = data.smokeChannelB;
      print('检测到烟雾传感器故障: status=${data.smokeStatus}');
    }

    // 检查CO传感器异常值
    if (data.coPpm != null && (data.coPpm! < 0 || data.coPpm! > 10000)) {
      final key = '${data.nodeId}|co_abnormal';
      if (_shouldHoldTrigger(key, true, 5000)) {
        faults.add('CO传感器异常');
      }
      faultData['co_ppm'] = data.coPpm;
      print('检测到CO传感器异常: coPpm=${data.coPpm}');
    }

    // 检查PT100开路
    if (data.pt100Temperatures != null) {
      try {
        final temps = jsonDecode(data.pt100Temperatures!) as List;
        final openCircuits = temps.where((temp) => temp == -999.0).length;
        if (openCircuits > 0) {
          final key = '${data.nodeId}|pt100_open';
          if (_shouldHoldTrigger(key, true, 5000)) {
            faults.add('PT100传感器开路($openCircuits个通道)');
          }
          faultData['pt100_open_circuits'] = openCircuits;
          faultData['pt100_temperatures'] = temps;
          print('检测到PT100传感器开路: $openCircuits个通道');
        }
      } catch (e) {
        print('解析PT100温度数据失败: $e');
      }
    }

    // 移除测试故障检测，只检测真实故障

    // 如果有故障，发送通知
    if (faults.isNotEmpty) {
      final faultType = faults.join(', ');
      final faultDescription = '节点${data.nodeId}检测到故障: $faultType';
      final timestamp = DateTime.now().toIso8601String();

      print('故障信息已记录: $faultDescription (不再主动发送，等待客户端请求)');
      // 不再主动发送故障信息，等待客户端请求
      // _modbusClient.sendFaultInfo(
      //   nodeId: data.nodeId,
      //   faultType: faultType,
      //   faultDescription: faultDescription,
      //   timestamp: timestamp,
      //   faultData: faultData,
      // );

      // print('节点${data.nodeId}故障检测: $faultDescription');
    } else {
      // print('节点${data.nodeId}无故障');
    }
  }

}

// 传感器类型常量
class SensorTypes {
  static const int TEMP_HUMIDITY_SENSOR = 0x01;
  static const int CO_SENSOR = 0x02;
  static const int H2_SENSOR = 0x03;
  static const int PRESSURE_SENSOR = 0x04;
  static const int SMOKE_SENSOR = 0x05;
  static const int FAN_CONTROL = 0x06;
  static const int PT100_SENSOR = 0x07;
  static const int STATUS_OVERVIEW = 0x0C;
}