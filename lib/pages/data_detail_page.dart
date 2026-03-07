import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/node_data.dart';
import '../providers/sensor_provider.dart';
import '../services/alert_service.dart';
import '../services/settings_service.dart';
import '../services/password_service.dart';
import '../services/ignore_service.dart';

class DataDetailPage extends StatefulWidget {
  final int nodeId;
  final NodeData? nodeData;
  const DataDetailPage({super.key, required this.nodeId, this.nodeData});

  @override
  State<DataDetailPage> createState() => _DataDetailPageState();
}

class _DataDetailPageState extends State<DataDetailPage> {
  String currentTime = '';
  String systemStatus = '正常';
  Color statusColor = const Color(0xFF00C853);
  bool hasFault = false;
  bool hasWarning = false;
  String faultInfo = '';
  
  // 多选状态管理
  bool isMultiSelectMode = false;
  Set<int> selectedFaultIndices = <int>{};

  // 电缆接头测点温度数据
  List<double> phaseATemps = [45, 45, 45, 45, 45, 45];
  List<double> phaseBTemps = [45, 45, 45, 45, 45, 45];
  List<double> phaseCTemps = [45, 45, 45, 45, 45, 45];
  List<String> phaseADisplay = ['—', '—', '—'];
  List<String> phaseBDisplay = ['—', '—', '—'];
  List<String> phaseCDisplay = ['—', '—', '—'];

  // 防爆盒内环境参数
  double humidity = 45;
  double pressure = 100;
  double whiteSmoke = 0.1;
  double h2Concentration = 0;
  double coConcentration = 10;
  double blackSmoke = 0.1;
  double upperTemp = 25;
  double middleTemp = 25;
  double lowerTemp = 25;
  double smokeRatio = 0;

  // PT100 十路误差修正（单位：℃，可正可负，步进0.1）
  List<double> _pt100Corrections = List<double>.filled(10, 0.0);
  bool _blinkOn = true;
  Timer? _blinkTimer;

  @override
  void initState() {
    super.initState();
    _updateCurrentTime();
    _loadPt100Corrections();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_updateDataFromNode());
    });
    _startDataRefresh();
    _blinkTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _blinkOn = !_blinkOn;
      });
    });
    // 初始化忽略服务
    IgnoreService().initialize();
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    super.dispose();
  }

  // 加载PT100误差修正数据
  void _loadPt100Corrections() {
    _pt100Corrections = SettingsService().pt100Corrections;
  }

  void _updateCurrentTime() {
    final now = DateTime.now();
    final year = now.year;
    final month = (now.month).toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final hours = now.hour.toString().padLeft(2, '0');
    final minutes = now.minute.toString().padLeft(2, '0');
    final seconds = now.second.toString().padLeft(2, '0');
    setState(() {
      currentTime = '$year/$month/$day  $hours:$minutes:$seconds';
    });
  }

  Future<void> _updateDataFromNode() async {
    // 从SensorProvider获取最新的节点数据
    final sensorProvider = Provider.of<SensorProvider>(context, listen: false);
    final currentNode = sensorProvider.getNodeData(widget.nodeId);
    
    if (currentNode == null) {
      print('Node not found in provider');
      return;
    }
    
    print('Updating data from node: ${currentNode.nodeId}');
    print('PT100 temperatures: ${currentNode.pt100Temperatures}');
    print('NodeData完整信息: smokeChannelA=${currentNode.smokeChannelA}, smokeChannelB=${currentNode.smokeChannelB}, smokeExternalTempC=${currentNode.smokeExternalTempC}');
    
    // 设置温度数据（叠加参数修正）- 在setState外部获取设置
    final s = SettingsService();
    final nodeSettings = await s.getAllSettingsForNode(widget.nodeId);
    final upperCorr = nodeSettings['upperTempCorrection'] as double? ?? 0.0;
    final middleCorr = nodeSettings['envTempCorrection'] as double? ?? 0.0;
    final lowerCorr = nodeSettings['lowerTempCorrection'] as double? ?? 0.0;
    
    setState(() {
      final humidityCorr = (nodeSettings['humidityCorrection'] as double? ?? 0.0);
      final rawHumidity = currentNode.humidity ?? 45;
      // 获取湿度历史正常值（如果当前值异常）
      final humidityHistoryValue = sensorProvider.getHumidityHistoryValue(widget.nodeId, rawHumidity);
      final validHumidity = humidityHistoryValue ?? rawHumidity;
      if (humidityHistoryValue != null) {
        print('湿度异常值替换: 节点=${widget.nodeId}, 异常值=$rawHumidity, 使用历史值=$humidityHistoryValue');
      }
      final correctedHumidity = (validHumidity + humidityCorr).clamp(0, 100);
      humidity = correctedHumidity.toDouble();
      pressure = currentNode.pressureKpa ?? 100;
      h2Concentration = currentNode.h2Percentage ?? 0;
      // 一氧化碳数据处理：检测负值和异常值
      final rawCo = currentNode.coPpm?.toDouble() ?? 10;
      if (rawCo < 0 || rawCo > 10000) {
        // 如果是负数或异常大的值，设置为0
        coConcentration = 0.0;
        print('CO异常值检测: 原始值=$rawCo, 修正为0');
      } else {
        coConcentration = rawCo;
      }
      smokeRatio = currentNode.smokeRatio ?? 0;
      
      // 辅助函数：获取环境温度值，如果异常则使用历史正常值
      double getValidTempForEnv(int channelIndex, double currentValue, double defaultTemp) {
        // 检查是否异常（超出合理范围，去掉上限）
        if (currentValue < -50 || currentValue == -999) {
          // 尝试获取历史正常值
          final historyValue = sensorProvider.getTempHistoryValue(widget.nodeId, channelIndex, currentValue);
          if (historyValue != null) {
            print('环境温度异常值替换: 节点=${widget.nodeId}, 通道=$channelIndex, 异常值=$currentValue, 使用历史值=$historyValue');
            return historyValue;
          }
          // 没有历史值，使用默认温度
          return defaultTemp;
        }
        return currentValue;
      }
      
      // 使用PT100通道11作为中温度，温湿度传感器温度作为下温度
      if (currentNode.pt100Temperatures != null && currentNode.pt100Temperatures!.length >= 12) {
        final pt11Temp = currentNode.pt100Temperatures![11];
        final validPt11Temp = getValidTempForEnv(11, pt11Temp, (currentNode.temperature ?? 25).toDouble());
        middleTemp = (validPt11Temp != -999) ? validPt11Temp + middleCorr : (currentNode.temperature ?? 25) + middleCorr;
      } else {
        middleTemp = (currentNode.temperature ?? 25) + middleCorr; // 备用：温湿度传感器温度
      }
      lowerTemp = (currentNode.temperature ?? 25) + lowerCorr; // 下温度=温湿度传感器温度
      
      // 烟雾通道数据（使用烟感计算）
      print('烟雾通道A: ${currentNode.smokeChannelA}');
      print('烟雾通道B: ${currentNode.smokeChannelB}');
      
      if (currentNode.smokeChannelA != null) {
        // 根据协议：a = 标定零点，T = 报警阈值
        final aA = (currentNode.smokeCalibA ?? 0).toDouble();
        final tA = (currentNode.smokeThreshA ?? 568).toDouble();
        print('白烟计算参数: xStar=${currentNode.smokeChannelA}, a=$aA, T=$tA');
        whiteSmoke = _calculateSmokeConcentrationWithParams(currentNode.smokeChannelA!.toDouble(), aA, tA);
        print('白烟计算结果: $whiteSmoke');
      } else {
        whiteSmoke = 0.1;
        print('白烟使用默认值: $whiteSmoke');
      }
      
      if (currentNode.smokeChannelB != null) {
        // 根据协议：a = 标定零点，T = 报警阈值
        final aB = (currentNode.smokeCalibB ?? 0).toDouble();
        final tB = (currentNode.smokeThreshB ?? 568).toDouble();
        print('黑烟计算参数: xStar=${currentNode.smokeChannelB}, a=$aB, T=$tB');
        blackSmoke = _calculateSmokeConcentrationWithParams(currentNode.smokeChannelB!.toDouble(), aB, tB);
        print('黑烟计算结果: $blackSmoke');
      } else {
        blackSmoke = 0.1;
        print('黑烟使用默认值: $blackSmoke');
      }
      
      // PT100数据映射到ABC三相
      if (currentNode.pt100Temperatures != null && currentNode.pt100Temperatures!.length >= 9) {
        final temps = currentNode.pt100Temperatures!;
        
        // 获取节点特定的PT100修正值
        final pt100Corrections = nodeSettings['pt100Corrections'] as List<dynamic>? ?? List.filled(10, 0.0);
        
        // 应用误差修正：开路(-999)保持不变，否则加上修正值
        final corrected = List<double>.generate(
          temps.length,
          (i) {
            final base = temps[i];
            if (base == -999) return -999;
            final delta = i < pt100Corrections.length ? (pt100Corrections[i] as double? ?? 0.0) : 0.0;
            return base + delta;
          },
        );
        print('Processing PT100 data: $temps');
        print('PT100 corrections: $_pt100Corrections');
        print('PT100 corrected: $corrected');
        
        // 辅助函数：获取温度值，如果异常则使用历史正常值
        double getValidTemp(int channelIndex, double currentValue) {
          // 检查是否异常（超出合理范围，去掉上限）
          if (currentValue < -50 || currentValue == -999) {
            // 尝试获取历史正常值
            final historyValue = sensorProvider.getTempHistoryValue(widget.nodeId, channelIndex, currentValue);
            if (historyValue != null) {
              print('温度异常值替换: 节点=${widget.nodeId}, 通道=$channelIndex, 异常值=$currentValue, 使用历史值=$historyValue');
              return historyValue;
            }
            // 没有历史值，使用默认值25°C（但保持开路标记）
            if (currentValue == -999) return -999;
            print('温度异常值替换: 节点=${widget.nodeId}, 通道=$channelIndex, 异常值=$currentValue, 使用默认值25.0');
            return 25.0;
          }
          return currentValue;
        }
        
        // A: ch1,ch2,ch3 - 使用有效温度值（异常时使用历史值）
        final aL = getValidTemp(0, corrected[0]);
        final aM = getValidTemp(1, corrected[1]);
        final aR = getValidTemp(2, corrected[2]);
        
        // B: ch4,ch5,ch6 - 使用有效温度值（异常时使用历史值）
        final bL = getValidTemp(3, corrected[3]);
        final bM = getValidTemp(4, corrected[4]);
        final bR = getValidTemp(5, corrected[5]);
        
        // C: ch7,ch8,ch9 - 使用有效温度值（异常时使用历史值）
        final cL = getValidTemp(6, corrected[6]);
        final cM = getValidTemp(7, corrected[7]);
        final cR = getValidTemp(8, corrected[8]);
        
        // 计算内温度：Y = xi + 6.42（xi – x0i）+（xi-xia）*2.5
        // xi: 外测点温度, x0i: 环境温度, xia: 三相平均值
        
        // 计算三相平均值（使用有效温度值，排除开路值）
        double calculateAvg(double val1, double val2, double val3) {
          int count = 0;
          double sum = 0;
          if (val1 != -999) { sum += val1; count++; }
          if (val2 != -999) { sum += val2; count++; }
          if (val3 != -999) { sum += val3; count++; }
          return count > 0 ? sum / count : 25.0; // 如果都是开路，使用默认值
        }
        
        final leftAvg = calculateAvg(aL, bL, cL);   // 左外温度平均值
        final middleAvg = calculateAvg(aM, bM, cM); // 中外温度平均值  
        final rightAvg = calculateAvg(aR, bR, cR);  // 右外温度平均值
        
        // 获取节点特定的k1、k2参数
        final aK1 = nodeSettings['aK1'] as double? ?? 6.42;
        final aK2 = nodeSettings['aK2'] as double? ?? 2.5;
        final bK1 = nodeSettings['bK1'] as double? ?? 6.42;
        final bK2 = nodeSettings['bK2'] as double? ?? 2.5;
        final cK1 = nodeSettings['cK1'] as double? ?? 6.42;
        final cK2 = nodeSettings['cK2'] as double? ?? 2.5;
        
        // A相内温度计算（环境温度为上温度）
        final aLInner = _calculateInnerTempWithParams(aL, upperTemp, leftAvg, aK1, aK2);
        final aMInner = _calculateInnerTempWithParams(aM, upperTemp, middleAvg, aK1, aK2);
        final aRInner = _calculateInnerTempWithParams(aR, upperTemp, rightAvg, aK1, aK2);
        
        // B相内温度计算（环境温度为中温度）
        final bLInner = _calculateInnerTempWithParams(bL, middleTemp, leftAvg, bK1, bK2);
        final bMInner = _calculateInnerTempWithParams(bM, middleTemp, middleAvg, bK1, bK2);
        final bRInner = _calculateInnerTempWithParams(bR, middleTemp, rightAvg, bK1, bK2);
        
        // C相内温度计算（环境温度为下温度）
        final cLInner = _calculateInnerTempWithParams(cL, lowerTemp, leftAvg, cK1, cK2);
        final cMInner = _calculateInnerTempWithParams(cM, lowerTemp, middleAvg, cK1, cK2);
        final cRInner = _calculateInnerTempWithParams(cR, lowerTemp, rightAvg, cK1, cK2);
        
        // 设置温度数组：[左外, 左内, 中外, 中内, 右外, 右内]
        phaseATemps = [aL, aLInner, aM, aMInner, aR, aRInner];
        phaseBTemps = [bL, bLInner, bM, bMInner, bR, bRInner];
        phaseCTemps = [cL, cLInner, cM, cMInner, cR, cRInner];
        // 上温度（叠加修正）：节点1使用通道10，其他节点使用通道9
        // 使用有效温度值（异常时使用历史值）
        if (widget.nodeId == 1) {
          // 节点1使用通道10
          final validUpperTemp = getValidTemp(10, corrected.length >= 11 ? corrected[10] : 25.0);
          upperTemp = (validUpperTemp != -999) ? validUpperTemp + upperCorr : 25 + upperCorr;
        } else {
          // 其他节点使用通道9
          final validUpperTemp = getValidTemp(9, corrected[9]);
          upperTemp = (validUpperTemp != -999) ? validUpperTemp + upperCorr : 25 + upperCorr;
        }

        print('Phase A temps: $phaseATemps');
        print('Phase B temps: $phaseBTemps');
        print('Phase C temps: $phaseCTemps');
      } else {
        // 如果没有PT100数据，设置默认值
        upperTemp = 25 + upperCorr;
        middleTemp = (currentNode.temperature ?? 25) + middleCorr;
        lowerTemp = (currentNode.pressureTempC ?? 25) + lowerCorr;
        
        // 设置测试数据显示
        phaseADisplay = ['26.1 °C', '26.3 °C', '24.9 °C'];
        phaseBDisplay = ['26.2 °C', '26.0 °C', '26.4 °C'];
        phaseCDisplay = ['25.8 °C', '26.1 °C', '26.3 °C'];
        
        print('Using test data for PT100 display');
      }
    });
  }

  String _mergePairDisplay(double outerVal, double innerVal) {
    final outerText = _formatTempText(outerVal);
    if (outerText == '开路') {
      return _formatTempText(innerVal);
    }
    return outerText;
  }

  String _formatTempText(double n) {
    if (n == -999) return '开路';
    return n.toStringAsFixed(2) + ' °C';
  }

  String _formatTempCore(double n) {
    if (n == -999) return '开路';
    return n.toStringAsFixed(1);
  }

  String _formatNumber1(double n) {
    return n.toStringAsFixed(1);
  }

  // 温度、H2、白黑烟格式化（2位小数）
  String _formatNumber2(double n) {
    return n.toStringAsFixed(2);
  }

  // 烟雾浓度格式化（2位小数）
  String _formatSmokeConcentration(double concentration) {
    if (concentration < 0.1) {
      return '0.00';
    }
    return concentration.toStringAsFixed(2);
  }

  // 烟感计算：新变量修正 + 拟合公式（支持传入a、T）
  // 变量修正：x0 = 568 * (xStar - a) / T
  // 浓度拟合：x0 < 568 => m = -1.5e-7 * x0^2 + 0.0007 * x0
  //          x0 >= 568 => m = 0.2772 * ln(x0) - 1.408
  double _calculateSmokeConcentrationWithParams(double xStar, double a, double T) {
    print('烟雾计算开始: xStar=$xStar, a=$a, T=$T');
    final double tSafe = (T == 0) ? 568.0 : T;
    final double delta = xStar - a;
    print('烟雾计算: delta=$delta');
    if (delta <= 0) {
      print('烟雾计算: delta <= 0, 返回0');
      return 0.0;
    }
    final double x0 = 568.0 * (delta / tSafe);
    print('烟雾计算: x0=$x0');
    double m;
    if (x0 < 568.0) {
      m = -0.00000015 * x0 * x0 + 0.0007 * x0;
      print('烟雾计算: x0 < 568, 使用二次公式, m=$m');
    } else {
      final double lnX0 = _naturalLog(x0);
      m = 0.2772 * lnX0 - 1.408;
      print('烟雾计算: x0 >= 568, 使用对数公式, ln(x0)=$lnX0, m=$m');
    }
    final double result = m < 0 ? 0 : m;
    print('烟雾计算最终结果: $result');
    return result;
  }

  // 计算内温度：Y = xi + k1·max(0, xi – x0i) + k2·max(0, xi – xia)
  // xi: 外测点温度, x0i: 环境温度, xia: 三相平均值
  // phase: 相别 ('A', 'B', 'C')
  double _calculateInnerTemp(double xi, double x0i, double xia, String phase) {
    // 如果外测点温度为开路，内温度也为开路
    if (xi == -999) return -999;
    
    // 当外温度小于环境温度时，中内温度等于中外温度
    if (xi < x0i) {
      return xi;
    }
    
    // 获取对应相的k1、k2参数
    final settings = SettingsService();
    double k1, k2;
    switch (phase) {
      case 'A':
        k1 = settings.aK1;
        k2 = settings.aK2;
        break;
      case 'B':
        k1 = settings.bK1;
        k2 = settings.bK2;
        break;
      case 'C':
        k1 = settings.cK1;
        k2 = settings.cK2;
        break;
      default:
        k1 = 6.42; // 默认值
        k2 = 2.5;  // 默认值
    }
    
    // 对差值进行下限截断：若为负则按0计算
    final deltaEnv = xi - x0i;
    final deltaPhaseAvg = xi - xia;
    final nonNegativeEnv = deltaEnv < 0 ? 0 : deltaEnv;
    final nonNegativePhaseAvg = deltaPhaseAvg < 0 ? 0 : deltaPhaseAvg;
    
    // 应用公式：Y = xi + k1·max(0, xi – x0i) + k2·max(0, xi – xia)
    final y = xi + k1 * nonNegativeEnv + k2 * nonNegativePhaseAvg;
    return y;
  }
  
  // 计算内温度（使用指定参数）
  double _calculateInnerTempWithParams(double xi, double x0i, double xia, double k1, double k2) {
    // 如果外测点温度为开路，内温度也为开路
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
    final y = xi + k1 * nonNegativeEnv + k2 * nonNegativePhaseAvg;
    return y;
  }

  // 手动实现自然对数（与报警服务保持一致）
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

  void _startDataRefresh() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _updateCurrentTime();
      unawaited(_updateDataFromNode());
      _updateConnectionStatus();
    });
  }



  Future<void> _updateConnectionStatus() async {
    // 从SensorProvider获取最新的节点数据
    final sensorProvider = Provider.of<SensorProvider>(context, listen: false);
    final currentNode = sensorProvider.getNodeData(widget.nodeId);
    
    if (currentNode == null) {
      setState(() {
        systemStatus = '❌ 未连接';
        statusColor = const Color(0xFFBDBDBD);
        hasFault = false;
        hasWarning = false;
        faultInfo = '设备未连接';
      });
      return;
    }

    // 使用新的预警服务分析节点数据
    final alertInfo = await AlertService().analyzeNodeData(currentNode);
    
    setState(() {
      // 更新系统状态
      systemStatus = alertInfo.level == AlertLevel.fault ? '⚠️ 故障' : 
                    alertInfo.level == AlertLevel.warning ? '⚠️ 预警' : '✅ 正常';
      
      // 更新状态颜色
      switch (alertInfo.level) {
        case AlertLevel.fault:
          statusColor = const Color(0xFFD50000); // 红色
          break;
        case AlertLevel.warning:
          statusColor = const Color(0xFFFF9800); // 橙色
          break;
        case AlertLevel.normal:
          statusColor = const Color(0xFF00C853); // 绿色
          break;
      }
      
      // 更新故障和预警状态
      hasFault = alertInfo.faults.isNotEmpty;
      hasWarning = alertInfo.warnings.isNotEmpty;
      
      // 更新故障信息
      faultInfo = alertInfo.description;
    });
  }

  // 判断节点是否连接
  bool _isConnected(NodeData? node) {
    if (node == null) return false;
    
    final now = DateTime.now().millisecondsSinceEpoch;
    final isStale = (node.lastUpdateTimestamp == null) || (now - node.lastUpdateTimestamp! > 40000);
    
    if (isStale) return false;
    
    // 基于实际传感器数据判断连接状态
    final hasData = node.temperature != null || node.humidity != null || node.coPpm != null || 
        node.h2Percentage != null || node.pressureKpa != null || node.smokeChannelA != null || 
        node.smokeChannelB != null || (node.pt100Temperatures != null && node.pt100Temperatures!.isNotEmpty);
    
    return hasData;
  }

  @override
  Widget build(BuildContext context) {
    // 获取当前节点数据
    final sensorProvider = Provider.of<SensorProvider>(context, listen: false);
    final currentNode = sensorProvider.getNodeData(widget.nodeId);
    
    return Scaffold(
      backgroundColor: const Color(0xFFB6A56A),
      body: Column(
        children: [
          // 顶部标题栏
          Container(
            color: const Color(0xFFCBBE8E),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Row(
              children: [
                // 左侧：节点名称（放大1倍，移到左侧）
                Text(
                  '节点${widget.nodeId.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.black),
                ),
                const SizedBox(width: 16),
                
                // 中间：图标+标题（放大1倍，居中）
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Image(image: AssetImage('assets/media/coo.png'), width: 90, height: 90),
                      SizedBox(width: 20),
                      Image(image: AssetImage('assets/media/hit1.png'), width: 90, height: 90),
                      SizedBox(width: 24),
                      Text(
                        '电缆中间接头关键参数监测系统',
                        style: TextStyle(fontSize: 56, fontWeight: FontWeight.bold, color: Colors.black),
                      ),
                    ],
                  ),
                ),
                
                // 右侧：时间（放大1倍，移到右侧）
                Text(
                  currentTime,
                  style: const TextStyle(fontSize: 40, color: Colors.black, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          
          // 主要内容区域
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  // 三个区域布局：左侧两个，右侧一个
                  Expanded(
                    flex: 1,
                    child: Row(
                      children: [
                        // 左侧：上下两个区域
                        Expanded(
                          flex: 8,
                          child: Column(
                            children: [
                              // 上半部分：电缆接头测点温度
                              Expanded(
                                flex: 1,
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(82, 12, 12, 12),
                                  margin: const EdgeInsets.only(left: 30),
                                  constraints: const BoxConstraints.expand(),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFB6A56A),
                                    border: Border.all(width: 4, color: const Color(0xFF003366), style: BorderStyle.solid),
                                  ),
                                  child: SingleChildScrollView(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          '电缆接头测点温度',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.black),
                                        ),
                                        const SizedBox(height: 8),
                                        _buildPhaseSection('A相', phaseATemps),
                                        const SizedBox(height: 4),
                                        _buildPhaseSection('B相', phaseBTemps),
                                        const SizedBox(height: 4),
                                        _buildPhaseSection('C相', phaseCTemps),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              // 下半部分：防爆盒内环境参数
                              Expanded(
                                flex: 1,
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(82, 12, 12, 12),
                                  margin: const EdgeInsets.only(left: 30),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFB6A56A),
                                    border: Border.all(width: 4, color: const Color(0xFF003366), style: BorderStyle.solid),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        '防爆盒内环境参数',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.black),
                                      ),
                                      const SizedBox(height: 6),
                                      Expanded(
                                        child: SingleChildScrollView(
                                          child: Column(
                                            children: [
                                            // 第一行：湿度、压力、上温度 + 连接状态
                                            Row(
                                              children: [
                                                const SizedBox(width: 68),
                                                _buildParameterRow('湿度', _formatNumber1(humidity), '%RH'),
                                                const SizedBox(width: 8),
                                                _buildParameterRow('压力', _formatNumber1(pressure), 'kPa'),
                                                const SizedBox(width: 8),
                                                _buildParameterRow('上温度', _formatNumber2(upperTemp), '°C'),
                                                const SizedBox(width: 8),
                                                _buildActionBox(
                                                  _isConnected(currentNode) ? '已连接' : '未连接',
                                                  onTap: null,
                                                  backgroundColor: _isConnected(currentNode) ? Color(0xFF00C853) : Color(0xFFBDBDBD),
                                                  textColor: Colors.white,
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            // 第二行：H2、CO、中温度 + 动作（设置）
                                            Row(
                                              children: [
                                                const SizedBox(width: 68),
                                                _buildParameterRow('H2', _formatNumber2(h2Concentration), '%LEL'),
                                                const SizedBox(width: 8),
                                                _buildParameterRow('CO', _formatNumber1(coConcentration), 'ppm'),
                                                const SizedBox(width: 8),
                                                _buildParameterRow('中温度', _formatNumber2(middleTemp), '°C'),
                                                const SizedBox(width: 8),
                                                _buildActionBoxWithIcon('设置', Icons.settings, onTap: _showSettingsDialog, backgroundColor: Colors.blue, textColor: Colors.white),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            // 第三行：白烟、黑烟、下温度 + 动作（返回）
                                            Row(
                                              children: [
                                                const SizedBox(width: 68),
                                                _buildParameterRow('白烟', _formatSmokeConcentration(whiteSmoke), 'DB'),
                                                const SizedBox(width: 8),
                                                _buildParameterRow('黑烟', _formatSmokeConcentration(blackSmoke), 'DB'),
                                                const SizedBox(width: 8),
                                                _buildParameterRow('下温度', _formatNumber2(lowerTemp), '°C'),
                                                const SizedBox(width: 8),
                                                _buildActionBoxWithIcon('返回', Icons.arrow_back, onTap: () => Navigator.pop(context), backgroundColor: Color(0xFF866400), textColor: Colors.white),
                                              ],
                                            ),
                                          ],
                                        ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 32),
                        // 右侧：系统状态和故障信息（跨上下两部分）
                        Expanded(
                          flex: 2,
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            constraints: const BoxConstraints.expand(),
                            decoration: BoxDecoration(
                              color: statusColor,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(width: 4, color: const Color(0xFF003366), style: BorderStyle.solid),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                const SizedBox(height: 68),
                                // 状态字样（居中，放大两倍）
                                Text(
                                  systemStatus,
                                  style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white),
                                ),
                                const SizedBox(height: 68),
                                // 故障信息（放大一倍）
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 34),
                                    child: _buildFaultInfoList(),
                                  ),
                                ),
                                // 多选模式下的操作按钮（显示在系统状态区域底部）
                                if (isMultiSelectMode) ...[
                                  const SizedBox(height: 8),
                                  _buildSystemStatusActionButtons(),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 30),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhaseSection(String phaseName, List<double> temps) {
    return Row(
      children: [
        SizedBox(width: 60, child: Text(phaseName, maxLines: 1, softWrap: false, textAlign: TextAlign.center, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.black))),
        const SizedBox(width: 8),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildTempBox('左外', _formatTempText(temps[0]))),
              const SizedBox(width: 8),
              Expanded(child: _buildTempBox('中外', _formatTempText(temps[2]))),
              const SizedBox(width: 8),
              Expanded(child: _buildTempBox('右外', _formatTempText(temps[4]))),
              const SizedBox(width: 8),
              Expanded(child: _buildTempBox('中内', _formatTempText(temps[3]))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPhaseGroup(String position, String outerValue, String innerValue) {
    return Column(
      children: [
        Row(
          children: [
            _buildTempBox('${position}外', outerValue),
            const SizedBox(width: 8),
            _buildTempBox('${position}内', innerValue),
          ],
        ),
      ],
    );
  }

  Widget _buildTempBox(String label, String value) {
    final String numericValue = value.replaceAll('°C', '').trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 198,
          child: Text(
            label,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.black),
            textAlign: TextAlign.start,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              width: 198,
              height: 79,
              decoration: const BoxDecoration(
                color: Colors.black,
              ),
              child: Center(
                child: Text(
                  numericValue,
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00FF66),
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              '°C',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFaultInfoList() {
    if (faultInfo.isEmpty || faultInfo == '系统正常') {
      return Center(
        child: Text(
          '节点${widget.nodeId.toString().padLeft(2, '0')}正常',
          style: const TextStyle(fontSize: 36, color: Colors.white),
        ),
      );
    }
    
    // 将故障信息按分号分割成列表
    final faultItems = faultInfo.split('；').where((item) => item.trim().isNotEmpty).toList();
    
    return ListView.builder(
      itemCount: faultItems.length,
      itemBuilder: (context, index) {
        final item = faultItems[index].trim();
        final isSelected = selectedFaultIndices.contains(index);
        
        return GestureDetector(
          onLongPressStart: (_) {
            // 长按开始时的视觉反馈
            HapticFeedback.mediumImpact();
          },
          onLongPress: () {
            if (!isMultiSelectMode) {
              setState(() {
                isMultiSelectMode = true;
                selectedFaultIndices.add(index);
              });
              // 长按完成时的反馈
              HapticFeedback.heavyImpact();
            }
          },
          onTap: () {
            if (isMultiSelectMode) {
              setState(() {
                if (isSelected) {
                  selectedFaultIndices.remove(index);
                } else {
                  selectedFaultIndices.add(index);
                }
              });
            }
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isSelected ? Colors.white.withOpacity(0.3) : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: isSelected ? Border.all(color: Colors.white, width: 2) : null,
            ),
            child: Row(
              children: [
                if (isMultiSelectMode) ...[
                  Icon(
                    isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                    color: Colors.white,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    '• $item',
                    style: const TextStyle(
                      fontSize: 36,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 忽略按钮：密码校验后写入忽略规则
  Widget _buildIgnoreButton(String message, String alertLevel) {
    return ElevatedButton(
      onPressed: () async {
        final ok = await _promptPasswordAndIgnore(message, alertLevel);
        if (ok && mounted) {
          _updateConnectionStatus();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已加入忽略规则')),
          );
        }
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.black, width: 2),
      ),
      child: const Text('忽略'),
    );
  }

  Future<bool> _promptPasswordAndIgnore(String message, String alertLevel) async {
    final controller = TextEditingController();
    DateTime? expiresAt;
    bool confirmed = false;
    await showGeneralDialog(
      context: context,
      pageBuilder: (ctx, anim1, anim2) {
        return AnimatedPadding(
          duration: const Duration(milliseconds: 200),
          padding: MediaQuery.of(ctx).viewInsets + const EdgeInsets.all(16),
          child: Center(
            child: Material(
              color: const Color(0xFFCBBE8E),
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
              child: Container(
                width: MediaQuery.of(ctx).size.width * 0.8,
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Color(0xFFCBBE8E),
                  border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 3)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      color: const Color(0xFF5D4037),
                      child: const Text('输入密码以忽略', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
                    ),
                    const SizedBox(height: 16),
                    Text('将忽略: $message', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black)),
                    const SizedBox(height: 16),
                    TextField(
                      controller: controller,
                      obscureText: true,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      decoration: const InputDecoration(
                        labelText: '管理员密码',
                        labelStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        border: OutlineInputBorder(borderSide: BorderSide(color: Colors.black, width: 3)),
                        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.black, width: 3)),
                        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.black, width: 3)),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: () {
                            expiresAt = null;
                            Navigator.of(ctx).pop(true);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1976D2),
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.black, width: 2),
                          ),
                          child: const Text('永久忽略', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: DateTime.now().add(const Duration(days: 1)),
                              firstDate: DateTime.now(),
                              lastDate: DateTime.now().add(const Duration(days: 365)),
                            );
                            if (picked != null) {
                              expiresAt = picked.add(const Duration(hours: 23, minutes: 59));
                              Navigator.of(ctx).pop(true);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1976D2),
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.black, width: 2),
                          ),
                          child: const Text('选择截止日期', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('取消', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ).then((v) { if (v == true) confirmed = true; });

    if (!confirmed) return false;
    if (!PasswordService().verifyPassword(controller.text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码错误')),
      );
      return false;
    }

    final alertType = _parseAlertTypeFromMessage(message);
    await IgnoreService().addIgnoreRule(
      nodeId: widget.nodeId.toString(),
      alertType: alertType,
      alertLevel: alertLevel,
      operator: 'admin',
      reason: '用户忽略',
      expiresAt: expiresAt,
    );
    return true;
  }

  String _parseAlertTypeFromMessage(String alert) {
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

  // 带图标的动作盒
  Widget _buildActionBoxWithIcon(String label, IconData icon, {VoidCallback? onTap, Color backgroundColor = Colors.black, Color textColor = const Color(0xFF00FF66)}) {
    final Widget content = Container(
      width: 198,
      height: 79,
      decoration: BoxDecoration(color: backgroundColor),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: textColor),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          GestureDetector(
            onTap: onTap,
            child: content,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // 第四列动作盒，样式与温度黑框一致
  Widget _buildActionBox(String label, {VoidCallback? onTap, Color backgroundColor = Colors.black, Color textColor = const Color(0xFF00FF66)}) {
    final Widget content = Container(
      width: 198,
      height: 79,
      decoration: BoxDecoration(color: backgroundColor),
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
    final Widget styledContent = Container(
      width: 198,
      height: 79,
      decoration: BoxDecoration(color: backgroundColor),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          GestureDetector(
            onTap: onTap,
            child: styledContent,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildStatusLight(String label, bool isActive) {
    Color lightColor;
    
    // 根据HarmonyOS原项目逻辑设置不同状态的颜色
    if (label == '已连接') {
      lightColor = isActive ? const Color(0xFF00C853) : const Color(0xFFBDBDBD);
    } else if (label == '正常') {
      lightColor = isActive ? const Color(0xFF00C853) : const Color(0xFFBDBDBD);
    } else if (label == '预警') {
      lightColor = isActive ? const Color(0xFFFF9800) : const Color(0xFFBDBDBD);
    } else if (label == '故障') {
      lightColor = isActive ? const Color(0xFFD50000) : const Color(0xFFBDBDBD);
    } else {
      lightColor = isActive ? const Color(0xFF00C853) : const Color(0xFFBDBDBD);
    }
    
    final bool isConnection = (label == '已连接' || label == '未连接');
    final double circleSize = isConnection ? 36 : 48;
    final double textSize = isConnection ? 24 : 28;
    final double borderW = isConnection ? 2 : 3;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: circleSize,
            height: circleSize,
            decoration: BoxDecoration(
              color: lightColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black, width: borderW),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: EdgeInsets.symmetric(horizontal: isConnection ? 8 : 10, vertical: isConnection ? 4 : 6),
            decoration: BoxDecoration(
              color: lightColor,
              border: Border.all(color: Colors.black, width: borderW),
            ),
            child: Text(
              label,
              style: TextStyle(fontSize: textSize, color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  // 矩形状态标签，颜色根据状态确定
  Widget _buildStatusLabel(String label, bool isActive, Color activeColor) {
    final color = isActive ? activeColor : const Color(0xFFBDBDBD);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: Colors.black, width: 2),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 28, color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  // 充满空间的状态方块
  Widget _buildStatusTile(String label, bool isActive, Color activeColor) {
    final Color color = isActive
        ? (_blinkOn ? activeColor : const Color(0xFFBDBDBD))
        : const Color(0xFFBDBDBD);
    return Container(
      color: color,
      child: Center(
        child: Text(
          label,
          style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildParameterRow(String label, String value, String unit) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 198,
            child: Text(
              label,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.black),
              textAlign: TextAlign.start,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Container(
                width: 198,
                height: 79,
                decoration: const BoxDecoration(
                  color: Colors.black,
                ),
                child: Center(
                  child: Text(
                    value,
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF00FF66),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                unit,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 显示设置对话框
  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return SettingsDialog(
          nodeId: widget.nodeId,
          onSettingsChanged: () {
            // 设置更改后刷新数据
            _loadPt100Corrections();
            unawaited(_updateDataFromNode());
          },
        );
      },
    );
  }

  // 构建系统状态区域内的操作按钮
  Widget _buildSystemStatusActionButtons() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // 取消按钮
          Expanded(
            child: ElevatedButton(
              onPressed: _cancelMultiSelect,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF757575),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                side: const BorderSide(color: Colors.black, width: 2),
              ),
              child: const Text(
                '取消',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 忽略按钮
          Expanded(
            child: ElevatedButton(
              onPressed: selectedFaultIndices.isNotEmpty ? _batchIgnoreSelected : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: selectedFaultIndices.isNotEmpty ? Colors.orange : Colors.grey,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                side: const BorderSide(color: Colors.black, width: 2),
              ),
              child: Text(
                '忽略 (${selectedFaultIndices.length})',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 取消多选模式
  void _cancelMultiSelect() {
    setState(() {
      isMultiSelectMode = false;
      selectedFaultIndices.clear();
    });
  }

  // 批量忽略选中的故障信息
  void _batchIgnoreSelected() async {
    if (selectedFaultIndices.isEmpty) return;

    // 获取选中的故障信息
    final faultItems = faultInfo.split('；').where((item) => item.trim().isNotEmpty).toList();
    final selectedFaults = selectedFaultIndices.map((index) => faultItems[index]).toList();

    // 显示密码输入对话框
    final controller = TextEditingController();
    DateTime? expiresAt;
    bool confirmed = false;
    
    await showGeneralDialog(
      context: context,
      pageBuilder: (ctx, anim1, anim2) {
        return AnimatedPadding(
          duration: const Duration(milliseconds: 200),
          padding: MediaQuery.of(ctx).viewInsets + const EdgeInsets.all(16),
          child: Center(
            child: Material(
              color: const Color(0xFFCBBE8E),
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
              child: Container(
                width: MediaQuery.of(ctx).size.width * 0.8,
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Color(0xFFCBBE8E),
                  border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 3)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      color: const Color(0xFF5D4037),
                      child: const Text('批量忽略故障信息', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
                    ),
                    const SizedBox(height: 16),
                    Text('将忽略 ${selectedFaultIndices.length} 条故障信息:', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black)),
                    const SizedBox(height: 8),
                    Container(
                      height: 120,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: Colors.black, width: 2),
                      ),
                      child: ListView.builder(
                        itemCount: selectedFaults.length,
                        itemBuilder: (context, index) {
                          return Text('• ${selectedFaults[index]}', style: const TextStyle(fontSize: 16));
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: controller,
                      obscureText: true,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      decoration: const InputDecoration(
                        labelText: '管理员密码',
                        labelStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        border: OutlineInputBorder(borderSide: BorderSide(color: Colors.black, width: 3)),
                        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.black, width: 3)),
                        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.black, width: 3)),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: () {
                            expiresAt = null;
                            Navigator.of(ctx).pop(true);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1976D2),
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.black, width: 2),
                          ),
                          child: const Text('永久忽略', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: DateTime.now().add(const Duration(days: 1)),
                              firstDate: DateTime.now(),
                              lastDate: DateTime.now().add(const Duration(days: 365)),
                            );
                            if (picked != null) {
                              expiresAt = picked.add(const Duration(hours: 23, minutes: 59));
                              Navigator.of(ctx).pop(true);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1976D2),
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.black, width: 2),
                          ),
                          child: const Text('选择截止日期', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('取消', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ).then((v) { if (v == true) confirmed = true; });

    if (!confirmed) return;
    if (!PasswordService().verifyPassword(controller.text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码错误')),
      );
      return;
    }

    // 批量添加忽略规则
    for (final faultText in selectedFaults) {
      final alertType = _parseAlertTypeFromMessage(faultText);
      final alertLevel = faultText.contains('故障') ? 'fault' : 'warning';
      
      await IgnoreService().addIgnoreRule(
        nodeId: widget.nodeId.toString(),
        alertType: alertType,
        alertLevel: alertLevel,
        operator: 'admin',
        reason: '批量忽略',
        expiresAt: expiresAt,
      );
    }

    // 退出多选模式并刷新状态
    setState(() {
      isMultiSelectMode = false;
      selectedFaultIndices.clear();
    });

    _updateConnectionStatus();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已批量忽略 ${selectedFaults.length} 条故障信息')),
    );
  }
}

// 设置对话框
class SettingsDialog extends StatefulWidget {
  final VoidCallback onSettingsChanged;
  final int nodeId;

  const SettingsDialog({super.key, required this.onSettingsChanged, required this.nodeId});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> with TickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _passwordController = TextEditingController();
  bool _isPasswordCorrect = false;

  // 阈值设置控制器
  final TextEditingController _tempStartController = TextEditingController();
  final TextEditingController _tempWarningController = TextEditingController();
  final TextEditingController _tempFaultController = TextEditingController();
  
  // ABC三相k1、k2参数控制器
  final TextEditingController _aK1Controller = TextEditingController();
  final TextEditingController _aK2Controller = TextEditingController();
  final TextEditingController _bK1Controller = TextEditingController();
  final TextEditingController _bK2Controller = TextEditingController();
  final TextEditingController _cK1Controller = TextEditingController();
  final TextEditingController _cK2Controller = TextEditingController();
  
  final TextEditingController _h2FaultController = TextEditingController();
  final TextEditingController _coFaultController = TextEditingController();
  final TextEditingController _smokeFaultController = TextEditingController();
  final TextEditingController _h2WarningController = TextEditingController();
  final TextEditingController _coWarningController = TextEditingController();
  final TextEditingController _humidityWarningController = TextEditingController();
  final TextEditingController _humidityFaultController = TextEditingController();
  final TextEditingController _humidityFaultHoursController = TextEditingController();
  final TextEditingController _pressureWarningLowController = TextEditingController();
  final TextEditingController _pressureFaultController = TextEditingController();
  final TextEditingController _humidityCorrectionController = TextEditingController();

  // PT100误差修正控制器
  final List<TextEditingController> _pt100Controllers = List.generate(
    10, 
    (index) => TextEditingController(),
  );
  // 环境温度修正控制器（上/中/下）
  final TextEditingController _envUpperController = TextEditingController();
  final TextEditingController _envMiddleController = TextEditingController();
  final TextEditingController _envLowerController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadCurrentSettings();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _passwordController.dispose();
    _tempStartController.dispose();
    _tempWarningController.dispose();
    _tempFaultController.dispose();
    
    _aK1Controller.dispose();
    _aK2Controller.dispose();
    _bK1Controller.dispose();
    _bK2Controller.dispose();
    _cK1Controller.dispose();
    _cK2Controller.dispose();
    
    _h2FaultController.dispose();
    _coFaultController.dispose();
    _smokeFaultController.dispose();
    _h2WarningController.dispose();
    _coWarningController.dispose();
    _humidityWarningController.dispose();
    _humidityFaultController.dispose();
    _humidityFaultHoursController.dispose();
    _pressureWarningLowController.dispose();
    _pressureFaultController.dispose();
    _humidityCorrectionController.dispose();
    for (var controller in _pt100Controllers) {
      controller.dispose();
    }
    _envUpperController.dispose();
    _envMiddleController.dispose();
    _envLowerController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentSettings() async {
    final settings = await SettingsService().getAllSettingsForNode(widget.nodeId);
    
    _tempStartController.text = settings['tempStart'].toString();
    _tempWarningController.text = settings['tempWarning'].toString();
    _tempFaultController.text = settings['tempFault'].toString();
    
    _aK1Controller.text = settings['aK1'].toString();
    _aK2Controller.text = settings['aK2'].toString();
    _bK1Controller.text = settings['bK1'].toString();
    _bK2Controller.text = settings['bK2'].toString();
    _cK1Controller.text = settings['cK1'].toString();
    _cK2Controller.text = settings['cK2'].toString();
    
    _h2FaultController.text = settings['h2Fault'].toString();
    _h2WarningController.text = settings['h2Warning'].toString();
    _coFaultController.text = settings['coFault'].toString();
    _coWarningController.text = settings['coWarning'].toString();
    _smokeFaultController.text = settings['smokeFault'].toString();
    _humidityWarningController.text = settings['humidityWarning'].toString();
    _humidityFaultController.text = settings['humidityFault'].toString();
    _humidityFaultHoursController.text = settings['humidityFaultHours'].toString();
    _pressureWarningLowController.text = settings['pressureWarning'].toString();
    _pressureFaultController.text = settings['pressureFault'].toString();
    _humidityCorrectionController.text = (settings['humidityCorrection'] as double? ?? 0.0).toString();
    
    final corrections = settings['pt100Corrections'] as List<dynamic>? ?? List.filled(10, 0.0);
    for (int i = 0; i < 10; i++) {
      _pt100Controllers[i].text = (corrections[i] as double? ?? 0.0).toString();
      if (_pt100Controllers[i].text.isEmpty) _pt100Controllers[i].text = '0.0';
    }
    // 环境温度修正：上/中/下
    final upperTemp = settings['upperTempCorrection'] as double? ?? 0.0;
    final middleTemp = settings['envTempCorrection'] as double? ?? 0.0;
    final lowerTemp = settings['lowerTempCorrection'] as double? ?? 0.0;
    print('读取温度修正值 - 节点${widget.nodeId}: 上=${upperTemp}, 中=${middleTemp}, 下=${lowerTemp}');
    _envUpperController.text = upperTemp.toString();
    _envMiddleController.text = middleTemp.toString();
    _envLowerController.text = lowerTemp.toString();
    if (_envUpperController.text.isEmpty) _envUpperController.text = '0.0';
    if (_envMiddleController.text.isEmpty) _envMiddleController.text = '0.0';
    if (_envLowerController.text.isEmpty) _envLowerController.text = '0.0';
  }

  void _verifyPassword() {
    if (PasswordService().verifyPassword(_passwordController.text)) {
      setState(() {
        _isPasswordCorrect = true;
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('密码错误！'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _saveSettings() async {
    try {
      // 验证温度阈值逻辑：起点 < 预警 < 故障
      final tempStart = double.parse(_tempStartController.text);
      final tempWarning = double.parse(_tempWarningController.text);
      final tempFault = double.parse(_tempFaultController.text);
      
      if (tempStart >= tempWarning) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('温度起点必须小于预警阈值'), backgroundColor: Colors.red),
        );
        return;
      }
      
      if (tempWarning >= tempFault) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('温度预警阈值必须小于故障阈值'), backgroundColor: Colors.red),
        );
        return;
      }
      
      // 验证湿度阈值逻辑：预警 < 故障
      final humidityWarning = double.parse(_humidityWarningController.text);
      final humidityFault = double.parse(_humidityFaultController.text);
      
      if (humidityWarning >= humidityFault) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('湿度预警阈值必须小于故障阈值'), backgroundColor: Colors.red),
        );
        return;
      }
      
      // 验证压力阈值逻辑：预警 < 故障
      final pressureWarning = double.parse(_pressureWarningLowController.text);
      final pressureFault = double.parse(_pressureFaultController.text);
      
      if (pressureWarning >= pressureFault) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('压力预警阈值必须小于故障阈值'), backgroundColor: Colors.red),
        );
        return;
      }
      
      // 验证数值范围
      if (tempStart < 0 || tempStart > 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('温度起点必须在0-200°C范围内'), backgroundColor: Colors.red),
        );
        return;
      }
      
      if (tempWarning < 0 || tempWarning > 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('温度预警阈值必须在0-200°C范围内'), backgroundColor: Colors.red),
        );
        return;
      }
      
      if (tempFault < 0 || tempFault > 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('温度故障阈值必须在0-200°C范围内'), backgroundColor: Colors.red),
        );
        return;
      }
      
      if (humidityWarning < 0 || humidityWarning > 100) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('湿度预警阈值必须在0-100%RH范围内'), backgroundColor: Colors.red),
        );
        return;
      }
      
      if (humidityFault < 0 || humidityFault > 100) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('湿度故障阈值必须在0-100%RH范围内'), backgroundColor: Colors.red),
        );
        return;
      }
      
      if (pressureWarning < 0 || pressureWarning > 1000) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('压力预警阈值必须在0-1000kPa范围内'), backgroundColor: Colors.red),
        );
        return;
      }
      
      if (pressureFault < 0 || pressureFault > 1000) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('压力故障阈值必须在0-1000kPa范围内'), backgroundColor: Colors.red),
        );
        return;
      }
      
      // 验证气体浓度阈值范围
      final h2Fault = double.parse(_h2FaultController.text);
      final coFault = double.parse(_coFaultController.text);
      final smokeFault = double.parse(_smokeFaultController.text);
      
      if (h2Fault < 0 || h2Fault > 100) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('氢气故障阈值必须在0-100%LEL范围内'), backgroundColor: Colors.red),
        );
        return;
      }
      
      if (coFault < 0 || coFault > 10000) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('一氧化碳故障阈值必须在0-10000ppm范围内'), backgroundColor: Colors.red),
        );
        return;
      }
      
      if (smokeFault < 0 || smokeFault > 10) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('烟雾故障阈值必须在0-10DB范围内'), backgroundColor: Colors.red),
        );
        return;
      }
      
      // 验证湿度故障时间阈值
      final humidityFaultHours = int.parse(_humidityFaultHoursController.text);
      if (humidityFaultHours < 1 || humidityFaultHours > 168) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('湿度故障时间阈值必须在1-168小时范围内'), backgroundColor: Colors.red),
        );
        return;
      }
      
      // 保存阈值设置（节点特定）
      await SettingsService().updateTempThresholdsForNode(
        widget.nodeId,
        tempStart,
        tempWarning,
        tempFault,
      );
      
      await SettingsService().updateGasThresholdsForNode(
        widget.nodeId,
        double.parse(_h2FaultController.text),
        double.parse(_coFaultController.text),
        double.parse(_smokeFaultController.text),
      );
      await SettingsService().updateGasWarningThresholdsForNode(
        widget.nodeId,
        double.parse(_h2WarningController.text),
        double.parse(_coWarningController.text),
      );
      
      await SettingsService().updateHumidityThresholdsForNode(
        widget.nodeId,
        double.parse(_humidityWarningController.text),
        double.parse(_humidityFaultController.text),
        int.parse(_humidityFaultHoursController.text),
      );
      
      await SettingsService().updatePressureThresholdsForNode(
        widget.nodeId,
        double.parse(_pressureWarningLowController.text),
        double.parse(_pressureFaultController.text),
      );
      
      // 保存湿度修正（节点特定）
      final humidityCorr = double.tryParse(_humidityCorrectionController.text) ?? 0.0;
      await SettingsService().updateHumidityCorrectionForNode(widget.nodeId, humidityCorr);
      
      // 保存PT100误差修正（节点特定）
      final corrections = _pt100Controllers.map((c) => double.tryParse(c.text) ?? 0.0).toList();
      await SettingsService().updatePt100CorrectionsForNode(widget.nodeId, corrections);

      // 保存环境温度修正（节点特定）
      final upperC = double.tryParse(_envUpperController.text) ?? 0.0;
      final middleC = double.tryParse(_envMiddleController.text) ?? 0.0;
      final lowerC = double.tryParse(_envLowerController.text) ?? 0.0;
      print('保存温度修正值 - 节点${widget.nodeId}: 上=${upperC}, 中=${middleC}, 下=${lowerC}');
      await SettingsService().updateEnvTempCorrectionsForNode(widget.nodeId, upperC, middleC, lowerC);
      print('温度修正值保存完成');
      
      // 验证和保存ABC三相k1、k2参数
      final aK1 = double.parse(_aK1Controller.text);
      final aK2 = double.parse(_aK2Controller.text);
      final bK1 = double.parse(_bK1Controller.text);
      final bK2 = double.parse(_bK2Controller.text);
      final cK1 = double.parse(_cK1Controller.text);
      final cK2 = double.parse(_cK2Controller.text);
      
      // 验证k1、k2参数范围（0-20）
      final kParams = [
        {'name': 'A相K1', 'value': aK1},
        {'name': 'A相K2', 'value': aK2},
        {'name': 'B相K1', 'value': bK1},
        {'name': 'B相K2', 'value': bK2},
        {'name': 'C相K1', 'value': cK1},
        {'name': 'C相K2', 'value': cK2},
      ];
      
      for (final param in kParams) {
        final value = param['value'] as double;
        if (value < 0 || value > 20) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${param['name']}参数必须在0-20范围内'), backgroundColor: Colors.red),
          );
          return;
        }
      }
      
      // 保存ABC三相k1、k2参数（节点特定）
      await SettingsService().updatePhaseKParamsForNode(
        widget.nodeId, aK1, aK2, bK1, bK2, cK1, cK2,
      );
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('设置已保存'),
          backgroundColor: Colors.green,
        ),
      );
      
      widget.onSettingsChanged();
      Navigator.of(context).pop();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFFCBBE8E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
          minHeight: 400,
        ),
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: Color(0xFFCBBE8E),
          border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 3)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
            // 标题
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: const BoxDecoration(
                color: Color(0xFF5D4037),
                border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 2)),
              ),
              child: const Text(
                '系统设置',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            const SizedBox(height: 20),
            
            // 密码验证
            if (!_isPasswordCorrect) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFFE8F5E9),
                  border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 2)),
                ),
                child: Column(
                  children: [
                    const Text(
                      '请输入密码以进入设置',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.black, width: 3),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.black, width: 3),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.black, width: 3),
                        ),
                        labelText: '密码',
                        labelStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black),
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: _verifyPassword,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1976D2),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                        side: const BorderSide(color: Colors.black, width: 2),
                      ),
                      child: const Text('验证密码', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ] else ...[
              // 设置内容
              Container(
                decoration: const BoxDecoration(
                  color: Color(0xFF5D4037),
                  border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 2)),
                ),
                child: TabBar(
                  controller: _tabController,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.grey,
                  indicatorColor: Colors.white,
                  indicatorWeight: 3,
                  labelStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  unselectedLabelStyle: const TextStyle(fontSize: 14),
                  tabs: const [
                    Tab(text: '阈值设置'),
                    Tab(text: '参数修正'),
                    Tab(text: '忽略管理'),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFFE8F5E9),
                    border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 2)),
                  ),
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildThresholdSettings(),
                      _buildErrorCorrectionSettings(),
                      _buildIgnoreManagement(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF757575),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                      side: const BorderSide(color: Colors.black, width: 2),
                    ),
                    child: const Text('取消', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  ElevatedButton(
                    onPressed: _saveSettings,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1976D2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                      side: const BorderSide(color: Colors.black, width: 2),
                    ),
                    child: const Text('保存', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildThresholdSettings() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('温度阈值设置'),
          _buildThresholdRow('温度起点阈值(°C)', _tempStartController),
          _buildThresholdRow('温度预警阈值(°C)', _tempWarningController),
          _buildThresholdRow('温度故障阈值(°C)', _tempFaultController),
          
          const SizedBox(height: 20),
          _buildSectionTitle('气体浓度阈值设置'),
          _buildThresholdRow('氢气预警阈值(%LEL)', _h2WarningController),
          _buildThresholdRow('氢气故障阈值(%LEL)', _h2FaultController),
          _buildThresholdRow('一氧化碳预警阈值(ppm)', _coWarningController),
          _buildThresholdRow('一氧化碳故障阈值(ppm)', _coFaultController),
          _buildThresholdRow('烟雾故障阈值(DB)', _smokeFaultController),
          
          const SizedBox(height: 20),
          _buildSectionTitle('湿度阈值设置'),
          _buildThresholdRow('湿度预警阈值(%RH)', _humidityWarningController),
          _buildThresholdRow('湿度故障阈值(%RH)', _humidityFaultController),
          _buildThresholdRow('湿度故障时间阈值(小时)', _humidityFaultHoursController),
          
          const SizedBox(height: 20),
          _buildSectionTitle('压力阈值设置'),
          _buildThresholdRow('压力预警阈值(kPa)', _pressureWarningLowController),
          _buildThresholdRow('压力故障阈值(kPa)', _pressureFaultController),
        ],
      ),
    );
  }

  Widget _buildIgnoreManagement() {
    final rules = IgnoreService().getAllIgnoreRules();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('忽略规则列表'),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 2)),
              ),
              child: ListView.separated(
                itemCount: rules.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.black),
                itemBuilder: (context, index) {
                  final r = rules[index];
                  final status = r.isActive ? '启用' : '停用';
                  final expires = r.expiresAt == null ? '永久' : _formatDateTime(r.expiresAt!);
                  return ListTile(
                    dense: true,
                    title: Text('[${r.alertLevel}] ${r.alertType}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 32)),
                    subtitle: Text('节点:${r.nodeId}  操作:${r.operator}  于:${_formatDateTime(r.createTime)}  截止:${expires}  状态:${status}',
                        style: const TextStyle(fontSize: 24)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () async {
                            await IgnoreService().toggleIgnoreRule(r.id, !r.isActive);
                            setState(() {});
                          },
                          child: Text(r.isActive ? '停用' : '启用',
                              style: TextStyle(fontSize: 20, color: r.isActive ? Colors.orange : Colors.green, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () async {
                            await IgnoreService().removeIgnoreRule(r.id);
                            setState(() {});
                          },
                          child: const Text('删除', style: TextStyle(fontSize: 20, color: Colors.red, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }

  Widget _buildSectionTitle(String title) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF5D4037),
        border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 2)),
      ),
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildErrorCorrectionSettings() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('参数修正'),

          // A相温度修正（左外/中/右外）
          _buildThresholdRow('A相 左外温度修正(°C)', _pt100Controllers[0]),
          _buildThresholdRow('A相 中温度修正(°C)', _pt100Controllers[1]),
          _buildThresholdRow('A相 右外温度修正(°C)', _pt100Controllers[2]),

          const SizedBox(height: 12),
          // B相
          _buildThresholdRow('B相 左外温度修正(°C)', _pt100Controllers[3]),
          _buildThresholdRow('B相 中温度修正(°C)', _pt100Controllers[4]),
          _buildThresholdRow('B相 右外温度修正(°C)', _pt100Controllers[5]),

          const SizedBox(height: 12),
          // C相
          _buildThresholdRow('C相 左外温度修正(°C)', _pt100Controllers[6]),
          _buildThresholdRow('C相 中温度修正(°C)', _pt100Controllers[7]),
          _buildThresholdRow('C相 右外温度修正(°C)', _pt100Controllers[8]),

          const SizedBox(height: 12),
          // 防爆盒内上/中/下温
          _buildThresholdRow('防爆盒 上温度修正(°C)', _envUpperController),
          _buildThresholdRow('防爆盒 中温度修正(°C)', _envMiddleController),
          _buildThresholdRow('防爆盒 下温度修正(°C)', _envLowerController),
          
          const SizedBox(height: 12),
          _buildThresholdRow('湿度修正(%RH)', _humidityCorrectionController),
          
          const SizedBox(height: 20),
          _buildSectionTitle('ABC三相内温度计算参数'),
          _buildThresholdRow('A相K1参数(环境温度系数)', _aK1Controller),
          _buildThresholdRow('A相K2参数(三相平均系数)', _aK2Controller),
          _buildThresholdRow('B相K1参数(环境温度系数)', _bK1Controller),
          _buildThresholdRow('B相K2参数(三相平均系数)', _bK2Controller),
          _buildThresholdRow('C相K1参数(环境温度系数)', _cK1Controller),
          _buildThresholdRow('C相K2参数(三相平均系数)', _cK2Controller),
        ],
      ),
    );
  }

  Widget _buildThresholdRow(String label, TextEditingController controller) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 2)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 1,
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.black, width: 3),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.black, width: 3),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.black, width: 3),
                ),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                filled: true,
                fillColor: Color(0xFFF5F5F5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}




