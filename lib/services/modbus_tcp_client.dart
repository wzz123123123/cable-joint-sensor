import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'rs485_protocol.dart';

/// 简单的Modbus TCP客户端，用于向192.168.201.203发送JSON数据
class ModbusTcpClient {
  static final ModbusTcpClient _instance = ModbusTcpClient._internal();
  factory ModbusTcpClient() => _instance;
  ModbusTcpClient._internal();

  static const String _serverHost = '192.168.201.203';
  static const int _serverPort = 502; // Modbus TCP标准端口
  static const int _timeoutSeconds = 3;

  Socket? _socket;
  bool _isConnected = false;
  Timer? _connectionCheckTimer;
  int _transactionId = 0x0001; // 事务ID计数器，递增使用

  /// 发送节点连接状态变化通知
  Future<bool> sendNodeConnectionChange({
    required int nodeId,
    required bool isConnected,
    required String timestamp,
  }) async {
    final jsonData = {
      'type': 'node_connection_change',
      'node_id': nodeId,
      'is_connected': isConnected,
      'timestamp': timestamp,
      'message': isConnected ? '客户端已连接' : '客户端已断开',
    };

    return await _sendJsonData(jsonData, unitId: nodeId);
  }

  /// 发送每分钟历史数据
  /// 根据节点编号（1-9）分配对应的 Unit ID（1-9）
  Future<bool> sendMinuteHistoryData({
    required int nodeId,
    required Map<String, dynamic> sensorData,
    required String timestamp,
  }) async {
    final jsonData = {
      'type': 'minute_history_data',
      'node_id': nodeId,
      'timestamp': timestamp,
      'sensor_data': sensorData,
    };

    // 节点1-9 对应 Unit ID 1-9
    return await _sendJsonData(jsonData, unitId: nodeId);
  }

  /// 发送故障信息
  /// 根据节点编号（1-9）分配对应的 Unit ID（1-9）
  Future<bool> sendFaultInfo({
    required int nodeId,
    required String faultType,
    required String faultDescription,
    required String timestamp,
    required Map<String, dynamic> faultData,
  }) async {
    final jsonData = {
      'type': 'fault_info',
      'node_id': nodeId,
      'fault_type': faultType,
      'fault_description': faultDescription,
      'timestamp': timestamp,
      'fault_data': faultData,
    };

    // 节点1-9 对应 Unit ID 1-9
    return await _sendJsonData(jsonData, unitId: nodeId);
  }

  /// 发送实时信息（03类型报文）
  /// 根据节点编号（1-9）分配对应的 Unit ID（1-9）
  Future<bool> sendRealtimeData({
    required int nodeId,
    required Map<String, dynamic> sensorData,
    required String timestamp,
  }) async {
    final jsonData = {
      'type': 'realtime_data',
      'node_id': nodeId,
      'timestamp': timestamp,
      'sensor_data': sensorData,
    };

    // 节点1-9 对应 Unit ID 1-9
    return await _sendJsonData(jsonData, unitId: nodeId);
  }

  /// 发送485格式数据帧到远端服务器
  /// 格式：节点地址(1) + 传感器编号(1) + 数据长度(1) + 数据(n) + CRC16[7-0](1) + CRC16[15-8](1)
  Future<bool> sendRS485Frame({
    required int nodeId,
    required int sensorId,
    required List<int> data,
  }) async {
    try {
      // 计算CRC16
      int calculateCRC16(List<int> data) {
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
      
      // 创建485格式帧
      final rs485Frame = RS485Protocol.createRS485Frame(
        nodeId: nodeId,
        sensorId: sensorId,
        data: data,
        calculateCRC16: calculateCRC16,
      );
      
      // 将485帧封装到Modbus TCP帧中发送
      final targetUnitId = nodeId.clamp(1, 9);
      final modbusFrame = _createModbusTcpFrame(rs485Frame, unitId: targetUnitId);
      
      if (_socket == null || !_isConnected) {
        print('连接不存在，尝试建立新连接...');
        final connected = await _connect();
        if (!connected) {
          print('Modbus TCP连接失败，跳过485帧发送');
          return false;
        }
      }
      
      _socket!.add(modbusFrame);
      await _socket!.flush();
      print('📤 485格式数据发送成功: 节点=$nodeId, 传感器=$sensorId, 数据长度=${data.length}');
      return true;
    } catch (e) {
      print('❌ 485格式数据发送失败: $e');
      _isConnected = false;
      return false;
    }
  }

  /// 发送通用JSON数据
  Future<bool> _sendJsonData(Map<String, dynamic> jsonData, {int? unitId}) async {
    try {
      // 从JSON中提取节点ID，如果没有指定unitId
      final nodeId = unitId ?? jsonData['node_id'] as int? ?? 1;
      // 限制节点ID范围 1-9，对应 Unit ID 1-9
      final targetUnitId = nodeId.clamp(1, 9);
      
      // 将JSON数据转换为字节数组
      final jsonString = jsonEncode(jsonData);
      final jsonBytes = utf8.encode(jsonString);
      // 报文类型前缀：0x01=历史数据, 0x02=故障/预警, 0x03=实时信息
      final typeStr = (jsonData['type'] as String?) ?? '';
      final int messageType = (typeStr == 'minute_history_data')
          ? 0x01
          : (typeStr == 'fault_info')
              ? 0x02
              : (typeStr == 'realtime_data')
                  ? 0x03
                  : 0x01;
      final payload = Uint8List(1 + jsonBytes.length);
      payload[0] = messageType;
      for (int i = 0; i < jsonBytes.length; i++) {
        payload[1 + i] = jsonBytes[i];
      }
      
      // 创建Modbus TCP帧（标准结构）
      final modbusFrame = _createModbusTcpFrame(payload, unitId: targetUnitId);
      
      // 检查连接状态，只有在必要时才重新连接
      if (_socket == null || !_isConnected) {
        print('连接不存在，尝试建立新连接...');
        final connected = await _connect();
        if (!connected) {
          print('Modbus TCP连接失败，跳过数据发送: ${jsonData['type']}');
          return false;
        }
      }
      
      // 发送数据
      _socket!.add(modbusFrame);
      await _socket!.flush();
      
      print('Modbus TCP数据发送成功: ${jsonData['type']}');
      return true;
    } catch (e) {
      print('Modbus TCP数据发送失败: $e');
      // 标记连接为断开，但不立即关闭socket，让监控机制处理重连
      _isConnected = false;
      return false;
    }
  }

  /// 建立长连接
  Future<bool> _connect() async {
    try {
      // 如果已有连接，先关闭
      if (_socket != null) {
        _socket!.close();
        _socket = null;
      }
      
      _socket = await Socket.connect(
        _serverHost,
        _serverPort,
        timeout: Duration(seconds: _timeoutSeconds),
      );
      _isConnected = true;
      print('Modbus TCP长连接已建立: $_serverHost:$_serverPort');
      return true;
    } catch (e) {
      print('Modbus TCP连接失败: $e');
      _isConnected = false;
      _socket = null;
      return false;
    }
  }

  /// 创建Modbus TCP帧（标准结构）
  /// Modbus TCP帧结构：
  /// Transaction ID (2 bytes) + Protocol ID (2 bytes) + Length (2 bytes) + Unit ID (1 byte) + Function Code (1 byte) + Data (N bytes)
  Uint8List _createModbusTcpFrame(List<int> data, {int unitId = 1}) {
    // 递增事务ID（0x0001-0xFFFF循环）
    _transactionId = (_transactionId >= 0xFFFF) ? 0x0001 : (_transactionId + 1);
    final transactionId = _transactionId;
    
    final protocolId = 0x0000;     // 协议ID (0 = Modbus TCP)
    // Unit ID 根据节点编号：节点1-9 对应 Unit ID 1-9
    final targetUnitId = unitId.clamp(1, 9);
    final functionCode = 0x10;      // 功能码 0x10 = Write Multiple Registers
    
    // 计算MBAP头后的长度：Unit ID (1) + Function Code (1) + Data Length
    final mbapLength = 1 + 1 + data.length;
    
    final frame = Uint8List(6 + mbapLength);
    
    // MBAP Header
    // Transaction ID (2 bytes) - 递增的事务标识符
    frame[0] = (transactionId >> 8) & 0xFF;
    frame[1] = transactionId & 0xFF;
    
    // Protocol ID (2 bytes) - 0x0000 = Modbus
    frame[2] = (protocolId >> 8) & 0xFF;
    frame[3] = protocolId & 0xFF;
    
    // Length (2 bytes) - 后续字节数（Unit ID + Function Code + Data）
    frame[4] = (mbapLength >> 8) & 0xFF;
    frame[5] = mbapLength & 0xFF;
    
    // Modbus PDU (Protocol Data Unit)
    // Unit ID (1 byte) - 设备地址，根据节点编号 1-9
    frame[6] = targetUnitId;
    
    // Function Code (1 byte) - 0x10 = Write Multiple Registers
    frame[7] = functionCode;
    
    // Data (N bytes) - JSON字符串的UTF-8字节流
    for (int i = 0; i < data.length; i++) {
      frame[8 + i] = data[i];
    }
    
    return frame;
  }

  /// 检测远端服务器连接状态
  Future<bool> checkServerConnection() async {
    try {
      // 如果已有连接，直接返回连接状态
      if (_socket != null && _isConnected) {
        print('Modbus TCP服务器连接正常: $_serverHost:$_serverPort');
        return true;
      }
      
      // 尝试建立新连接
      return await _connect();
    } catch (e) {
      _isConnected = false;
      print('Modbus TCP服务器连接失败: $e');
      return false;
    }
  }

  /// 启动定期连接检测
  void startConnectionMonitoring() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = Timer.periodic(Duration(seconds: 60), (timer) async {
      // 只有在连接断开时才尝试重连
      if (!_isConnected || _socket == null) {
        print('检测到连接断开，尝试重新连接...');
        await _connect();
      }
    });
    
    // 启动时立即建立连接
    _connect();
    print('Modbus TCP连接监控已启动');
  }

  /// 停止连接检测
  void stopConnectionMonitoring() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = null;
    print('Modbus TCP连接监控已停止');
  }

  /// 获取当前连接状态
  bool get isServerConnected => _isConnected;

  /// 获取服务器信息
  String get serverInfo => '$_serverHost:$_serverPort';

  /// 清理资源
  void dispose() {
    stopConnectionMonitoring();
    _socket?.close();
    _socket = null;
    _isConnected = false;
    print('Modbus TCP客户端已清理');
  }
}
