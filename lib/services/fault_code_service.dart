/// 故障码和预警码定义服务
class FaultCodeService {
  static final FaultCodeService _instance = FaultCodeService._internal();
  factory FaultCodeService() => _instance;
  FaultCodeService._internal();

  // 传感器类型定义（与485协议一致）
  static const int SENSOR_CO = 0x02;           // CO传感器
  static const int SENSOR_H2 = 0x04;           // H2传感器
  static const int SENSOR_TEMP_HUMIDITY = 0x05; // 温湿度传感器
  static const int SENSOR_PRESSURE = 0x06;      // 压力传感器
  static const int SENSOR_SMOKE = 0x03;         // 烟雾传感器
  static const int SENSOR_PT100 = 0x08;         // PT100传感器

  // 故障码定义（高字节=传感器类型，低字节=故障类型）
  // 故障码范围：0x80-0xFF（最高位为1表示故障）
  static const int FAULT_TEMP_OVER = 0x81;      // 温度超限故障
  static const int FAULT_TEMP_PARTIAL = 0x82;   // 局放值高故障
  static const int FAULT_CO_OVER = 0x83;        // CO超限故障
  static const int FAULT_H2_OVER = 0x84;        // H2超限故障
  static const int FAULT_PRESSURE_OVER = 0x85;  // 压力超限故障
  static const int FAULT_HUMIDITY_OVER = 0x86;  // 湿度超限故障
  static const int FAULT_SMOKE_FAULT = 0x87;    // 烟雾传感器故障
  static const int FAULT_PT100_OPEN = 0x88;     // PT100开路故障
  static const int FAULT_CONNECTION = 0x89;      // 连接故障

  // 预警码定义（高字节=传感器类型，低字节=预警类型）
  // 预警码范围：0x40-0x7F（最高位为0，次高位为1表示预警）
  static const int WARN_TEMP_OVER = 0x41;       // 温度预警
  static const int WARN_TEMP_GROWTH = 0x42;     // 温度增长预警
  static const int WARN_CO_OVER = 0x43;         // CO预警
  static const int WARN_H2_OVER = 0x44;         // H2预警
  static const int WARN_PRESSURE_OVER = 0x45;   // 压力预警
  static const int WARN_HUMIDITY_OVER = 0x46;  // 湿度预警
  static const int WARN_SMOKE = 0x47;           // 烟雾预警

  /// 根据预警/故障描述解析故障码
  int? parseFaultCode(String description) {
    if (description.contains('温度故障')) {
      if (description.contains('局放值高')) {
        return FAULT_TEMP_PARTIAL;
      }
      return FAULT_TEMP_OVER;
    } else if (description.contains('一氧化碳故障')) {
      return FAULT_CO_OVER;
    } else if (description.contains('氢气故障')) {
      return FAULT_H2_OVER;
    } else if (description.contains('压力故障')) {
      return FAULT_PRESSURE_OVER;
    } else if (description.contains('湿度故障')) {
      return FAULT_HUMIDITY_OVER;
    } else if (description.contains('烟雾传感器故障')) {
      return FAULT_SMOKE_FAULT;
    } else if (description.contains('PT100传感器开路')) {
      return FAULT_PT100_OPEN;
    } else if (description.contains('连接故障') || description.contains('未连接')) {
      return FAULT_CONNECTION;
    }
    return null;
  }

  /// 根据预警描述解析预警码
  int? parseWarningCode(String description) {
    if (description.contains('温度预警')) {
      if (description.contains('增长')) {
        return WARN_TEMP_GROWTH;
      }
      return WARN_TEMP_OVER;
    } else if (description.contains('一氧化碳预警')) {
      return WARN_CO_OVER;
    } else if (description.contains('氢气预警')) {
      return WARN_H2_OVER;
    } else if (description.contains('压力预警')) {
      return WARN_PRESSURE_OVER;
    } else if (description.contains('湿度预警')) {
      return WARN_HUMIDITY_OVER;
    } else if (description.contains('烟雾预警')) {
      return WARN_SMOKE;
    }
    return null;
  }

  /// 从描述中提取数值（用于故障/预警数据）
  double? extractValue(String description) {
    // 尝试提取温度值
    final tempMatch = RegExp(r'(\d+\.?\d*)°C').firstMatch(description);
    if (tempMatch != null) {
      return double.tryParse(tempMatch.group(1)!);
    }
    
    // 尝试提取压力值
    final pressureMatch = RegExp(r'(\d+\.?\d*)kPa').firstMatch(description);
    if (pressureMatch != null) {
      return double.tryParse(pressureMatch.group(1)!);
    }
    
    // 尝试提取CO值
    final coMatch = RegExp(r'(\d+)ppm').firstMatch(description);
    if (coMatch != null) {
      return double.tryParse(coMatch.group(1)!);
    }
    
    // 尝试提取H2值
    final h2Match = RegExp(r'(\d+\.?\d*)%LEL').firstMatch(description);
    if (h2Match != null) {
      return double.tryParse(h2Match.group(1)!);
    }
    
    // 尝试提取湿度值
    final humidityMatch = RegExp(r'(\d+\.?\d*)%RH').firstMatch(description);
    if (humidityMatch != null) {
      return double.tryParse(humidityMatch.group(1)!);
    }
    
    return null;
  }
}
