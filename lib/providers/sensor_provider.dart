import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../services/sensor_data_service.dart';
import '../models/node_data.dart';

class SensorProvider with ChangeNotifier {
  final SensorDataService _sensorService = SensorDataService();
  
  List<NodeData> _nodes = [];
  // 最多2个节点
  bool _isConnected = false;
  bool _isClientConnected = false;
  String _connectionStatus = '未连接';
  String _runtimeStats = '';
  int _receivedFrames = 0;
  String _lastDataFrame = '';
  String _lastUpdateTime = '';

  // Getters
  List<NodeData> get nodes => _nodes;
  bool get isConnected => _isConnected;
  bool get isClientConnected => _isClientConnected;
  String get connectionStatus => _connectionStatus;
  String get runtimeStats => _runtimeStats;
  int get receivedFrames => _receivedFrames;
  String get lastDataFrame => _lastDataFrame;
  String get lastUpdateTime => _lastUpdateTime;

  // 初始化
  Future<void> initialize() async {
    try {
      // 设置数据更新回调
      _sensorService.setDataUpdateCallback(
        onDataUpdate: _handleDataUpdate,
      );
      
      // 启动传感器服务
      await _sensorService.startReceiving();
      
      // 开始定时刷新
      _startPeriodicRefresh();
      
      print('传感器提供者初始化完成');
    } catch (e) {
      print('传感器提供者初始化失败: $e');
    }
  }

  // 处理数据更新
  void _handleDataUpdate(int sensorType, SensorData data) {
    try {
      // 更新最后更新时间
      final now = DateTime.now();
      _lastUpdateTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
      
      // 查找或创建节点
      int nodeIndex = _findNodeIndex(data.nodeId);
      if (nodeIndex == -1) {
        // 创建新节点
        final newNode = NodeData.fromSensorData(data);
        _nodes.add(newNode);
        // 限制最多5个节点：超过则移除最旧的一个（简单按列表头移除）
        if (_nodes.length > 5) {
          _nodes.removeAt(0);
        }
        nodeIndex = _nodes.length - 1;
      }
      
      // 更新节点数据
      final existingNode = _nodes[nodeIndex];
      final updatedNode = _updateNodeData(existingNode, data, sensorType);
      _nodes[nodeIndex] = updatedNode;
      
      // 更新连接状态
      _updateConnectionStatus();
      
      // 通知监听器
      notifyListeners();
      
      print('节点数据已更新: 节点${data.nodeId}, 类型$sensorType');
    } catch (e) {
      print('处理数据更新失败: $e');
    }
  }

  // 查找节点索引
  int _findNodeIndex(int nodeId) {
    for (int i = 0; i < _nodes.length; i++) {
      if (_nodes[i].nodeId == nodeId) {
        return i;
      }
    }
    return -1;
  }

  // 更新节点数据
  NodeData _updateNodeData(NodeData existingNode, SensorData data, int sensorType) {
    switch (sensorType) {
      case SensorTypes.TEMP_HUMIDITY_SENSOR:
        return existingNode.copyWith(
          temperature: data.temperature,
          humidity: data.humidity,
          lastUpdate: _lastUpdateTime,
          lastUpdateTimestamp: data.timestamp,
        );
      case SensorTypes.CO_SENSOR:
        return existingNode.copyWith(
          coPpm: data.coPpm,
          lastUpdate: _lastUpdateTime,
          lastUpdateTimestamp: data.timestamp,
        );
      case SensorTypes.H2_SENSOR:
        return existingNode.copyWith(
          h2Percentage: data.h2Percentage,
          lastUpdate: _lastUpdateTime,
          lastUpdateTimestamp: data.timestamp,
        );
      case SensorTypes.PRESSURE_SENSOR:
        return existingNode.copyWith(
          pressureKpa: data.pressureKpa,
          pressureTempC: data.pressureTempC,
          lastUpdate: _lastUpdateTime,
          lastUpdateTimestamp: data.timestamp,
        );
      case SensorTypes.SMOKE_SENSOR:
        print('处理烟雾数据: smokeChannelA=${data.smokeChannelA}, smokeChannelB=${data.smokeChannelB}');
        print('烟雾标定参数: calibA=${data.smokeCalibA}, calibB=${data.smokeCalibB}');
        print('烟雾阈值参数: threshA=${data.smokeThreshA}, threshB=${data.smokeThreshB}');
        return existingNode.copyWith(
          smokeAlarm: data.smokeStatus != null ? (data.smokeStatus! & 0x04) != 0 : null,
          smokeChannelA: data.smokeChannelA,
          smokeChannelB: data.smokeChannelB,
          smokeCalibA: data.smokeCalibA,
          smokeCalibB: data.smokeCalibB,
          smokeThreshA: data.smokeThreshA,
          smokeThreshB: data.smokeThreshB,
          smokeExternalTempC: data.smokeExternalTempC,
          lastUpdate: _lastUpdateTime,
          lastUpdateTimestamp: data.timestamp,
        );
      case SensorTypes.PT100_SENSOR:
        print('处理PT100数据: ${data.pt100Temperatures}');
        List<double>? pt100Temps;
        if (data.pt100Temperatures != null) {
          try {
            if (data.pt100Temperatures is String) {
              final List<dynamic> temps = jsonDecode(data.pt100Temperatures!);
              pt100Temps = temps.cast<double>();
            } else if (data.pt100Temperatures is List) {
              pt100Temps = (data.pt100Temperatures as List).cast<double>();
            }
          } catch (e) {
            print('解析PT100温度数据失败: $e');
          }
        }
        print('PT100数据更新: $pt100Temps');
        final updatedNode = existingNode.copyWith(
          pt100Temperatures: pt100Temps,
          lastUpdate: _lastUpdateTime,
          lastUpdateTimestamp: data.timestamp,
        );
        print('更新后的节点PT100数据: ${updatedNode.pt100Temperatures}');
        return updatedNode;
      case SensorTypes.STATUS_OVERVIEW:
        return existingNode.copyWith(
          stCoLen: data.stCoLen,
          stSmokeLen: data.stSmokeLen,
          stH2Len: data.stH2Len,
          stPt100Len: data.stPt100Len,
          stThLen: data.stThLen,
          stPressureLen: data.stPressureLen,
          lastUpdate: _lastUpdateTime,
          lastUpdateTimestamp: data.timestamp,
        );
      default:
        return existingNode;
    }
  }

  // 更新连接状态
  void _updateConnectionStatus() {
    _isConnected = _sensorService.isConnected();
    _isClientConnected = _sensorService.isClientConnected();
    _connectionStatus = _sensorService.getConnectionStatus();
    _runtimeStats = _sensorService.getRuntimeStats();
    _receivedFrames = _sensorService.getFramesExtracted();
    
    final hexSamples = _sensorService.getLastHexSamples();
    _lastDataFrame = hexSamples['frame'] ?? '';
  }

  // 开始定时刷新
  void _startPeriodicRefresh() {
    // 每秒刷新一次连接状态
    Timer.periodic(Duration(seconds: 1), (timer) {
      if (!_isConnected) {
        timer.cancel();
        return;
      }
      _updateConnectionStatus();
      notifyListeners();
    });
  }

  // 手动重连
  Future<void> manualReconnect() async {
    try {
      _connectionStatus = '重连中...';
      notifyListeners();
      
      _sensorService.stopReceiving();
      await _sensorService.startReceiving();
      
      _updateConnectionStatus();
      notifyListeners();
      
      print('手动重连完成');
    } catch (e) {
      print('手动重连失败: $e');
      _connectionStatus = '重连失败';
      notifyListeners();
    }
  }

  // 重置所有数据
  Future<void> resetAllData() async {
    try {
      final result = await _sensorService.resetAllData();
      _nodes.clear();
      _lastUpdateTime = '';
      notifyListeners();
      
      print('数据重置完成: 数据库删除${result['dbResult']}条记录');
    } catch (e) {
      print('重置数据失败: $e');
    }
  }

  // 添加节点
  void addNode(int nodeId) {
    if (_findNodeIndex(nodeId) != -1) {
      print('节点$nodeId已存在');
      return;
    }
    
    final newNode = NodeData(nodeId: nodeId);
    _nodes.add(newNode);
    notifyListeners();
    
    // 发送状态查询命令
    _sensorService.sendStatusQueryCommand(nodeId);
    
    print('已添加节点$nodeId');
  }

  // 删除节点
  void removeNode(int nodeId) {
    final index = _findNodeIndex(nodeId);
    if (index != -1) {
      _nodes.removeAt(index);
      notifyListeners();
      print('已删除节点$nodeId');
    }
  }

  // 获取节点数据
  NodeData? getNodeData(int nodeId) {
    final index = _findNodeIndex(nodeId);
    return index != -1 ? _nodes[index] : null;
  }

  // 获取网络连接状态
  bool get isNetworkConnected => _sensorService.isNetworkConnected();

  // 清理资源
  void dispose() {
    _sensorService.stopReceiving();
    super.dispose();
  }
}

