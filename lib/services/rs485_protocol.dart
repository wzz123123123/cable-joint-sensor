/// RS485协议定义和故障码体系
class RS485Protocol {
  // 传感器编号定义
  static const int SENSOR_CO = 0x02;           // CO传感器
  static const int SENSOR_SMOKE = 0x03;        // 感烟探测
  static const int SENSOR_H2 = 0x04;           // 氢气传感器
  static const int SENSOR_TEMP_HUMIDITY = 0x05; // 温湿度传感器
  static const int SENSOR_PRESSURE = 0x06;      // 压力传感器
  static const int SENSOR_FAN = 0x07;           // 风扇状态
  static const int SENSOR_PT100 = 0x08;         // PT100温度采集（保留兼容）
  static const int SENSOR_CABLE_TEMP = 0x09;    // 电缆接头测点温度（ABC相左中右外温度+内温度）
  static const int SENSOR_ENV_PARAMS = 0x0A;    // 防爆盒内环境参数（湿度、压力、白烟、黑烟、H2、CO、上中下温度、烟雾比值等）
  
  // 故障/预警类型码（用于故障报文）
  static const int TYPE_WARNING = 0x01;        // 预警
  static const int TYPE_FAULT = 0x02;           // 故障
  static const int TYPE_DATA = 0x00;            // 正常数据
  
  // 故障码定义（传感器编号 + 故障类型）
  // 温度相关
  static const int FAULT_TEMP_WARNING = 0xE0;   // 温度预警
  static const int FAULT_TEMP_FAULT = 0xF0;     // 温度故障
  static const int FAULT_TEMP_GROWTH = 0xE1;    // 温度增长预警
  static const int FAULT_PT100_OPEN = 0xF1;     // PT100开路故障
  
  // CO相关
  static const int FAULT_CO_WARNING = 0xE2;     // CO预警
  static const int FAULT_CO_FAULT = 0xF2;       // CO故障
  
  // H2相关
  static const int FAULT_H2_WARNING = 0xE3;     // H2预警
  static const int FAULT_H2_FAULT = 0xF3;        // H2故障
  
  // 压力相关
  static const int FAULT_PRESSURE_WARNING = 0xE4; // 压力预警
  static const int FAULT_PRESSURE_FAULT = 0xF4;   // 压力故障
  
  // 烟雾相关
  static const int FAULT_SMOKE_WARNING = 0xE5;    // 烟雾预警
  static const int FAULT_SMOKE_FAULT = 0xF5;      // 烟雾故障
  
  // 湿度相关
  static const int FAULT_HUMIDITY_WARNING = 0xE6; // 湿度预警
  static const int FAULT_HUMIDITY_FAULT = 0xF6;   // 湿度故障
  
  // 连接相关
  static const int FAULT_CONNECTION = 0xF7;        // 连接故障
  
  // 局放相关（PT100局放值高）
  static const int FAULT_PARTIAL_DISCHARGE = 0xF8; // 局放值高故障
  
  /// 根据预警/故障描述获取故障码
  static int? getFaultCode(String description) {
    if (description.contains('温度预警')) {
      if (description.contains('增长')) return FAULT_TEMP_GROWTH;
      return FAULT_TEMP_WARNING;
    }
    if (description.contains('温度故障')) return FAULT_TEMP_FAULT;
    if (description.contains('CO预警')) return FAULT_CO_WARNING;
    if (description.contains('CO故障') || description.contains('一氧化碳故障')) return FAULT_CO_FAULT;
    if (description.contains('氢气预警')) return FAULT_H2_WARNING;
    if (description.contains('氢气故障') || description.contains('H2故障')) return FAULT_H2_FAULT;
    if (description.contains('压力预警')) return FAULT_PRESSURE_WARNING;
    if (description.contains('压力故障')) return FAULT_PRESSURE_FAULT;
    if (description.contains('烟雾预警')) return FAULT_SMOKE_WARNING;
    if (description.contains('烟雾故障')) return FAULT_SMOKE_FAULT;
    if (description.contains('湿度预警')) return FAULT_HUMIDITY_WARNING;
    if (description.contains('湿度故障')) return FAULT_HUMIDITY_FAULT;
    if (description.contains('连接') || description.contains('未连接')) return FAULT_CONNECTION;
    if (description.contains('局放值高') || description.contains('局放')) return FAULT_PARTIAL_DISCHARGE;
    if (description.contains('PT100') && description.contains('开路')) return FAULT_PT100_OPEN;
    return null;
  }
  
  /// 创建485格式数据帧
  /// 格式：节点地址(1) + 传感器编号(1) + 数据长度(1) + 数据(n) + CRC16[7-0](1) + CRC16[15-8](1)
  static List<int> createRS485Frame({
    required int nodeId,
    required int sensorId,
    required List<int> data,
    required int Function(List<int>) calculateCRC16,
  }) {
    final frame = <int>[];
    frame.add(nodeId);           // 节点地址
    frame.add(sensorId);         // 传感器编号
    frame.add(data.length);      // 数据长度
    frame.addAll(data);          // 数据
    final crc = calculateCRC16(frame);
    frame.add(crc & 0xFF);       // CRC16[7-0] 低位在前
    frame.add((crc >> 8) & 0xFF); // CRC16[15-8] 高位在后
    return frame;
  }
  
  /// 将数值转换为2字节（高字节在前）
  static List<int> intTo2Bytes(int value) {
    return [(value >> 8) & 0xFF, value & 0xFF];
  }
  
  /// 将浮点数转换为2字节整数（乘以100，高字节在前）
  static List<int> floatTo2Bytes(double value) {
    final intValue = (value * 100).round();
    return intTo2Bytes(intValue);
  }

  /// 温度编码：开路 -999 → 0x8066；负数按无符号 16 位。
  static List<int> encodeTemp100(double value) {
    if (value == -999) return [0x80, 0x66];
    var v = (value * 100).round();
    if (v < 0) v += 65536;
    return intTo2Bytes(v & 0xFFFF);
  }

  /// 烟雾浓度编码：乘以 1000，高字节在前。
  static List<int> encodeSmoke1000(double value) {
    var v = (value * 1000).round();
    if (v < 0) v = 0;
    if (v > 65535) v = 65535;
    return intTo2Bytes(v);
  }
  
  /// 将浮点数转换为4字节整数（乘以100，高字节在前）
  static List<int> floatTo4Bytes(double value) {
    final intValue = (value * 100).round();
    return [
      (intValue >> 24) & 0xFF,
      (intValue >> 16) & 0xFF,
      (intValue >> 8) & 0xFF,
      intValue & 0xFF,
    ];
  }
}

