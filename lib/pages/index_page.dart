import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import '../providers/sensor_provider.dart';
import '../models/node_data.dart';
import '../services/alert_service.dart';
import '../services/password_service.dart';
import '../services/settings_service.dart';
import '../services/serial_debug_logger.dart';
import '../services/csv_logger_service.dart';
import 'data_detail_page.dart';
import 'daily_history_page.dart';

class IndexPage extends StatefulWidget {
  const IndexPage({super.key});

  @override
  State<IndexPage> createState() => _IndexPageState();
}

class _IndexPageState extends State<IndexPage> {
  String nowText = '';
  
  // 折叠状态管理：节点ID -> 是否展开
  final Map<int, bool> _expandedStates = {};

  @override
  void initState() {
    super.initState();
    _tick();
  }

  // 根据系统状态计算卡片背景色
  Future<Color> _computeCardColor(NodeData? node) async {
    if (node == null) return const Color(0xFFBDBDBD); // 灰色表示未连接
    
    // 检查连接状态
    final now = DateTime.now().millisecondsSinceEpoch;
    final isStale = node.lastUpdateTimestamp == null || (now - node.lastUpdateTimestamp! > 40000);
    
    if (isStale) return const Color(0xFFBDBDBD); // 灰色表示未连接
    
    // 检查是否有数据
    final hasData = node.temperature != null || node.humidity != null || node.coPpm != null || 
        node.h2Percentage != null || node.pressureKpa != null || node.smokeChannelA != null || 
        node.smokeChannelB != null || (node.pt100Temperatures != null && node.pt100Temperatures!.isNotEmpty);
    
    if (!hasData) return const Color(0xFFBDBDBD); // 灰色表示未连接
    
    // 有数据时根据系统状态显示颜色
    try {
      final hex = await node.getSystemStatusColor(); // e.g. '#00C853'
      final value = int.parse(hex.substring(1), radix: 16) + 0xFF000000;
      return Color(value);
    } catch (_) {
      return const Color(0xFFBDBDBD);
    }
  }

  // 获取显示状态：未连接时显示未连接，否则显示系统状态
  Future<String> _getDisplayStatus(NodeData? node) async {
    if (node == null) return '未连接';
    
    // 检查连接状态
    final now = DateTime.now().millisecondsSinceEpoch;
    final isStale = node.lastUpdateTimestamp == null || (now - node.lastUpdateTimestamp! > 40000);
    
    if (isStale) return '未连接';
    
    // 检查是否有数据
    final hasData = node.temperature != null || node.humidity != null || node.coPpm != null || 
        node.h2Percentage != null || node.pressureKpa != null || node.smokeChannelA != null || 
        node.smokeChannelB != null || (node.pt100Temperatures != null && node.pt100Temperatures!.isNotEmpty);
    
    if (!hasData) return '未连接';
    
    // 有数据时显示系统状态
    return await node.getSystemStatusText();
  }

  // 构造A/B/C中内温度（基于pt100通道 + 公式计算）
  Widget _buildCoreTempsRow(NodeData? node) {
    String fmt(double? v) => v == null ? '--' : v.toStringAsFixed(1);
    if (node?.pt100Temperatures == null || node!.pt100Temperatures!.length < 12) {
      return Row(
        children: [
          // 湿度
          Expanded(child: _buildDataBox('湿度', '--', '%RH')),
          const SizedBox(width: 12),
          // A/B/C
          Expanded(child: _buildDataBox('A中内', '--', '°C')),
          const SizedBox(width: 12),
          Expanded(child: _buildDataBox('B中内', '--', '°C')),
          const SizedBox(width: 12),
          Expanded(child: _buildDataBox('C中内', '--', '°C')),
        ],
      );
    }
    final t = node.pt100Temperatures!;
    
    // 使用与详细页面相同的计算逻辑
    return FutureBuilder<Map<String, dynamic>>(
      future: _calculateCoreTempsWithSettings(node),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Row(
            children: [
              Expanded(child: _buildDataBox('湿度', '--', '%RH')),
              const SizedBox(width: 12),
              Expanded(child: _buildDataBox('A中内', '--', '°C')),
              const SizedBox(width: 12),
              Expanded(child: _buildDataBox('B中内', '--', '°C')),
              const SizedBox(width: 12),
              Expanded(child: _buildDataBox('C中内', '--', '°C')),
            ],
          );
        }
        
        final data = snapshot.data!;
        final humidityVal = node.humidity == null ? '--' : node.humidity!.toStringAsFixed(1);
        
        return Row(
          children: [
            Expanded(child: _buildDataBox('湿度', humidityVal, '%RH')),
            const SizedBox(width: 12),
            Expanded(child: _buildDataBox('A中内', data['aCore'].isNaN ? '--' : fmt(data['aCore']), '°C')),
            const SizedBox(width: 12),
            Expanded(child: _buildDataBox('B中内', data['bCore'].isNaN ? '--' : fmt(data['bCore']), '°C')),
            const SizedBox(width: 12),
            Expanded(child: _buildDataBox('C中内', data['cCore'].isNaN ? '--' : fmt(data['cCore']), '°C')),
          ],
        );
      },
    );
  }

  // 使用与详细页面相同的计算逻辑计算中内温度
  Future<Map<String, dynamic>> _calculateCoreTempsWithSettings(NodeData node) async {
    final t = node.pt100Temperatures!;
    
    // 获取节点设置
    final settings = SettingsService();
    final nodeSettings = await settings.getAllSettingsForNode(node.nodeId);
    final upperCorr = nodeSettings['upperTempCorrection'] as double? ?? 0.0;
    final middleCorr = nodeSettings['envTempCorrection'] as double? ?? 0.0;
    final lowerCorr = nodeSettings['lowerTempCorrection'] as double? ?? 0.0;
    
    // 获取节点特定的PT100修正值
    final pt100Corrections = nodeSettings['pt100Corrections'] as List<dynamic>? ?? List.filled(10, 0.0);
    
    // 应用误差修正：开路(-999)保持不变，否则加上修正值
    final corrected = List<double>.generate(
      t.length,
      (i) {
        final base = t[i];
        if (base == -999) return -999;
        final delta = i < pt100Corrections.length ? (pt100Corrections[i] as double? ?? 0.0) : 0.0;
        return base + delta;
      },
    );
    
    // 计算三相平均值
    final leftAvg = (corrected[0] + corrected[3] + corrected[6]) / 3;   // 左外温度平均值
    final middleAvg = (corrected[1] + corrected[4] + corrected[7]) / 3; // 中外温度平均值  
    final rightAvg = (corrected[2] + corrected[5] + corrected[8]) / 3;  // 右外温度平均值
    
    // 获取节点特定的k1、k2参数
    final aK1 = nodeSettings['aK1'] as double? ?? 6.42;
    final aK2 = nodeSettings['aK2'] as double? ?? 2.5;
    final bK1 = nodeSettings['bK1'] as double? ?? 6.42;
    final bK2 = nodeSettings['bK2'] as double? ?? 2.5;
    final cK1 = nodeSettings['cK1'] as double? ?? 6.42;
    final cK2 = nodeSettings['cK2'] as double? ?? 2.5;
    
    // 计算环境温度
    double upperTemp = 25.0 + upperCorr;
    double middleTemp = (node.temperature ?? 25.0) + middleCorr;
    double lowerTemp = (node.temperature ?? 25.0) + lowerCorr;
    
    // 如果有PT100数据，使用PT100通道9作为上温度
    if (t.length >= 10) {
      final pt9Temp = corrected[9];
      if (pt9Temp != -999) {
        upperTemp = pt9Temp + upperCorr;
      }
    }
    
    // 如果有PT100数据，使用PT100通道11作为中温度
    if (t.length >= 12) {
      final pt11Temp = corrected[11];
      if (pt11Temp != -999) {
        middleTemp = pt11Temp + middleCorr;
      }
    }
    
    // 计算中内温度：Y = xi + k1·max(0, xi – x0i) + k2·max(0, xi – xia)
    double calcInnerTemp(double xi, double x0i, double xia, double k1, double k2) {
      if (xi == -999) return double.nan;
      
      // 当外温度小于环境温度时，中内温度等于中外温度
      if (xi < x0i) {
        return xi;
      }
      
      final deltaEnv = xi - x0i;
      final deltaPhaseAvg = xi - xia;
      final nonNegativeEnv = deltaEnv < 0 ? 0 : deltaEnv;
      final nonNegativePhaseAvg = deltaPhaseAvg < 0 ? 0 : deltaPhaseAvg;
      return xi + k1 * nonNegativeEnv + k2 * nonNegativePhaseAvg;
    }
    
    // A相中内温度计算（环境温度为上温度，使用中外温度平均值）
    final aCore = calcInnerTemp(corrected[1], upperTemp, middleAvg, aK1, aK2);
    
    // B相中内温度计算（环境温度为中温度，使用中外温度平均值）
    final bCore = calcInnerTemp(corrected[4], middleTemp, middleAvg, bK1, bK2);
    
    // C相中内温度计算（环境温度为下温度，使用中外温度平均值）
    final cCore = calcInnerTemp(corrected[7], lowerTemp, middleAvg, cK1, cK2);
    
    return {
      'aCore': aCore,
      'bCore': bCore,
      'cCore': cCore,
    };
  }

  Widget _buildDataBox(String label, String value, String unit) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 2),
        Container(
          decoration: const BoxDecoration(color: Colors.black),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF00FF66))),
              const SizedBox(width: 3),
              Text(unit, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
            ],
          ),
        ),
      ],
    );
  }

  // 湿度展示（三倍字号）
  Future<Widget> _buildHumidityRow(NodeData? node) async {
    final String humidityText = '湿度: ${node?.humidity == null ? '--' : node!.humidity!.toStringAsFixed(1)}%RH';
    final Color sysColor = node != null ? Color(int.parse((await node.getSystemStatusColor()).substring(1), radix: 16) + 0xFF000000) : const Color(0xFFBDBDBD);
    final String displayStatus = await _getDisplayStatus(node);
    return Row(
      children: [
        // 与A/B/C中内三列对齐：每列一个Expanded
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                humidityText,
                style: const TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 18, height: 18, decoration: BoxDecoration(color: sysColor, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(displayStatus, style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // 空白占位，保持布局对齐
        const Expanded(child: SizedBox()),
      ],
    );
  }
  void _tick() {
    nowText = _nowString();
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() {
        nowText = _nowString();
      });
      _tick();
    });
  }

  String _nowString() {
    final now = DateTime.now();
    String to2(int n) => n < 10 ? '0$n' : '$n';
    return '${now.year}/${to2(now.month)}/${to2(now.day)}  ${to2(now.hour)}:${to2(now.minute)}:${to2(now.second)}';
  }

  String _getDateString() {
    final now = DateTime.now();
    String to2(int n) => n < 10 ? '0$n' : '$n';
    return '${now.year}/${to2(now.month)}/${to2(now.day)}';
  }

  String _getTimeString() {
    final now = DateTime.now();
    String to2(int n) => n < 10 ? '0$n' : '$n';
    return '${to2(now.hour)}:${to2(now.minute)}:${to2(now.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SensorProvider>(
      builder: (context, sensorProvider, child) {
        return Scaffold(
          backgroundColor: const Color(0xFFB6A56A),
          body: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 顶部栏：图标+居中标题+右时间（对齐节点详情的样式）
                  Container(
                    color: const Color(0xFFCBBE8E),
                    padding: const EdgeInsets.fromLTRB(24, 48, 24, 48),
                    child: Stack(
                      children: [
                        // 左上角：两个图标紧挨着，在图层最顶层
                        Positioned(
                          left: 40,
                          top: 20,
                          child: Container(
                            color: const Color(0xFFCBBE8E),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Image(
                                  image: AssetImage('assets/media/coo.png'), 
                                  width: 100, 
                                  height: 100
                                ),
                                const SizedBox(width: 16),
                                const Image(
                                  image: AssetImage('assets/media/hit1.png'), 
                                  width: 100, 
                                  height: 100
                                ),
                              ],
                            ),
                          ),
                        ),
                        
                        // 中间：标题（放大1倍，居中）
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 16, bottom: 24),
                            child: const Text(
                              '电缆中间接头关键参数监测系统',
                              style: TextStyle(fontSize: 72, fontWeight: FontWeight.bold, color: Colors.black),
                            ),
                          ),
                        ),
                        
                        // 右侧时间（两行显示）
                        Positioned(
                          right: 0,
                          top:20,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                _getDateString(),
                                style: const TextStyle(fontSize: 32, color: Colors.black, fontWeight: FontWeight.w600),
                              ),
                              Text(
                                _getTimeString(),
                                style: const TextStyle(fontSize: 32, color: Colors.black, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  Container(
                    width: double.infinity,
                    color: const Color(0xFF5D4037),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: SelectableText(
                      '版本1.0.22 固定/dev/ttyS7    串口: ${sensorProvider.connectionStatus}    数据记录: ${CsvLoggerService.instance.displayPath ?? "初始化中"}    调试日志: ${SerialDebugLogger.instance.displayPath ?? "初始化中"}',
                      style: const TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ),
                  
                  // 节点卡片容器
                  Expanded(
                    child: Container(
                      color: const Color(0xFFB6A56A),
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: Builder(
                        builder: (_) {
                          // 固定显示2个节点卡片+1个按钮卡片，左右布局
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              // 左侧：2个节点卡片垂直排列
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _buildNodeCard(context, sensorProvider, 6),
                                  const SizedBox(height: 48),
                                  _buildNodeCard(context, sensorProvider, 7),
                                ],
                              ),
                              // 右侧：按钮容器
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _buildButtonCard(context),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
              
              
              // 去掉“开始记录”按钮
            ],
          ),
        );
      },
    );
  }

  Future<Widget> _buildAlertInfoSection(NodeData? node) async {
    if (node == null) return const SizedBox.shrink();
    
    final alertInfo = await AlertService().analyzeNodeData(node);
    final hasAlerts = alertInfo.warnings.isNotEmpty || alertInfo.faults.isNotEmpty;
    
    if (!hasAlerts) return const SizedBox.shrink();
    
    final isExpanded = _expandedStates[node.nodeId] ?? false;
    
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          // 折叠/展开按钮
          InkWell(
            onTap: () {
              setState(() {
                _expandedStates[node.nodeId] = !isExpanded;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '预警信息 (${alertInfo.warnings.length}) | 故障信息 (${alertInfo.faults.length})',
                    style: const TextStyle(
                      fontSize: 16,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // 展开的内容
          if (isExpanded) ...[
            const Divider(color: Colors.white54, height: 1),
            Container(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 预警信息
                  if (alertInfo.warnings.isNotEmpty) ...[
                    const Text(
                      '预警信息:',
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...alertInfo.warnings.map((warning) => Container(
                      margin: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '• $warning',
                        style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xFFFFA726), // 黄色
                        ),
                      ),
                    )),
                    const SizedBox(height: 8),
                  ],
                  
                  // 故障信息
                  if (alertInfo.faults.isNotEmpty) ...[
                    const Text(
                      '故障信息:',
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...alertInfo.faults.map((fault) => Container(
                      margin: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '• $fault',
                        style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xFFD50000), // 红色
                        ),
                      ),
                    )),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSensorStatus(String name, int status, int? lastUpdateTimestamp) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final isStale = lastUpdateTimestamp == null || (now - lastUpdateTimestamp) > 40000;
    final color = isStale ? const Color(0xFFD50000)
        : (status > 0 ? const Color(0xFF00C853) : const Color(0xFFD50000));
    return Container(
      margin: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 15,
            height: 15,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            name,
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
        ],
      ),
    );
  }

  void _showAddNodeDialog(BuildContext context, SensorProvider sensorProvider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加节点'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入节点ID (6-7)',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final nodeId = int.tryParse(controller.text);
              if (nodeId != null && (nodeId == 6 || nodeId == 7)) {
                sensorProvider.addNode(nodeId);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已添加节点$nodeId')),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入有效的节点ID (6或7)')),
                );
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Widget _buildButtonCard(BuildContext context) {
    return SizedBox(
      width: MediaQuery.of(context).size.width * 0.45,
      child: Column(
        children: [
          // 历史数据按钮
          SizedBox(
            width: MediaQuery.of(context).size.width * 0.45,
            height: 200, // 等于卡片高度
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                side: const BorderSide(color: Colors.indigo, width: 2),
              ),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const DailyHistoryPage()),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.history, size: 64, color: Colors.white),
                  SizedBox(height: 8),
                  Text('历史数据', style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 48),
          // 修改密码按钮
          SizedBox(
            width: MediaQuery.of(context).size.width * 0.45,
            height: 200, // 等于卡片高度
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5D4037),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                side: const BorderSide(color: Colors.indigo, width: 2),
              ),
              onPressed: _showChangePasswordDialog,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.lock, size: 64, color: Colors.white),
                  SizedBox(height: 8),
                  Text('修改密码', style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNodeCard(BuildContext context, SensorProvider sensorProvider, int nodeId) {
    final node = sensorProvider.getNodeData(nodeId);
    
      return SizedBox(
        width: MediaQuery.of(context).size.width * 0.45,
      child: GestureDetector(
        onTap: () => Navigator.pushNamed(context, '/detail', arguments: {
          'nodeId': nodeId,
          'nodeData': node,
        }),
        child: FutureBuilder<Color>(
          future: _computeCardColor(node),
          builder: (context, snapshot) {
            return Container(
              decoration: BoxDecoration(
                color: snapshot.data ?? const Color(0xFFBDBDBD),
                border: Border.all(color: Colors.white, width: 1),
              ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 节点标题
              Row(
                children: [
                  Text(
                    '节点${nodeId.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const Spacer(),
                  // 顶部右侧：系统状态（未连接时显示未连接，否则显示系统状态）
                  Padding(
                    padding: const EdgeInsets.only(right: 48),
                    child: FutureBuilder<String>(
                      future: _getDisplayStatus(node),
                      builder: (context, snapshot) {
                        return Text(
                          snapshot.data ?? '未连接',
                          style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white),
                        );
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              
              // 去掉传感器状态行
              const SizedBox(height: 8),
              
              // 状态行合并进湿度行，移除此处单独行
              const SizedBox(height: 8),
              
              // 去掉预警和故障信息折叠栏
              
              // 四个温度显示在卡片底部
              const SizedBox(height: 8),
              _buildCoreTempsRow(node),
              const SizedBox(height: 12),
            ],
          ),
            );
          },
        ),
      ),
    );
  }

  // 显示修改密码对话框
  void _showChangePasswordDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ChangePasswordDialog();
      },
    );
  }
}

// 修改密码对话框
class ChangePasswordDialog extends StatefulWidget {
  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final TextEditingController _oldPasswordController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _changePassword() async {
    final oldPassword = _oldPasswordController.text;
    final newPassword = _newPasswordController.text;
    final confirmPassword = _confirmPasswordController.text;

    // 验证输入
    if (oldPassword.isEmpty || newPassword.isEmpty || confirmPassword.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请填写所有字段'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (newPassword != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('新密码和确认密码不匹配'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (newPassword.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('新密码至少需要6位'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    // 修改密码
    final success = await PasswordService().changePassword(oldPassword, newPassword);
    
    setState(() {
      _isLoading = false;
    });

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('密码修改成功'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('原密码错误'),
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
        width: MediaQuery.of(context).size.width * 0.8,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
          minHeight: 400,
        ),
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: Color(0xFFCBBE8E),
          border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 3)),
        ),
        child: SingleChildScrollView(
          child: Column(
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
                  '修改管理员密码',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              const SizedBox(height: 20),
            
            // 原密码输入
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 2)),
              ),
              child: TextField(
                controller: _oldPasswordController,
                obscureText: true,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  labelText: '原密码',
                  labelStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // 新密码输入
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 2)),
              ),
              child: TextField(
                controller: _newPasswordController,
                obscureText: true,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  labelText: '新密码（至少6位）',
                  labelStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // 确认密码输入
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 2)),
              ),
              child: TextField(
                controller: _confirmPasswordController,
                obscureText: true,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  labelText: '确认新密码',
                  labelStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
              ),
            ),
            const SizedBox(height: 20),
            
            // 按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
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
                  onPressed: _isLoading ? null : _changePassword,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1976D2),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                    side: const BorderSide(color: Colors.black, width: 2),
                  ),
                  child: _isLoading 
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text('修改密码', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            ],
          ),
        ),
      ),
    );
  }
}


