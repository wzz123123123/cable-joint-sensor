import 'dart:convert';
import 'dart:math' as math;
import 'sensor_data_service.dart';
import 'settings_service.dart';

/// 统一的数据计算服务，确保CSV、Modbus TCP服务器和页面显示使用完全相同的计算逻辑
class NodeDataCalculator {
  static final NodeDataCalculator _instance = NodeDataCalculator._internal();
  factory NodeDataCalculator() => _instance;
  NodeDataCalculator._internal();

  /// 计算节点显示数据（与页面显示完全一致）
  /// 返回一个Map，包含所有页面显示的数据
  Future<Map<String, dynamic>> calculateDisplayData(SensorData data) async {
    // 获取节点设置
    final settings = SettingsService();
    final nodeSettings = await settings.getAllSettingsForNode(data.nodeId);
    
    final upperCorr = nodeSettings['upperTempCorrection'] as double? ?? 0.0;
    final middleCorr = nodeSettings['envTempCorrection'] as double? ?? 0.0;
    final lowerCorr = nodeSettings['lowerTempCorrection'] as double? ?? 0.0;
    final humidityCorr = nodeSettings['humidityCorrection'] as double? ?? 0.0;
    
    // 获取节点特定的PT100修正值
    final pt100Corrections = nodeSettings['pt100Corrections'] as List<dynamic>? ?? List.filled(10, 0.0);
    
    // 解析PT100数据并应用修正值
    List<double> correctedTemps = [];
    if (data.pt100Temperatures != null) {
      final temps = jsonDecode(data.pt100Temperatures!) as List;
      correctedTemps = List<double>.generate(
        temps.length,
        (i) {
          final base = temps[i] as double;
          if (base == -999) return -999;
          final delta = i < pt100Corrections.length ? (pt100Corrections[i] as double? ?? 0.0) : 0.0;
          return base + delta;
        },
      );
    }
    
    // 计算上中下温度（与页面逻辑完全一致）
    double upperTemp = (data.temperature ?? 25) + upperCorr;
    double middleTemp = (data.temperature ?? 25) + middleCorr;
    double lowerTemp = (data.temperature ?? 25) + lowerCorr;
    
    // 节点1特殊处理：使用PT100通道10作为上温度
    if (data.nodeId == 1 && correctedTemps.length >= 11) {
      upperTemp = correctedTemps[10] + upperCorr;
    } else if (correctedTemps.length >= 10) {
      upperTemp = correctedTemps[9] + upperCorr;
    }
    
    // 使用PT100通道11作为中温度
    if (correctedTemps.length >= 12 && correctedTemps[11] != -999) {
      middleTemp = correctedTemps[11] + middleCorr;
    }
    
    // 下温度=温湿度传感器温度
    lowerTemp = (data.temperature ?? 25) + lowerCorr;
    
    // 计算A/B/C相温度（与页面逻辑完全一致）
    Map<String, List<double>> phaseTemps = {};
    if (correctedTemps.length >= 9) {
      // 获取K1、K2参数
      final aK1 = nodeSettings['aK1'] as double? ?? 6.42;
      final aK2 = nodeSettings['aK2'] as double? ?? 2.5;
      final bK1 = nodeSettings['bK1'] as double? ?? 6.42;
      final bK2 = nodeSettings['bK2'] as double? ?? 2.5;
      final cK1 = nodeSettings['cK1'] as double? ?? 6.42;
      final cK2 = nodeSettings['cK2'] as double? ?? 2.5;
      
      // A相
      final aL = correctedTemps[0];
      final aM = correctedTemps[1];
      final aR = correctedTemps[2];
      
      // B相
      final bL = correctedTemps[3];
      final bM = correctedTemps[4];
      final bR = correctedTemps[5];
      
      // C相
      final cL = correctedTemps[6];
      final cM = correctedTemps[7];
      final cR = correctedTemps[8];
      
      // 计算三相平均值
      final leftAvg = (aL + bL + cL) / 3;
      final middleAvg = (aM + bM + cM) / 3;
      final rightAvg = (aR + bR + cR) / 3;
      
      // 计算内温度（与页面逻辑完全一致）
      final aLInner = _calculateInnerTemp(aL, upperTemp, leftAvg, aK1, aK2);
      final aMInner = _calculateInnerTemp(aM, upperTemp, middleAvg, aK1, aK2);
      final aRInner = _calculateInnerTemp(aR, upperTemp, rightAvg, aK1, aK2);
      
      final bLInner = _calculateInnerTemp(bL, middleTemp, leftAvg, bK1, bK2);
      final bMInner = _calculateInnerTemp(bM, middleTemp, middleAvg, bK1, bK2);
      final bRInner = _calculateInnerTemp(bR, middleTemp, rightAvg, bK1, bK2);
      
      final cLInner = _calculateInnerTemp(cL, lowerTemp, leftAvg, cK1, cK2);
      final cMInner = _calculateInnerTemp(cM, lowerTemp, middleAvg, cK1, cK2);
      final cRInner = _calculateInnerTemp(cR, lowerTemp, rightAvg, cK1, cK2);
      
      // 页面只显示：左外、中外、右外、中内
      phaseTemps['A'] = [aL, aM, aR, aMInner];
      phaseTemps['B'] = [bL, bM, bR, bMInner];
      phaseTemps['C'] = [cL, cM, cR, cMInner];
    }
    
    // 计算烟雾浓度（与页面逻辑完全一致）
    double whiteSmoke = 0.1;
    double blackSmoke = 0.1;
    
    if (data.smokeChannelA != null) {
      final aA = (data.smokeCalibA ?? 0).toDouble();
      final tA = (data.smokeThreshA ?? 568).toDouble();
      whiteSmoke = _calculateSmokeConcentrationWithParams(data.smokeChannelA!.toDouble(), aA, tA);
    }
    
    if (data.smokeChannelB != null) {
      final aB = (data.smokeCalibB ?? 0).toDouble();
      final tB = (data.smokeThreshB ?? 568).toDouble();
      blackSmoke = _calculateSmokeConcentrationWithParams(data.smokeChannelB!.toDouble(), aB, tB);
    }
    
    // 计算湿度（应用修正）
    double? humidityCorrected;
    if (data.humidity != null) {
      humidityCorrected = ((data.humidity! + humidityCorr)).clamp(0, 100).toDouble();
    }
    
    // CO值处理（与页面逻辑完全一致）
    double? coCorrected;
    if (data.coPpm != null) {
      final rawCo = data.coPpm!.toDouble();
      if (rawCo < 0 || rawCo > 10000) {
        coCorrected = 0.0;
      } else {
        coCorrected = rawCo;
      }
    }
    
    return {
      // 环境参数
      'upperTemp': upperTemp,
      'middleTemp': middleTemp,
      'lowerTemp': lowerTemp,
      'humidity': humidityCorrected,
      'pressure': data.pressureKpa,
      'h2': data.h2Percentage,
      'co': coCorrected,
      
      // 烟雾
      'whiteSmoke': whiteSmoke,
      'blackSmoke': blackSmoke,
      
      // 相温度（页面显示的4个值：左外、中外、右外、中内）
      // 如果没有数据，使用-999.0表示开路/无效值
      'phaseA': phaseTemps['A'] ?? [-999.0, -999.0, -999.0, -999.0],
      'phaseB': phaseTemps['B'] ?? [-999.0, -999.0, -999.0, -999.0],
      'phaseC': phaseTemps['C'] ?? [-999.0, -999.0, -999.0, -999.0],
      
      // 原始PT100数据（已应用修正）
      'pt100Corrected': correctedTemps,
    };
  }
  
  /// 计算内温度（与页面逻辑完全一致）
  /// Y = xi + k1·max(0, xi – x0i) + k2·max(0, xi – xia)
  double _calculateInnerTemp(double xi, double x0i, double xia, double k1, double k2) {
    if (xi == -999) return -999;
    
    // 当外温度小于环境温度时，中内温度等于中外温度
    if (xi < x0i) {
      return xi;
    }
    
    // 对差值进行下限截断：若为负则按0计算
    final deltaEnv = xi - x0i;
    final deltaPhaseAvg = xi - xia;
    final nonNegativeEnv = deltaEnv < 0 ? 0 : deltaEnv;
    final nonNegativePhaseAvg = deltaPhaseAvg < 0 ? 0 : deltaPhaseAvg;
    
    // 应用公式：Y = xi + k1·max(0, xi – x0i) + k2·max(0, xi – xia)
    return xi + k1 * nonNegativeEnv + k2 * nonNegativePhaseAvg;
  }
  
  /// 计算烟雾浓度（与页面逻辑完全一致）
  /// 变量修正：x0 = 568 * (xStar - a) / T
  /// 浓度拟合：x0 < 568 => m = -1.5e-7 * x0^2 + 0.0007 * x0
  ///          x0 >= 568 => m = 0.2772 * ln(x0) - 1.408
  double _calculateSmokeConcentrationWithParams(double xStar, double a, double T) {
    final double tSafe = (T == 0) ? 568.0 : T;
    final double delta = xStar - a;
    if (delta <= 0) {
      return 0.0;
    }
    final double x0 = 568.0 * (delta / tSafe);
    double m;
    if (x0 < 568.0) {
      m = -0.00000015 * x0 * x0 + 0.0007 * x0;
    } else {
      final double lnX0 = _naturalLog(x0);
      m = 0.2772 * lnX0 - 1.408;
    }
    return m < 0 ? 0 : m;
  }
  
  /// 手动实现自然对数（与页面逻辑完全一致）
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
}


