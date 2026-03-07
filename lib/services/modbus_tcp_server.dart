import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart' show unawaited;
import 'csv_logger_service.dart';
import 'settings_service.dart';
import 'alert_service.dart';
import 'node_data_calculator.dart';
import 'sensor_data_service.dart';
import 'rs485_protocol.dart';
import '../models/node_data.dart';

/// Modbus TCP服务器，监听客户端连接，根据请求返回节点数据（485格式）
class ModbusTcpServer {
  static final ModbusTcpServer _instance = ModbusTcpServer._internal();
  factory ModbusTcpServer() => _instance;
  ModbusTcpServer._internal();

  static const int _listenPort = 10124; // 监听端口（节点6-7）
  ServerSocket? _serverSocket;
  final Map<Socket, String> _clients = {}; // 客户端连接管理
  bool _isRunning = false;
  int _transactionId = 0x0001;
  
  // 设置缓存（按节点ID缓存）
  final Map<int, Map<String, dynamic>> _settingsCache = {};
  Timer? _settingsCacheTimer;
  
  // 缓存每个节点上一次非空的响应数据（用于未连接时返回）
  // key: nodeId, value: 上一次非空的响应数据
  final Map<int, List<int>> _lastValidResponseCache = {};
  
  // 温度值历史记录（用于异常值过滤）
  // key: '${nodeId}_${phase}_${channelIndex}', value: 最近的有效温度值列表
  final Map<String, List<double>> _tempHistoryCache = {};
  
  // 温度值异常跳变阈值（°C）
  static const double _tempJumpThreshold = 10.0; // 超过±10°C的变化认为是异常
  static const double _tempMinValue = -50.0; // 最小合理温度（去掉上限）

  /// 启动服务器
  Future<bool> start() async {
    if (_isRunning) {
      print('Modbus TCP服务器已在运行');
      return true;
    }

    try {
      _serverSocket = await ServerSocket.bind(
        InternetAddress('0.0.0.0'),
        _listenPort,
        shared: true,
      );
      _isRunning = true;
      print('✅ Modbus TCP服务器已启动，监听地址: 0.0.0.0:$_listenPort');

      _serverSocket!.listen((Socket client) {
        _handleClient(client);
      });

      // 启动设置缓存刷新定时器（每30秒刷新一次）
      _settingsCacheTimer = Timer.periodic(Duration(seconds: 30), (timer) {
        _refreshSettingsCache();
      });

      return true;
    } catch (e) {
      print('❌ Modbus TCP服务器启动失败: $e');
      _isRunning = false;
      return false;
    }
  }

  /// 停止服务器
  void stop() {
    if (!_isRunning) return;

    _isRunning = false;
    _serverSocket?.close();
    _serverSocket = null;

    // 关闭所有客户端连接
    for (final client in _clients.keys) {
      client.close();
    }
    _clients.clear();

    // 停止设置缓存定时器
    _settingsCacheTimer?.cancel();
    _settingsCacheTimer = null;

    print('Modbus TCP服务器已停止');
  }

  /// 异步加载设置到缓存
  Future<void> _loadSettingsToCache(int nodeId) async {
    try {
      final settingsService = SettingsService();
      final settings = await settingsService.getAllSettingsForNode(nodeId);
      _settingsCache[nodeId] = settings;
    } catch (e) {
      print('⚠️ 加载节点$nodeId设置失败: $e');
    }
  }

  /// 刷新所有节点的设置缓存
  Future<void> _refreshSettingsCache() async {
    try {
      // 刷新所有已缓存节点的设置
      for (final nodeId in _settingsCache.keys.toList()) {
        await _loadSettingsToCache(nodeId);
      }
    } catch (e) {
      print('⚠️ 刷新设置缓存失败: $e');
    }
  }

  /// 处理客户端连接
  void _handleClient(Socket client) {
    final clientAddress = client.remoteAddress.address;
    final clientInfo = '$clientAddress:${client.remotePort}';
    
    _clients[client] = clientInfo;
    print('📥 新客户端连接: $clientInfo');

    // 监听客户端数据
    client.listen(
      (Uint8List data) {
        _handleClientData(client, data);
      },
      onError: (error) {
        print('❌ 客户端错误: $error');
        _disconnectClient(client);
      },
      onDone: () {
        print('📤 客户端断开连接: $clientInfo');
        _disconnectClient(client);
      },
    );
  }

  /// 断开客户端连接
  void _disconnectClient(Socket client) {
    _clients.remove(client);
    client.close();
  }

  /// 处理客户端数据（Modbus TCP请求）
  void _handleClientData(Socket client, Uint8List data) {
    unawaited(_handleClientDataAsync(client, data));
  }

  /// 异步处理客户端数据
  Future<void> _handleClientDataAsync(Socket client, Uint8List data) async {
    try {
      // 打印完整接收数据（十六进制）用于调试
      final hexString = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      print('🔍 收到完整数据（${data.length}字节）: $hexString');
      
      if (data.length < 8) {
        print('⚠️ 数据长度不足: ${data.length}');
        return;
      }

      // 解析Modbus TCP MBAP头
      final transactionId = (data[0] << 8) | data[1];
      final protocolId = (data[2] << 8) | data[3];
      final length = (data[4] << 8) | data[5];
      final unitId = data[6]; // 节点号（站地址）
      final functionCode = data[7];

      print('📨 收到Modbus TCP请求: 事务ID=$transactionId (0x${transactionId.toRadixString(16).padLeft(4, '0')}), 协议ID=$protocolId (0x${protocolId.toRadixString(16).padLeft(4, '0')}), 长度=$length, 节点=$unitId (0x${unitId.toRadixString(16).padLeft(2, '0')}), 功能码=$functionCode (0x${functionCode.toRadixString(16).padLeft(2, '0')})');

      // 只处理功能码03（读保持寄存器）
      if (functionCode != 0x03) {
        print('⚠️ 不支持的功能码: $functionCode');
        _sendErrorResponse(client, transactionId, unitId, functionCode, 0x01); // 非法功能码
        return;
      }

      // 解析PDU（从第8字节开始）
      if (data.length < 12) {
        print('⚠️ PDU数据不完整');
        return;
      }

      final startAddress = (data[8] << 8) | data[9]; // 起始寄存器地址
      final quantity = (data[10] << 8) | data[11];   // 寄存器数量

      print('📊 请求参数: 起始地址=$startAddress (0x${startAddress.toRadixString(16).padLeft(4, '0')}), 寄存器数量=$quantity (0x${quantity.toRadixString(16).padLeft(4, '0')})');

      // 验证地址范围（有效范围：0x0000-0x0023，共36个寄存器）
      final maxAddress = 0x0023;
      final maxQuantity = maxAddress - startAddress + 1; // 从起始地址到最大地址的数量
      
      if (startAddress > maxAddress) {
        print('⚠️ 起始地址超出范围: 起始地址=$startAddress (0x${startAddress.toRadixString(16).padLeft(4, '0')}), 最大地址=$maxAddress (0x${maxAddress.toRadixString(16).padLeft(4, '0')})');
        _sendErrorResponse(client, transactionId, unitId, functionCode, 0x02); // 非法数据地址
        return;
      }
      
      // 如果请求的数量超出范围，限制到有效范围
      int actualQuantity = quantity;
      if (startAddress + quantity - 1 > maxAddress) {
        actualQuantity = maxQuantity;
        print('⚠️ 寄存器数量超出范围，已限制: 请求数量=$quantity (0x${quantity.toRadixString(16).padLeft(4, '0')}), 实际返回=$actualQuantity (0x${actualQuantity.toRadixString(16).padLeft(4, '0')}), 最大地址=$maxAddress (0x${maxAddress.toRadixString(16).padLeft(4, '0')})');
      }

      // 生成响应数据（485格式）
      final responseData = await _generateNodeDataResponse(unitId, startAddress, actualQuantity);

      if (responseData.isEmpty) {
        print('⚠️ 无法生成节点$unitId的响应数据（起始地址=$startAddress, 数量=$actualQuantity）');
        // 如果无法生成数据，尝试返回上一次正常的数据
        if (_lastValidResponseCache.containsKey(unitId) && _lastValidResponseCache[unitId]!.isNotEmpty) {
          print('📦 节点$unitId数据为空，返回上一次正常数据（缓存长度=${_lastValidResponseCache[unitId]!.length}）');
          _sendResponse(client, transactionId, unitId, functionCode, _lastValidResponseCache[unitId]!);
          return;
        }
        // 如果缓存也没有，才发送错误响应
        print('❌ 节点$unitId无数据且无缓存，发送错误响应');
        _sendErrorResponse(client, transactionId, unitId, functionCode, 0x02); // 非法数据地址
        return;
      }

      // 发送响应
      _sendResponse(client, transactionId, unitId, functionCode, responseData);
    } catch (e) {
      print('❌ 处理客户端数据失败: $e');
    }
  }

  /// 生成节点数据响应（485格式）
  /// 返回：节点号(1) + 字节长度(1) + 数据(n) + 间隔(1) + 下一组数据...
  Future<List<int>> _generateNodeDataResponse(int nodeId, int startAddress, int quantity) async {
    final response = <int>[];

    try {
      // 获取节点最新快照
      final snapshot = CsvLoggerService.instance.getNodeSnapshot(nodeId);
      if (snapshot == null) {
        print('⚠️ 节点$nodeId快照不存在（起始地址=$startAddress, 数量=$quantity）');
        // 如果快照不存在，尝试返回上一次非空的响应数据
        if (_lastValidResponseCache.containsKey(nodeId) && _lastValidResponseCache[nodeId]!.isNotEmpty) {
          print('📦 节点$nodeId未连接，返回上一次非空数据（缓存长度=${_lastValidResponseCache[nodeId]!.length}）');
          return List.from(_lastValidResponseCache[nodeId]!);
        }
        print('❌ 节点$nodeId快照不存在且无缓存数据');
        return [];
      }

      // 检查节点是否未连接
      bool isDisconnected = false;
      try {
        final nodeData = _snapshotToNodeData(snapshot, nodeId);
        if (nodeData != null) {
          // 检查是否未连接：超过40秒未更新或没有实际传感器数据
          final now = DateTime.now().millisecondsSinceEpoch;
          final isStale = nodeData.lastUpdateTimestamp == null || 
                         (now - nodeData.lastUpdateTimestamp! > 40000);
          
          final hasData = nodeData.temperature != null || nodeData.humidity != null || 
                         nodeData.coPpm != null || nodeData.h2Percentage != null || 
                         nodeData.pressureKpa != null || nodeData.smokeChannelA != null || 
                         nodeData.smokeChannelB != null || 
                         (nodeData.pt100Temperatures != null && nodeData.pt100Temperatures!.isNotEmpty);
          
          isDisconnected = isStale || !hasData;
        } else {
          isDisconnected = true;
        }
      } catch (e) {
        print('⚠️ 检查节点连接状态失败: $e');
        isDisconnected = true;
      }

      // 如果节点未连接，返回上一次非空的响应数据
      if (isDisconnected) {
        if (_lastValidResponseCache.containsKey(nodeId) && _lastValidResponseCache[nodeId]!.isNotEmpty) {
          print('📦 节点$nodeId未连接，返回上一次非空数据（缓存长度=${_lastValidResponseCache[nodeId]!.length}）');
          return List.from(_lastValidResponseCache[nodeId]!);
        }
        print('⚠️ 节点$nodeId未连接且无缓存数据（起始地址=$startAddress, 数量=$quantity）');
        return [];
      }

      // 将快照转换为SensorData，然后使用NodeDataCalculator获取与页面显示完全一致的数据
      final sensorData = _snapshotToSensorData(snapshot, nodeId);
      if (sensorData == null) {
        print('⚠️ 节点$nodeId快照转换为SensorData失败');
        return [];
      }

      // 使用NodeDataCalculator获取与页面显示完全一致的数据
      final calculator = NodeDataCalculator();
      final displayData = await calculator.calculateDisplayData(sensorData);

      // 获取节点设置（修正值）- 从缓存获取
      Map<String, dynamic> nodeSettings;
      if (_settingsCache.containsKey(nodeId)) {
        nodeSettings = _settingsCache[nodeId]!;
      } else {
        // 使用默认值
        nodeSettings = <String, dynamic>{
          'pt100Corrections': List.filled(10, 0.0),
          'upperTempCorrection': 0.0,
          'envTempCorrection': 0.0,
          'lowerTempCorrection': 0.0,
          'humidityCorrection': 0.0,
          'aK1': 6.42,
          'aK2': 2.5,
          'bK1': 6.42,
          'bK2': 2.5,
          'cK1': 6.42,
          'cK2': 2.5,
        };
        // 异步加载实际设置到缓存
        _loadSettingsToCache(nodeId);
      }

      // 获取节点预警/故障状态
      // 从快照转换为NodeData，然后分析预警/故障
      AlertInfo? alerts;
      try {
        final nodeData = _snapshotToNodeData(snapshot, nodeId);
        if (nodeData != null) {
          final alertService = AlertService();
          alerts = await alertService.analyzeNodeData(nodeData);
        }
      } catch (e) {
        print('⚠️ 获取节点预警/故障状态失败: $e');
        alerts = null;
      }

      // 根据起始地址和数量，生成对应的数据
      // 寄存器映射（每个数据项格式：状态2字节 + 数据值n字节，只传输页面显示的数据）：
      // 0x0000-0x000F: A相温度数据（4个温度值：左外、中外、右外、中内，每个：状态2字节+数据2字节=4字节，共16字节=8个寄存器）
      // 0x0010-0x001F: B相温度数据（同上，8个寄存器）
      // 0x0020-0x002F: C相温度数据（同上，8个寄存器）
      // 0x0030-0x003B: 环境参数（上温度、中温度、下温度、湿度、压力，每个：状态2字节+数据2字节=4字节，共5个参数，20字节=10个寄存器）
      // 0x003C-0x0043: 烟雾和气体（白烟、黑烟、H2、CO，每个：状态2字节+数据2字节=4字节，共4个参数，16字节=8个寄存器）

      // 根据起始地址和数量，生成对应的Modbus TCP格式数据
      // Modbus TCP格式：直接返回寄存器值（每个寄存器2字节，高字节在前）
      final endAddress = startAddress + quantity;
      int currentAddress = startAddress;

      while (currentAddress < endAddress) {
        // 根据单个寄存器地址返回对应的2字节值（Modbus TCP格式）
        List<int> registerValue = [0, 0];
        
        // A相温度（0x0000-0x0006，7个寄存器）
        if (currentAddress >= 0x0000 && currentAddress <= 0x0006) {
          registerValue = _getPhaseTempRegisterValue67(displayData, nodeSettings, nodeId, alerts, 'A', currentAddress - 0x0000);
        }
        // B相温度（0x0007-0x000D，7个寄存器）
        else if (currentAddress >= 0x0007 && currentAddress <= 0x000D) {
          registerValue = _getPhaseTempRegisterValue67(displayData, nodeSettings, nodeId, alerts, 'B', currentAddress - 0x0007);
        }
        // C相温度（0x000E-0x0014，7个寄存器）
        else if (currentAddress >= 0x000E && currentAddress <= 0x0014) {
          registerValue = _getPhaseTempRegisterValue67(displayData, nodeSettings, nodeId, alerts, 'C', currentAddress - 0x000E);
        }
        // 环境参数（0x0015-0x001B，7个寄存器）
        else if (currentAddress >= 0x0015 && currentAddress <= 0x001B) {
          registerValue = _getEnvironmentRegisterValue67(displayData, nodeSettings, alerts, currentAddress - 0x0015, nodeId);
        }
        // 烟雾和气体（0x001C-0x0023，8个寄存器）
        else if (currentAddress >= 0x001C && currentAddress <= 0x0023) {
          registerValue = _getSmokeAndGasRegisterValue67(displayData, nodeSettings, alerts, currentAddress - 0x001C);
        }
        
        // Modbus TCP格式：直接添加寄存器值（2字节，高字节在前）
        response.addAll(registerValue);
        
        currentAddress += 1; // 每次处理1个寄存器
      }

      // 缓存本次响应数据（如果非空）
      if (response.isNotEmpty) {
        _lastValidResponseCache[nodeId] = List.from(response);
        print('💾 节点$nodeId响应数据已缓存（长度=${response.length}）');
      }

      return response;
    } catch (e) {
      print('❌ 生成节点数据响应失败: $e');
      // 如果生成失败，尝试返回缓存的上一次正常数据
      if (_lastValidResponseCache.containsKey(nodeId) && _lastValidResponseCache[nodeId]!.isNotEmpty) {
        print('📦 节点$nodeId生成响应失败，返回缓存的上一次正常数据');
        return List.from(_lastValidResponseCache[nodeId]!);
      }
      return [];
    }
  }

  /// 获取相温度数据（A/B/C相，只传输页面显示的4个温度值：左外、中外、右外、中内）
  List<int> _getPhaseTemperatureData(dynamic snapshot, Map<String, dynamic> nodeSettings, int address, int nodeId, AlertInfo? alerts, String phase) {
    final data = <int>[];

    try {
      if (snapshot.pt100Temperatures == null) {
        return List.filled(14, 0); // 返回14个0（4个温度值：左外4字节+中外2字节+右外4字节+中内4字节=14字节，中外跳过状态）
      }

      final temps = jsonDecode(snapshot.pt100Temperatures!) as List;
      if (temps.length < 9) {
        return List.filled(14, 0); // 返回14个0（4个温度值：左外4字节+中外2字节+右外4字节+中内4字节=14字节，中外跳过状态）
      }

      final pt100Corrections = nodeSettings['pt100Corrections'] as List<dynamic>? ?? List.filled(10, 0.0);
      final upperCorr = nodeSettings['upperTempCorrection'] as double? ?? 0.0;
      final middleCorr = nodeSettings['envTempCorrection'] as double? ?? 0.0;
      final lowerCorr = nodeSettings['lowerTempCorrection'] as double? ?? 0.0;

      // 应用误差修正
      final corrected = List<double>.generate(
        temps.length,
        (i) {
          final base = temps[i] as double;
          if (base == -999) return -999;
          final delta = i < pt100Corrections.length ? (pt100Corrections[i] as double? ?? 0.0) : 0.0;
          return base + delta;
        },
      );

      // 更新上中下温度
      double upperTemp = (snapshot.temperature ?? 25) + upperCorr;
      double middleTemp = (snapshot.temperature ?? 25) + middleCorr;
      double lowerTemp = (snapshot.temperature ?? 25) + lowerCorr;

      if (nodeId == 1 && corrected.length >= 11) {
        upperTemp = corrected[10] + upperCorr;
      } else if (corrected.length >= 10) {
        upperTemp = corrected[9] + upperCorr;
      }

      if (corrected.length >= 12 && corrected[11] != -999) {
        middleTemp = corrected[11] + middleCorr;
      }

      // 根据phase参数确定是哪个相
      int phaseOffset;
      double envTemp;
      if (phase == 'A') {
        // A相
        phaseOffset = 0;
        envTemp = upperTemp;
      } else if (phase == 'B') {
        // B相
        phaseOffset = 3;
        envTemp = middleTemp;
      } else {
        // C相
        phaseOffset = 6;
        envTemp = lowerTemp;
      }

      // 获取该相的3个外温度值（左外、中外、右外）
      final aL = corrected[phaseOffset + 0];
      final aM = corrected[phaseOffset + 1];
      final aR = corrected[phaseOffset + 2];

      // 计算三相平均值（用于内温度计算）
      final leftAvg = (corrected[0] + corrected[3] + corrected[6]) / 3;
      final middleAvg = (corrected[1] + corrected[4] + corrected[7]) / 3;
      final rightAvg = (corrected[2] + corrected[5] + corrected[8]) / 3;

      // 获取K1、K2参数
      final k1 = phaseOffset == 0
          ? (nodeSettings['aK1'] as double? ?? 6.42)
          : phaseOffset == 3
              ? (nodeSettings['bK1'] as double? ?? 6.42)
              : (nodeSettings['cK1'] as double? ?? 6.42);
      final k2 = phaseOffset == 0
          ? (nodeSettings['aK2'] as double? ?? 2.5)
          : phaseOffset == 3
              ? (nodeSettings['bK2'] as double? ?? 2.5)
              : (nodeSettings['cK2'] as double? ?? 2.5);

      // 计算内温度
      double _calculateInnerTemp(double xi, double x0i, double xia, double k1, double k2) {
        if (xi == -999) return -999;
        if (xi < x0i) return xi;
        final deltaEnv = (xi - x0i) < 0 ? 0 : (xi - x0i);
        final deltaPhaseAvg = (xi - xia) < 0 ? 0 : (xi - xia);
        return xi + k1 * deltaEnv + k2 * deltaPhaseAvg;
      }

      // 根据位置使用不同的平均值
      final aLInner = _calculateInnerTemp(aL, envTemp, leftAvg, k1, k2);
      final aMInner = _calculateInnerTemp(aM, envTemp, middleAvg, k1, k2);
      final aRInner = _calculateInnerTemp(aR, envTemp, rightAvg, k1, k2);

      // 获取该相的温度状态
      final phaseStatus = _getPhaseTemperatureStatus(alerts, phase);
      
      // 只传输页面显示的4个温度值：左外、中外、右外、中内（不传输左内和右内）
      final tempsList = [aL, aM, aR, aMInner]; // [左外, 中外, 右外, 中内]
      for (int i = 0; i < tempsList.length; i++) {
        final temp = tempsList[i];
        // 跳过中外温度的状态（i=1对应中外温度）
        if (i != 1) {
          // 先添加状态（2字节，高字节在前）
          data.add((phaseStatus >> 8) & 0xFF);
          data.add(phaseStatus & 0xFF);
        }
        
        // 再添加温度值（2字节，高字节在前，除以0.01）
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

      return data;
    } catch (e) {
      print('❌ 获取相温度数据失败: $e');
      return List.filled(14, 0); // 返回14个0（4个温度值：左外4字节+中外2字节+右外4字节+中内4字节=14字节，中外跳过状态）
    }
  }

  /// 获取环境参数数据
  /// 上/中/下温度：只有数据值(2字节)，跳过状态
  /// 湿度/压力：状态(2字节) + 数据值(2字节) = 4字节
  List<int> _getEnvironmentData(dynamic snapshot, Map<String, dynamic> nodeSettings, int address, AlertInfo? alerts) {
    final data = <int>[];

    try {
      final upperCorr = nodeSettings['upperTempCorrection'] as double? ?? 0.0;
      final middleCorr = nodeSettings['envTempCorrection'] as double? ?? 0.0;
      final lowerCorr = nodeSettings['lowerTempCorrection'] as double? ?? 0.0;
      final humidityCorr = nodeSettings['humidityCorrection'] as double? ?? 0.0;

      double upperTemp = (snapshot.temperature ?? 25) + upperCorr;
      double middleTemp = (snapshot.temperature ?? 25) + middleCorr;
      double lowerTemp = (snapshot.temperature ?? 25) + lowerCorr;
      double correctedHumidity = ((snapshot.humidity ?? 0) + humidityCorr).clamp(0, 100);
      final pressure = snapshot.pressureKpa ?? 0;

      // 根据地址返回对应的数据和状态（只传输页面显示的参数：上温度、中温度、下温度、湿度、压力）
      final offset = (address - 0x0030) ~/ 2; // 每个参数占2个寄存器
      double value = 0;
      int status = 0;

      switch (offset) {
        case 0: // 上温度
          value = upperTemp;
          status = _getPhaseTemperatureStatus(alerts, 'A'); // 上温度对应A相状态
          break;
        case 1: // 中温度
          value = middleTemp;
          status = _getPhaseTemperatureStatus(alerts, 'B'); // 中温度对应B相状态
          break;
        case 2: // 下温度
          value = lowerTemp;
          status = _getPhaseTemperatureStatus(alerts, 'C'); // 下温度对应C相状态
          break;
        case 3: // 湿度
          value = correctedHumidity;
          status = _getSensorStatusValue(alerts, 'HUMIDITY');
          break;
        case 4: // 压力
          value = pressure;
          status = _getSensorStatusValue(alerts, 'PRESSURE');
          break;
        default:
          value = 0;
          status = 0;
      }

      // 跳过上/中/下温度的状态（offset=0,1,2对应上/中/下温度）
      if (offset != 0 && offset != 1 && offset != 2) {
        // 先添加状态（2字节，高字节在前）
        data.add((status >> 8) & 0xFF);
        data.add(status & 0xFF);
      }
      
      // 再添加数据值（2字节，高字节在前，乘以100）
      final raw = (value * 100).round();
      data.add((raw >> 8) & 0xFF);
      data.add(raw & 0xFF);

      return data;
    } catch (e) {
      print('❌ 获取环境参数数据失败: $e');
      return [0, 0, 0, 0];
    }
  }

  /// 获取烟雾和气体数据（白烟、黑烟、H2、CO）
  /// 每个参数格式：状态(2字节) + 数据值(2字节) = 4字节
  List<int> _getSmokeAndGasData(dynamic snapshot, Map<String, dynamic> nodeSettings, int address, AlertInfo? alerts) {
    final data = <int>[];

    try {
      // 计算烟雾浓度
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

      final offset = (address - 0x003C) ~/ 2; // 每个参数占2个寄存器
      double value = 0;
      int status = 0;

      switch (offset) {
        case 0: // 白烟浓度
          status = _getSensorStatusValue(alerts, 'SMOKE');
          if (snapshot.smokeChannelA != null) {
            final aA = (snapshot.smokeCalibA ?? 0).toDouble();
            final tA = (snapshot.smokeThreshA ?? 568).toDouble();
            value = _calculateSmokeConcentration(snapshot.smokeChannelA!.toDouble(), aA, tA);
          }
          // 先添加状态（2字节，高字节在前）
          data.add((status >> 8) & 0xFF);
          data.add(status & 0xFF);
          // 再添加数据值（2字节，高字节在前，乘以1000）
          final whiteSmokeRaw = (value * 1000).round().clamp(0, 65535);
          data.add((whiteSmokeRaw >> 8) & 0xFF);
          data.add(whiteSmokeRaw & 0xFF);
          break;
        case 1: // 黑烟浓度
          status = _getSensorStatusValue(alerts, 'SMOKE');
          if (snapshot.smokeChannelB != null) {
            final aB = (snapshot.smokeCalibB ?? 0).toDouble();
            final tB = (snapshot.smokeThreshB ?? 568).toDouble();
            value = _calculateSmokeConcentration(snapshot.smokeChannelB!.toDouble(), aB, tB);
          }
          // 先添加状态（2字节，高字节在前）
          data.add((status >> 8) & 0xFF);
          data.add(status & 0xFF);
          // 再添加数据值（2字节，高字节在前，乘以1000）
          final blackSmokeRaw = (value * 1000).round().clamp(0, 65535);
          data.add((blackSmokeRaw >> 8) & 0xFF);
          data.add(blackSmokeRaw & 0xFF);
          break;
        case 2: // H2浓度
          status = _getSensorStatusValue(alerts, 'H2');
          final h2 = snapshot.h2Percentage?.round() ?? 0;
          // 先添加状态（2字节，高字节在前）
          data.add((status >> 8) & 0xFF);
          data.add(status & 0xFF);
          // 再添加数据值（2字节，高字节在前，H2百分比值）
          data.add(h2.clamp(0, 255));
          data.add(0); // 填充字节
          break;
        case 3: // CO浓度
          status = _getSensorStatusValue(alerts, 'CO');
          final rawCo = snapshot.coPpm?.toDouble() ?? 0;
          final coConcentration = (rawCo < 0 || rawCo > 10000) ? 0 : rawCo;
          // 先添加状态（2字节，高字节在前）
          data.add((status >> 8) & 0xFF);
          data.add(status & 0xFF);
          // 再添加数据值（2字节，高字节在前，ppm值）
          final coRaw = coConcentration.round();
          data.add((coRaw >> 8) & 0xFF);
          data.add(coRaw & 0xFF);
          break;
        default:
          data.add(0);
          data.add(0);
          data.add(0);
          data.add(0);
      }

      return data;
    } catch (e) {
      print('❌ 获取烟雾和气体数据失败: $e');
      return [0, 0, 0, 0];
    }
  }

  /// 获取烟雾比值和外部温度
  /// 每个参数格式：状态(2字节) + 数据值(2字节) = 4字节
  List<int> _getSmokeRatioAndExtTemp(dynamic snapshot, Map<String, dynamic> nodeSettings, int address, AlertInfo? alerts) {
    final data = <int>[];

    try {
      final offset = (address - 0x005C) ~/ 2; // 每个参数占2个寄存器
      int status = _getSensorStatusValue(alerts, 'SMOKE'); // 烟雾比值和外部温度都使用烟雾状态

      if (offset == 0) {
        // 烟雾比值
        // SensorData中没有smokeRatio字段，使用默认值0
        final ratio = 0;
        // 先添加状态（2字节，高字节在前）
        data.add((status >> 8) & 0xFF);
        data.add(status & 0xFF);
        // 再添加数据值（2字节，高字节在前）
        data.add(ratio.clamp(0, 255));
        data.add(0); // 填充字节
      } else if (offset == 1) {
        // 外部温度
        final extTemp = snapshot.smokeExternalTempC ?? 0;
        // 先添加状态（2字节，高字节在前）
        data.add((status >> 8) & 0xFF);
        data.add(status & 0xFF);
        // 再添加数据值（2字节，低字节在前，乘以100）
        final extTempRaw = (extTemp * 100).round().clamp(-32768, 32767);
        final signedExtTempRaw = extTempRaw < 0 ? (extTempRaw + 65536) : extTempRaw;
        data.add(signedExtTempRaw & 0xFF);
        data.add((signedExtTempRaw >> 8) & 0xFF);
      }

      return data;
    } catch (e) {
      print('❌ 获取烟雾比值和外部温度失败: $e');
      return [0, 0, 0, 0];
    }
  }

  /// 获取相温度状态值（根据具体预警/故障类型返回对应的状态码）
  /// 正常=0，其他返回RS485Protocol中定义的故障码
  int _getPhaseTemperatureStatus(AlertInfo? alerts, String phase) {
    if (alerts == null) return 0; // 正常

    // 查找该相相关的预警和故障
    final phaseWarnings = alerts.warnings.where((w) => w.contains('${phase}相')).toList();
    final phaseFaults = alerts.faults.where((f) => f.contains('${phase}相')).toList();
    
    // 优先返回故障码（故障优先级高于预警）
    for (final fault in phaseFaults) {
      final faultCode = RS485Protocol.getFaultCode(fault);
      if (faultCode != null) return faultCode;
    }
    
    // 返回预警码
    for (final warning in phaseWarnings) {
      final faultCode = RS485Protocol.getFaultCode(warning);
      if (faultCode != null) return faultCode;
    }
    
    // 如果没有该相的具体预警/故障，检查是否有通用的温度预警/故障
    final tempFaults = alerts.faults.where((f) => f.contains('温度故障')).toList();
    if (tempFaults.isNotEmpty) {
      final faultCode = RS485Protocol.getFaultCode(tempFaults.first);
      if (faultCode != null) return faultCode;
    }
    
    final tempWarnings = alerts.warnings.where((w) => w.contains('温度预警')).toList();
    if (tempWarnings.isNotEmpty) {
      final faultCode = RS485Protocol.getFaultCode(tempWarnings.first);
      if (faultCode != null) return faultCode;
    }
    
    return 0; // 正常
  }

  /// 获取传感器状态值（根据具体预警/故障类型返回对应的状态码）
  /// 正常=0，其他返回RS485Protocol中定义的故障码
  /// sensorType: 'CO', 'H2', 'SMOKE', 'HUMIDITY', 'PRESSURE'
  int _getSensorStatusValue(AlertInfo? alerts, String sensorType) {
    if (alerts == null) return 0; // 正常

    // 根据传感器类型匹配预警和故障信息
    String warningKeyword;
    String faultKeyword;
    
    switch (sensorType) {
      case 'CO':
        warningKeyword = '一氧化碳预警';
        faultKeyword = '一氧化碳故障';
        break;
      case 'H2':
        warningKeyword = '氢气预警';
        faultKeyword = '氢气故障';
        break;
      case 'SMOKE':
        warningKeyword = '烟雾预警';
        faultKeyword = '烟雾故障';
        break;
      case 'HUMIDITY':
        warningKeyword = '湿度预警';
        faultKeyword = '湿度故障';
        break;
      case 'PRESSURE':
        warningKeyword = '压力预警';
        faultKeyword = '压力故障';
        break;
      default:
        return 0;
    }

    // 优先返回故障码（故障优先级高于预警）
    final faults = alerts.faults.where((f) => f.contains(faultKeyword)).toList();
    if (faults.isNotEmpty) {
      final faultCode = RS485Protocol.getFaultCode(faults.first);
      if (faultCode != null) return faultCode;
    }
    
    // 返回预警码
    final warnings = alerts.warnings.where((w) => w.contains(warningKeyword)).toList();
    if (warnings.isNotEmpty) {
      final faultCode = RS485Protocol.getFaultCode(warnings.first);
      if (faultCode != null) return faultCode;
    }

    return 0; // 正常
  }

  /// 根据关键词列表从预警/故障中查找对应的状态码
  /// 优先返回故障码，其次返回预警码
  int _getStatusFromAlerts(AlertInfo? alerts, List<String> keywords) {
    if (alerts == null) return 0; // 正常

    // 优先查找故障
    for (final fault in alerts.faults) {
      if (keywords.any((keyword) => fault.contains(keyword))) {
        final faultCode = RS485Protocol.getFaultCode(fault);
        if (faultCode != null) return faultCode;
      }
    }
    
    // 其次查找预警
    for (final warning in alerts.warnings) {
      if (keywords.any((keyword) => warning.contains(keyword))) {
        final faultCode = RS485Protocol.getFaultCode(warning);
        if (faultCode != null) return faultCode;
      }
    }

    return 0; // 正常
  }

  /// 将故障码转换为简单状态值：0=正常，1=预警，2=故障
  /// 故障码范围：0xE0-0xEF为预警，0xF0-0xFF为故障
  int _getSimpleStatusFromFaultCode(int faultCode) {
    if (faultCode == 0) return 0; // 正常
    if (faultCode >= 0xE0 && faultCode < 0xF0) return 1; // 预警
    if (faultCode >= 0xF0) return 2; // 故障
    return 0; // 默认正常
  }

  /// 获取简单状态值（统一为36寄存器格式）
  /// 返回：0=正常，1=预警，2=故障
  int _getSimpleStatusValue(AlertInfo? alerts, String phase) {
    if (alerts == null) return 0; // 正常

    // 查找该相相关的预警和故障（排除局放值故障）
    final phaseWarnings = alerts.warnings.where((w) => 
      w.contains('${phase}相') && !w.contains('局放值高')
    ).toList();
    final phaseFaults = alerts.faults.where((f) => 
      f.contains('${phase}相') && !f.contains('局放值高')
    ).toList();
    
    // 优先返回故障（故障优先级高于预警）
    if (phaseFaults.isNotEmpty) {
      return 2; // 故障
    }
    
    // 返回预警
    if (phaseWarnings.isNotEmpty) {
      return 1; // 预警
    }
    
    // 如果没有该相的具体预警/故障，检查是否有通用的温度预警/故障（排除局放值）
    final tempFaults = alerts.faults.where((f) => 
      f.contains('温度故障') && !f.contains('局放值高')
    ).toList();
    if (tempFaults.isNotEmpty) {
      return 2; // 故障
    }
    
    final tempWarnings = alerts.warnings.where((w) => 
      w.contains('温度预警') && !w.contains('局放值高')
    ).toList();
    if (tempWarnings.isNotEmpty) {
      return 1; // 预警
    }
    
    return 0; // 正常
  }

  /// 检查是否有局放值故障（针对特定相和温度索引）
  /// tempIndex: 0=左外，1=中外，2=右外，3=中内
  bool _hasPartialDischargeFault(AlertInfo? alerts, String phase, int tempIndex) {
    if (alerts == null) return false;
    
    // 局放值故障只影响左外和右外（tempIndex 0和2）
    if (tempIndex != 0 && tempIndex != 2) return false;
    
    // 查找该相的局放值故障
    final partialDischargeFaults = alerts.faults.where((f) => 
      f.contains('${phase}相') && f.contains('局放值高')
    ).toList();
    
    if (partialDischargeFaults.isEmpty) return false;
    
    // 检查是左外还是右外
    if (tempIndex == 0) {
      // 左外
      return partialDischargeFaults.any((f) => f.contains('左外'));
    } else if (tempIndex == 2) {
      // 右外
      return partialDischargeFaults.any((f) => f.contains('右外'));
    }
    
    return false;
  }

  /// 发送Modbus TCP响应
  void _sendResponse(Socket client, int transactionId, int unitId, int functionCode, List<int> data) {
    try {
      // Modbus TCP响应格式（功能码03）：
      // MBAP头（6字节）+ PDU（Unit ID + Function Code + Byte Count + Register Values）
      // 注意：Modbus寄存器是16位（2字节），所以字节数 = 寄存器数 * 2
      final byteCount = data.length;
      final pduLength = 1 + 1 + 1 + byteCount; // Unit ID + Function Code + Byte Count + Data
      final mbapLength = pduLength;

      final response = Uint8List(6 + pduLength);

      // MBAP头
      response[0] = (transactionId >> 8) & 0xFF;
      response[1] = transactionId & 0xFF;
      response[2] = 0x00; // Protocol ID
      response[3] = 0x00;
      response[4] = (mbapLength >> 8) & 0xFF;
      response[5] = mbapLength & 0xFF;

      // PDU
      response[6] = unitId;
      response[7] = functionCode;
      response[8] = byteCount; // 字节数
      for (int i = 0; i < data.length; i++) {
        response[9 + i] = data[i];
      }

      client.add(response);
      client.flush();

      print('📤 已发送响应: 节点=$unitId, 字节数=$byteCount, 寄存器数=${byteCount ~/ 2}');
    } catch (e) {
      print('❌ 发送响应失败: $e');
    }
  }

  /// 发送错误响应
  void _sendErrorResponse(Socket client, int transactionId, int unitId, int functionCode, int errorCode) {
    try {
      final pduLength = 1 + 1 + 1; // Unit ID + Error Function Code + Exception Code
      final mbapLength = pduLength;

      final response = Uint8List(6 + pduLength);

      // MBAP头
      response[0] = (transactionId >> 8) & 0xFF;
      response[1] = transactionId & 0xFF;
      response[2] = 0x00;
      response[3] = 0x00;
      response[4] = (mbapLength >> 8) & 0xFF;
      response[5] = mbapLength & 0xFF;

      // PDU（错误响应）
      response[6] = unitId;
      response[7] = functionCode | 0x80; // 错误功能码 = 原功能码 | 0x80
      response[8] = errorCode; // 异常码

      client.add(response);
      client.flush();

      print('📤 已发送错误响应: 节点=$unitId, 错误码=$errorCode');
    } catch (e) {
      print('❌ 发送错误响应失败: $e');
    }
  }

  /// 获取服务器运行状态
  bool get isRunning => _isRunning;

  /// 获取监听端口
  int get listenPort => _listenPort;

  /// 获取当前连接的客户端数量
  int get clientCount => _clients.length;

  /// 将快照转换为SensorData（用于NodeDataCalculator）
  SensorData? _snapshotToSensorData(dynamic snapshot, int nodeId) {
    try {
      return SensorData(
        nodeId: nodeId,
        sensorType: snapshot.sensorType ?? 0,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        temperature: snapshot.temperature,
        humidity: snapshot.humidity,
        coPpm: snapshot.coPpm,
        h2Percentage: snapshot.h2Percentage,
        pressureKpa: snapshot.pressureKpa,
        pressureTempC: snapshot.pressureTempC,
        smokeStatus: snapshot.smokeStatus,
        smokeExternalTempC: snapshot.smokeExternalTempC,
        smokeChannelA: snapshot.smokeChannelA,
        smokeChannelB: snapshot.smokeChannelB,
        smokeCalibA: snapshot.smokeCalibA,
        smokeCalibB: snapshot.smokeCalibB,
        smokeThreshA: snapshot.smokeThreshA,
        smokeThreshB: snapshot.smokeThreshB,
        pt100Temperatures: snapshot.pt100Temperatures,
        fanStatus: snapshot.fanStatus,
        fanTimer: snapshot.fanTimer,
        stCoLen: snapshot.stCoLen,
        stSmokeLen: snapshot.stSmokeLen,
        stH2Len: snapshot.stH2Len,
        stPt100Len: snapshot.stPt100Len,
        stThLen: snapshot.stThLen,
        stPressureLen: snapshot.stPressureLen,
      );
    } catch (e) {
      print('❌ 转换快照为SensorData失败: $e');
      return null;
    }
  }

  /// 将快照转换为NodeData
  NodeData? _snapshotToNodeData(dynamic snapshot, int nodeId) {
    try {
      return NodeData(
        nodeId: nodeId,
        temperature: snapshot.temperature,
        humidity: snapshot.humidity,
        coPpm: snapshot.coPpm,
        h2Percentage: snapshot.h2Percentage,
        pressureKpa: snapshot.pressureKpa,
        pressureTempC: snapshot.pressureTempC,
        smokeAlarm: snapshot.smokeStatus == 1,
        smokeRatio: null, // SensorData中没有smokeRatio字段，设置为null
        smokeAlarmCount: snapshot.smokeStatus,
        smokeExternalTempC: snapshot.smokeExternalTempC,
        smokeChannelA: snapshot.smokeChannelA,
        smokeChannelB: snapshot.smokeChannelB,
        pt100Temperatures: snapshot.pt100Temperatures != null 
            ? (jsonDecode(snapshot.pt100Temperatures!) as List).cast<num>().map((e) => e.toDouble()).toList()
            : null,
        lastUpdate: DateTime.now().toIso8601String(),
        lastUpdateTimestamp: DateTime.now().millisecondsSinceEpoch,
        stCoLen: snapshot.coPpm != null ? 1 : 0,
        stSmokeLen: (snapshot.smokeChannelA != null || snapshot.smokeChannelB != null) ? 1 : 0,
        stH2Len: snapshot.h2Percentage != null ? 1 : 0,
        stPt100Len: snapshot.pt100Temperatures != null ? 1 : 0,
        stThLen: (snapshot.temperature != null || snapshot.humidity != null) ? 1 : 0,
        stPressureLen: snapshot.pressureKpa != null ? 1 : 0,
      );
    } catch (e) {
      print('❌ 转换快照为NodeData失败: $e');
      return null;
    }
  }

  /// 获取相温度单个寄存器的值（sensor_flutter67专用，使用与页面显示一致的数据）
  /// offset: 相对于相起始地址的偏移（0-6）
  /// 寄存器映射：0=左外状态, 1=左外值, 2=中外值, 3=右外状态, 4=右外值, 5=中内状态, 6=中内值
  List<int> _getPhaseTempRegisterValue67(Map<String, dynamic> displayData, Map<String, dynamic> nodeSettings, int nodeId, AlertInfo? alerts, String phase, int offset) {
    final data = <int>[];
    
    try {
      // 从displayData获取相温度数据（与页面显示完全一致）
      final phaseTemps = displayData['phase$phase'] as List<double>?;
      if (phaseTemps == null || phaseTemps.length < 4) {
        return [0, 0];
      }

      // 页面显示的4个值：左外、中外、右外、中内
      final leftOuter = phaseTemps[0];   // 左外
      final middleOuter = phaseTemps[1]; // 中外
      final rightOuter = phaseTemps[2];  // 右外
      final middleInner = phaseTemps[3]; // 中内

      // 获取该相的温度状态
      // 检查是否有局放值故障（用于左外和右外）
      final hasPartialDischargeLeft = _hasPartialDischargeFault(alerts, phase, 0);
      final hasPartialDischargeRight = _hasPartialDischargeFault(alerts, phase, 2);
      final statusLeft = hasPartialDischargeLeft ? 3 : _getSimpleStatusValue(alerts, phase);
      final statusRight = hasPartialDischargeRight ? 3 : _getSimpleStatusValue(alerts, phase);
      final statusInner = _getSimpleStatusValue(alerts, phase);

      // 根据offset返回对应的寄存器值
      // 0=左外状态, 1=左外值, 2=中外值, 3=右外状态, 4=右外值, 5=中内状态, 6=中内值
      if (offset == 0) {
        // 左外温度状态（转换为简单状态值：0=正常，1=预警，2=故障，3=局放值故障）
        data.add(0); // 高字节为0
        data.add(statusLeft); // 低字节为状态值
      } else if (offset == 1) {
        // 左外温度值（应用异常值过滤）
        final filteredTemp = _filterTemperatureValue(nodeId, phase, 0, leftOuter);
        int raw;
        if (filteredTemp == -999.0) {
          raw = 0x8066;
        } else {
          final signedRaw = (filteredTemp / 0.01).round();
          raw = signedRaw < 0 ? (signedRaw + 65536) : signedRaw;
        }
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else if (offset == 2) {
        // 中外温度值（无状态，应用异常值过滤）
        final filteredTemp = _filterTemperatureValue(nodeId, phase, 1, middleOuter);
        int raw;
        if (filteredTemp == -999.0) {
          raw = 0x8066;
        } else {
          final signedRaw = (filteredTemp / 0.01).round();
          raw = signedRaw < 0 ? (signedRaw + 65536) : signedRaw;
        }
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else if (offset == 3) {
        // 右外温度状态（转换为简单状态值：0=正常，1=预警，2=故障，3=局放值故障）
        data.add(0); // 高字节为0
        data.add(statusRight); // 低字节为状态值
      } else if (offset == 4) {
        // 右外温度值（应用异常值过滤）
        final filteredTemp = _filterTemperatureValue(nodeId, phase, 2, rightOuter);
        int raw;
        if (filteredTemp == -999.0) {
          raw = 0x8066;
        } else {
          final signedRaw = (filteredTemp / 0.01).round();
          raw = signedRaw < 0 ? (signedRaw + 65536) : signedRaw;
        }
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else if (offset == 5) {
        // 中内温度状态（转换为简单状态值：0=正常，1=预警，2=故障）
        data.add(0); // 高字节为0
        data.add(statusInner); // 低字节为状态值
      } else if (offset == 6) {
        // 中内温度值（应用异常值过滤）
        final filteredTemp = _filterTemperatureValue(nodeId, phase, 3, middleInner);
        int raw;
        if (filteredTemp == -999.0) {
          raw = 0x8066;
        } else {
          final signedRaw = (filteredTemp / 0.01).round();
          raw = signedRaw < 0 ? (signedRaw + 65536) : signedRaw;
        }
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else {
        data.add(0);
        data.add(0);
      }

      return data;
    } catch (e) {
      print('❌ 获取相温度寄存器值失败: $e');
      return [0, 0];
    }
  }

  /// 获取相温度单个寄存器的值（sensor_flutter67专用）- 旧方法保留用于兼容
  /// offset: 相对于相起始地址的偏移（0-6）
  /// 寄存器映射：0=左外状态, 1=左外值, 2=中外值, 3=右外状态, 4=右外值, 5=中内状态, 6=中内值
  List<int> _getPhaseTempRegisterValue67Old(dynamic snapshot, Map<String, dynamic> nodeSettings, int nodeId, AlertInfo? alerts, String phase, int offset) {
    final data = <int>[];
    
    try {
      if (snapshot.pt100Temperatures == null) {
        return [0, 0];
      }

      final temps = jsonDecode(snapshot.pt100Temperatures!) as List;
      if (temps.length < 9) {
        return [0, 0];
      }

      final pt100Corrections = nodeSettings['pt100Corrections'] as List<dynamic>? ?? List.filled(10, 0.0);
      final upperCorr = nodeSettings['upperTempCorrection'] as double? ?? 0.0;
      final middleCorr = nodeSettings['envTempCorrection'] as double? ?? 0.0;
      final lowerCorr = nodeSettings['lowerTempCorrection'] as double? ?? 0.0;

      // 应用误差修正
      final corrected = List<double>.generate(
        temps.length,
        (i) {
          final base = temps[i] as double;
          if (base == -999) return -999;
          final delta = i < pt100Corrections.length ? (pt100Corrections[i] as double? ?? 0.0) : 0.0;
          return base + delta;
        },
      );

      // 更新上中下温度
      double upperTemp = (snapshot.temperature ?? 25) + upperCorr;
      double middleTemp = (snapshot.temperature ?? 25) + middleCorr;
      double lowerTemp = (snapshot.temperature ?? 25) + lowerCorr;

      if (nodeId == 1 && corrected.length >= 11) {
        upperTemp = corrected[10] + upperCorr;
      } else if (corrected.length >= 10) {
        upperTemp = corrected[9] + upperCorr;
      }

      if (corrected.length >= 12 && corrected[11] != -999) {
        middleTemp = corrected[11] + middleCorr;
      }

      // 根据phase参数确定是哪个相
      int phaseOffset;
      double envTemp;
      if (phase == 'A') {
        phaseOffset = 0;
        envTemp = upperTemp;
      } else if (phase == 'B') {
        phaseOffset = 3;
        envTemp = middleTemp;
      } else {
        phaseOffset = 6;
        envTemp = lowerTemp;
      }

      // 获取该相的3个外温度值（左外、中外、右外）
      final aL = corrected[phaseOffset + 0];
      final aM = corrected[phaseOffset + 1];
      final aR = corrected[phaseOffset + 2];

      // 计算三相平均值（用于内温度计算）
      final leftAvg = (corrected[0] + corrected[3] + corrected[6]) / 3;
      final middleAvg = (corrected[1] + corrected[4] + corrected[7]) / 3;
      final rightAvg = (corrected[2] + corrected[5] + corrected[8]) / 3;

      // 获取K1、K2参数
      final k1 = phaseOffset == 0
          ? (nodeSettings['aK1'] as double? ?? 6.42)
          : phaseOffset == 3
              ? (nodeSettings['bK1'] as double? ?? 6.42)
              : (nodeSettings['cK1'] as double? ?? 6.42);
      final k2 = phaseOffset == 0
          ? (nodeSettings['aK2'] as double? ?? 2.5)
          : phaseOffset == 3
              ? (nodeSettings['bK2'] as double? ?? 2.5)
              : (nodeSettings['cK2'] as double? ?? 2.5);

      // 计算内温度
      double _calculateInnerTemp(double xi, double x0i, double xia, double k1, double k2) {
        if (xi == -999) return -999;
        if (xi < x0i) return xi;
        final deltaEnv = (xi - x0i) < 0 ? 0 : (xi - x0i);
        final deltaPhaseAvg = (xi - xia) < 0 ? 0 : (xi - xia);
        return xi + k1 * deltaEnv + k2 * deltaPhaseAvg;
      }

      final aLInner = _calculateInnerTemp(aL, envTemp, leftAvg, k1, k2);
      final aMInner = _calculateInnerTemp(aM, envTemp, middleAvg, k1, k2);
      final aRInner = _calculateInnerTemp(aR, envTemp, rightAvg, k1, k2);

      // 获取该相的温度状态
      // 检查是否有局放值故障（用于左外和右外）
      final hasPartialDischargeLeft = _hasPartialDischargeFault(alerts, phase, 0);
      final hasPartialDischargeRight = _hasPartialDischargeFault(alerts, phase, 2);
      final statusLeft = hasPartialDischargeLeft ? 3 : _getSimpleStatusValue(alerts, phase);
      final statusRight = hasPartialDischargeRight ? 3 : _getSimpleStatusValue(alerts, phase);
      final statusInner = _getSimpleStatusValue(alerts, phase);
      
      // 根据offset返回对应的寄存器值
      // 0=左外状态, 1=左外值, 2=中外值, 3=右外状态, 4=右外值, 5=中内状态, 6=中内值
      if (offset == 0) {
        // 左外温度状态（转换为简单状态值：0=正常，1=预警，2=故障，3=局放值故障）
        data.add(0); // 高字节为0
        data.add(statusLeft); // 低字节为状态值
      } else if (offset == 1) {
        // 左外温度值（应用异常值过滤）
        final filteredTemp = _filterTemperatureValue(nodeId, phase, 0, aL);
        int raw;
        if (filteredTemp == -999.0) {
          raw = 0x8066;
        } else {
          final signedRaw = (filteredTemp / 0.01).round();
          raw = signedRaw < 0 ? (signedRaw + 65536) : signedRaw;
        }
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else if (offset == 2) {
        // 中外温度值（无状态，应用异常值过滤）
        final filteredTemp = _filterTemperatureValue(nodeId, phase, 1, aM);
        int raw;
        if (filteredTemp == -999.0) {
          raw = 0x8066;
        } else {
          final signedRaw = (filteredTemp / 0.01).round();
          raw = signedRaw < 0 ? (signedRaw + 65536) : signedRaw;
        }
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else if (offset == 3) {
        // 右外温度状态（转换为简单状态值：0=正常，1=预警，2=故障，3=局放值故障）
        data.add(0); // 高字节为0
        data.add(statusRight); // 低字节为状态值
      } else if (offset == 4) {
        // 右外温度值（应用异常值过滤）
        final filteredTemp = _filterTemperatureValue(nodeId, phase, 2, aR);
        int raw;
        if (filteredTemp == -999.0) {
          raw = 0x8066;
        } else {
          final signedRaw = (filteredTemp / 0.01).round();
          raw = signedRaw < 0 ? (signedRaw + 65536) : signedRaw;
        }
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else if (offset == 5) {
        // 中内温度状态（转换为简单状态值：0=正常，1=预警，2=故障）
        data.add(0); // 高字节为0
        data.add(statusInner); // 低字节为状态值
      } else if (offset == 6) {
        // 中内温度值（应用异常值过滤）
        final filteredTemp = _filterTemperatureValue(nodeId, phase, 3, aMInner);
        int raw;
        if (filteredTemp == -999.0) {
          raw = 0x8066;
        } else {
          final signedRaw = (filteredTemp / 0.01).round();
          raw = signedRaw < 0 ? (signedRaw + 65536) : signedRaw;
        }
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else {
        data.add(0);
        data.add(0);
      }

      return data;
    } catch (e) {
      print('❌ 获取相温度寄存器值失败: $e');
      return [0, 0];
    }
  }

  /// 过滤温度异常值
  /// nodeId: 节点ID
  /// phase: 相（A/B/C/ENV）
  /// channelIndex: 通道索引（0=左外/上温度，1=中外/中温度，2=右外/下温度，3=中内）
  /// rawTemp: 原始温度值
  /// 返回：过滤后的温度值
  double _filterTemperatureValue(int nodeId, String phase, int channelIndex, double rawTemp) {
    // 1. 处理开路值
    if (rawTemp == -999.0) {
      return -999.0;
    }
    
    // 2. 基本范围检查（只检查下限，去掉上限）
    if (rawTemp < _tempMinValue) {
      print('⚠️ 温度值超出范围: 节点=$nodeId, 相=$phase, 通道=$channelIndex, 原始值=$rawTemp°C, 最小范围=$_tempMinValue°C');
      // 返回历史值或默认值
      final historyKey = '${nodeId}_${phase}_$channelIndex';
      final history = _tempHistoryCache[historyKey];
      if (history != null && history.isNotEmpty) {
        final lastValidValue = history.last;
        print('📊 使用历史值: $lastValidValue°C');
        return lastValidValue;
      }
      return 25.0; // 默认值
    }
    
    // 3. 获取历史记录
    final historyKey = '${nodeId}_${phase}_$channelIndex';
    final history = _tempHistoryCache.putIfAbsent(historyKey, () => <double>[]);
    
    // 4. 如果没有历史数据，直接使用当前值
    if (history.isEmpty) {
      history.add(rawTemp);
      // 限制历史记录长度（最多保留10个）
      if (history.length > 10) {
        history.removeAt(0);
      }
      return rawTemp;
    }
    
    // 5. 获取最近的有效值
    final lastValue = history.last;
    
    // 6. 检测异常跳变
    final absDiff = (rawTemp - lastValue).abs();
    if (absDiff > _tempJumpThreshold) {
      print('⚠️ 温度异常跳变检测: 节点=$nodeId, 相=$phase, 通道=$channelIndex, 从$lastValue°C跳变到$rawTemp°C (变化=${absDiff.toStringAsFixed(1)}°C)');
      // 使用上一次的有效值
      history.add(lastValue); // 继续使用上次的值
      // 限制历史记录长度
      if (history.length > 10) {
        history.removeAt(0);
      }
      return lastValue;
    }
    
    // 7. 正常变化，使用当前值
    history.add(rawTemp);
    // 限制历史记录长度
    if (history.length > 10) {
      history.removeAt(0);
    }
    return rawTemp;
  }

  /// 获取环境参数单个寄存器的值（sensor_flutter67专用，使用与页面显示一致的数据）
  /// offset: 相对于环境参数起始地址的偏移（0-6）
  /// 寄存器映射：0=上温度值, 1=中温度值, 2=下温度值, 3=湿度状态, 4=湿度值, 5=压力状态, 6=压力值
  List<int> _getEnvironmentRegisterValue67(Map<String, dynamic> displayData, Map<String, dynamic> nodeSettings, AlertInfo? alerts, int offset, int nodeId) {
    final data = <int>[];
    
    try {
      // 从displayData获取环境参数（与页面显示完全一致）
      final upperTemp = displayData['upperTemp'] as double;
      final middleTemp = displayData['middleTemp'] as double;
      final lowerTemp = displayData['lowerTemp'] as double;
      final correctedHumidity = displayData['humidity'] as double? ?? 0.0;
      final pressure = displayData['pressure'] as double? ?? 0.0;

      if (offset == 0) {
        // 上温度值（无状态，应用异常值过滤）
        final filteredTemp = _filterTemperatureValue(nodeId, 'ENV', 0, upperTemp);
        final raw = (filteredTemp * 100).round();
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else if (offset == 1) {
        // 中温度值（无状态，应用异常值过滤）
        final filteredTemp = _filterTemperatureValue(nodeId, 'ENV', 1, middleTemp);
        final raw = (filteredTemp * 100).round();
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else if (offset == 2) {
        // 下温度值（无状态，应用异常值过滤）
        final filteredTemp = _filterTemperatureValue(nodeId, 'ENV', 2, lowerTemp);
        final raw = (filteredTemp * 100).round();
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else if (offset == 3) {
        // 湿度状态（转换为简单状态值：0=正常，1=预警，2=故障）
        final statusFaultCode = _getSensorStatusValue(alerts, 'HUMIDITY');
        final statusValue = _getSimpleStatusFromFaultCode(statusFaultCode);
        data.add(0); // 高字节为0
        data.add(statusValue); // 低字节为状态值
      } else if (offset == 4) {
        // 湿度值
        final raw = (correctedHumidity * 100).round();
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else if (offset == 5) {
        // 压力状态（转换为简单状态值：0=正常，1=预警，2=故障）
        final statusFaultCode = _getSensorStatusValue(alerts, 'PRESSURE');
        final statusValue = _getSimpleStatusFromFaultCode(statusFaultCode);
        data.add(0); // 高字节为0
        data.add(statusValue); // 低字节为状态值
      } else if (offset == 6) {
        // 压力值
        final raw = (pressure * 100).round();
        data.add((raw >> 8) & 0xFF);
        data.add(raw & 0xFF);
      } else {
        data.add(0);
        data.add(0);
      }

      return data;
    } catch (e) {
      print('❌ 获取环境参数寄存器值失败: $e');
      return [0, 0];
    }
  }

  /// 获取烟雾和气体单个寄存器的值（sensor_flutter67专用，使用与页面显示一致的数据）
  /// offset: 相对于烟雾和气体起始地址的偏移（0-7）
  /// 寄存器映射：每个参数2个寄存器（状态+数值），0-1=白烟, 2-3=黑烟, 4-5=H2, 6-7=CO
  List<int> _getSmokeAndGasRegisterValue67(Map<String, dynamic> displayData, Map<String, dynamic> nodeSettings, AlertInfo? alerts, int offset) {
    final data = <int>[];
    
    try {
      // 从displayData获取烟雾和气体数据（与页面显示完全一致）
      final whiteSmoke = displayData['whiteSmoke'] as double;
      final blackSmoke = displayData['blackSmoke'] as double;
      final h2 = displayData['h2'] as double? ?? 0.0;
      final co = displayData['co'] as double? ?? 0.0;

      final paramIndex = offset ~/ 2; // 参数索引：0=白烟, 1=黑烟, 2=H2, 3=CO
      final isStatus = (offset % 2 == 0); // 是否为状态寄存器

      if (paramIndex == 0) {
        // 白烟
        final statusFaultCode = _getSensorStatusValue(alerts, 'SMOKE');
        if (isStatus) {
          // 状态寄存器（转换为简单状态值：0=正常，1=预警，2=故障）
          final statusValue = _getSimpleStatusFromFaultCode(statusFaultCode);
          data.add(0); // 高字节为0
          data.add(statusValue); // 低字节为状态值
        } else {
          // 使用与页面显示一致的白烟值
          final raw = (whiteSmoke * 1000).round().clamp(0, 65535);
          data.add((raw >> 8) & 0xFF);
          data.add(raw & 0xFF);
        }
      } else if (paramIndex == 1) {
        // 黑烟
        final statusFaultCode = _getSensorStatusValue(alerts, 'SMOKE');
        if (isStatus) {
          // 状态寄存器（转换为简单状态值：0=正常，1=预警，2=故障）
          final statusValue = _getSimpleStatusFromFaultCode(statusFaultCode);
          data.add(0); // 高字节为0
          data.add(statusValue); // 低字节为状态值
        } else {
          // 使用与页面显示一致的黑烟值
          final raw = (blackSmoke * 1000).round().clamp(0, 65535);
          data.add((raw >> 8) & 0xFF);
          data.add(raw & 0xFF);
        }
      } else if (paramIndex == 2) {
        // H2
        final statusFaultCode = _getSensorStatusValue(alerts, 'H2');
        if (isStatus) {
          // 状态寄存器（转换为简单状态值：0=正常，1=预警，2=故障）
          final statusValue = _getSimpleStatusFromFaultCode(statusFaultCode);
          data.add(0); // 高字节为0
          data.add(statusValue); // 低字节为状态值
        } else {
          // 使用与页面显示一致的H2值
          final h2Value = h2.round();
          data.add(h2Value.clamp(0, 255));
          data.add(0); // 填充字节
        }
      } else if (paramIndex == 3) {
        // CO
        final statusFaultCode = _getSensorStatusValue(alerts, 'CO');
        if (isStatus) {
          // 状态寄存器（转换为简单状态值：0=正常，1=预警，2=故障）
          final statusValue = _getSimpleStatusFromFaultCode(statusFaultCode);
          data.add(0); // 高字节为0
          data.add(statusValue); // 低字节为状态值
        } else {
          // 使用与页面显示一致的CO值（已处理异常值）
          final coRaw = co.round();
          data.add((coRaw >> 8) & 0xFF);
          data.add(coRaw & 0xFF);
        }
      } else {
        data.add(0);
        data.add(0);
      }

      return data;
    } catch (e) {
      print('❌ 获取烟雾和气体寄存器值失败: $e');
      return [0, 0];
    }
  }
}


