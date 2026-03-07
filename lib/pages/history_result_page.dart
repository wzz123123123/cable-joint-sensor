import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/csv_logger_service.dart';
import '../services/settings_service.dart';

class HistoryResultPage extends StatefulWidget {
  final int nodeId;
  // sensorType 表示参数 key，例如 upper_temp、humidity 等
  final String sensorType;
  final DateTime startDateTime;
  final DateTime endDateTime;

  const HistoryResultPage({
    super.key,
    required this.nodeId,
    required this.sensorType,
    required this.startDateTime,
    required this.endDateTime,
  });

  @override
  State<HistoryResultPage> createState() => _HistoryResultPageState();
}

class _HistoryResultPageState extends State<HistoryResultPage> {
  List<List<String>> _rows = [];
  bool _isLoading = true;
  bool _showChart = false;
  String _statusMessage = '';

  final List<String> _headers = const [
    '时间',
    '毫秒时间戳',
    '节点',
    '传感器类型',
    '上温度(°C)',
    '中温度(°C)',
    '下温度(°C)',
    '湿度(%RH)',
    'CO(ppm)',
    'H2(%LEL)',
    '压力(kPa)',
    '烟雾状态',
    '烟雾外温(°C)',
    '白烟',
    '黑烟',
    'A相左外','A相中','A相右外','B相左外','B相中','B相右外','C相左外','C相中','C相右外',
    'A相中内','B相中内','C相中内',
    '状态',
    '预警信息',
    '故障信息',
  ];

  final List<double> _colWidths = <double>[
    120, 96, 40, 72, 78, 78, 78, 78, 64, 70, 78, 70, 92, 70, 70,
    64, 64, 64, 64, 64, 64, 64, 64, 64,
    64, 64, 64,
    72, 260, 260,
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _statusMessage = '正在加载数据...';
    });

    try {
      // 从CSV中按时间范围读取数据
      final rows = await CsvLoggerService.instance.readNodeCsvByTimeRange(
        widget.nodeId,
        widget.startDateTime,
        widget.endDateTime,
      );

      // 重新计算中内温度（使用当前的 k1、k2 参数）
      final recalculatedRows = await _recalculateCoreTempsForRows(rows, widget.nodeId);

      // 按传感器类型筛选
      final filteredRows = _filterBySensorType(recalculatedRows);

      setState(() {
        _rows = filteredRows;
        _statusMessage = '节点${widget.nodeId}共 ${filteredRows.length} 条记录';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = '加载数据失败: $e';
        _isLoading = false;
      });
    }
  }

  List<List<String>> _filterBySensorType(List<List<String>> rows) {
    final config = _getParameterConfig(widget.sensorType);
    final columnIndex = config['index'] as int?;
    if (columnIndex == null) return rows;

    return rows.where((r) {
      if (r.length <= columnIndex) return false;
      return r[columnIndex].isNotEmpty;
    }).toList();
  }

  Future<List<List<String>>> _recalculateCoreTempsForRows(List<List<String>> rows, int nodeId) async {
    try {
      final settings = SettingsService();
      final nodeSettings = await settings.getAllSettingsForNode(nodeId);
      final aK1 = nodeSettings['aK1'] as double? ?? 6.42;
      final aK2 = nodeSettings['aK2'] as double? ?? 2.5;
      final bK1 = nodeSettings['bK1'] as double? ?? 6.42;
      final bK2 = nodeSettings['bK2'] as double? ?? 2.5;
      final cK1 = nodeSettings['cK1'] as double? ?? 6.42;
      final cK2 = nodeSettings['cK2'] as double? ?? 2.5;

      List<List<String>> recalculated = [];
      for (final r in rows) {
        if (r.length < 27) {
          recalculated.add(r);
          continue;
        }
        double parse(String s) => double.tryParse(s) ?? 0;

        final aL = parse(r[15]);
        final aM = parse(r[16]);
        final aR = parse(r[17]);
        final bL = parse(r[18]);
        final bM = parse(r[19]);
        final bR = parse(r[20]);
        final cL = parse(r[21]);
        final cM = parse(r[22]);
        final cR = parse(r[23]);

        final leftAvg = (aL + bL + cL) / 3;
        final middleAvg = (aM + bM + cM) / 3;
        final rightAvg = (aR + bR + cR) / 3;

        double calc(double xi, double x0i, double xia, double k1, double k2) {
          if (xi == -999) return -999;
          if (xi < x0i) return xi;
          final d1 = xi - x0i;
          final d2 = xi - xia;
          return xi + k1 * (d1 < 0 ? 0 : d1) + k2 * (d2 < 0 ? 0 : d2);
        }

        final aCore = calc(aM, parse(r[5]), leftAvg, aK1, aK2);
        final bCore = calc(bM, parse(r[5]), middleAvg, bK1, bK2);
        final cCore = calc(cM, parse(r[6]), rightAvg, cK1, cK2);

        final newRow = List<String>.from(r);
        if (newRow.length >= 27) {
          newRow[24] = aCore.toStringAsFixed(2);
          newRow[25] = bCore.toStringAsFixed(2);
          newRow[26] = cCore.toStringAsFixed(2);
        }
        recalculated.add(newRow);
      }
      return recalculated;
    } catch (_) {
      return rows;
    }
  }

  Map<String, dynamic> _getParameterConfig(String key) {
    // 返回 index（列号）和展示名
    const configs = {
      'upper_temp': {'index': 4, 'name': '上温度(°C)'},
      'middle_temp': {'index': 5, 'name': '中温度(°C)'},
      'lower_temp': {'index': 6, 'name': '下温度(°C)'},
      'humidity': {'index': 7, 'name': '湿度(%RH)'},
      'co': {'index': 8, 'name': 'CO(ppm)'},
      'h2': {'index': 9, 'name': 'H2(%LEL)'},
      'pressure': {'index': 10, 'name': '压力(kPa)'},
      'smoke_external_temp': {'index': 12, 'name': '烟雾外温(°C)'},
      'white_smoke': {'index': 13, 'name': '白烟'},
      'black_smoke': {'index': 14, 'name': '黑烟'},
      'pt100_a_left': {'index': 15, 'name': 'A相左外(PT100)'},
      'pt100_a_middle': {'index': 16, 'name': 'A相中(PT100)'},
      'pt100_a_right': {'index': 17, 'name': 'A相右外(PT100)'},
      'pt100_b_left': {'index': 18, 'name': 'B相左外(PT100)'},
      'pt100_b_middle': {'index': 19, 'name': 'B相中(PT100)'},
      'pt100_b_right': {'index': 20, 'name': 'B相右外(PT100)'},
      'pt100_c_left': {'index': 21, 'name': 'C相左外(PT100)'},
      'pt100_c_middle': {'index': 22, 'name': 'C相中(PT100)'},
      'pt100_c_right': {'index': 23, 'name': 'C相右外(PT100)'},
      'core_a': {'index': 24, 'name': 'A相中内(°C)'},
      'core_b': {'index': 25, 'name': 'B相中内(°C)'},
      'core_c': {'index': 26, 'name': 'C相中内(°C)'},
      'status': {'index': 27, 'name': '状态'},
    };
    return configs[key] ?? {};
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
              decoration: const BoxDecoration(color: Color(0xFFCBBE8E)),
              child: Row(
                children: [
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF424242),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                      elevation: 2,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.arrow_back, size: 24),
                        SizedBox(width: 6),
                        Text('返回'),
                      ],
                    ),
                  ),
                  const Icon(Icons.analytics, color: Colors.black, size: 30),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${_getParameterConfig(widget.sensorType)['name'] ?? '查询结果'}（节点${widget.nodeId}）',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _rows.isEmpty ? null : () => setState(() => _showChart = !_showChart),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    ),
                    child: Text(_showChart ? '显示表格' : '显示图表', style: const TextStyle(fontSize: 16)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _statusMessage,
                  style: const TextStyle(fontSize: 16, color: Colors.black87),
                ),
              ),
            ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _showChart
                      ? _buildChart()
                      : _buildTable(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTable() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: _currentTableWidth(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFEEEEEE),
                  border: Border.all(color: const Color(0xFFBDBDBD)),
                ),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: _visibleColumnIndices().map((i) {
                    return Container(
                      width: _colWidths[i],
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 1)),
                      ),
                      padding: const EdgeInsets.all(4),
                      child: Text(
                        _headers[i],
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF424242)),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: ListView.builder(
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final r = _rows[index];
                    final bg = index.isEven ? const Color(0xFFF7F7F7) : const Color(0xFFFFFFFF);
                    return Container(
                      decoration: BoxDecoration(
                        color: bg,
                        border: const Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: _visibleColumnIndices().map((i) {
                          String v = i < r.length ? r[i] : '';
                          if (i == 0 && v.isNotEmpty) {
                            v = v.replaceFirst('T', ' ');
                            final dot = v.indexOf('.');
                            if (dot > 0) v = v.substring(0, dot);
                          }
                          return Container(
                            width: _colWidths[i],
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 1)),
                            ),
                            padding: const EdgeInsets.all(5),
                            child: Text(
                              v,
                              textAlign: TextAlign.center,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          );
                        }).toList(),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChart() {
    final cfg = _getParameterConfig(widget.sensorType);
    final idx = cfg['index'] as int?;
    if (idx == null || _rows.isEmpty) {
      return const Center(child: Text('无数据'));
    }

    final spots = <FlSpot>[];
    for (final r in _rows) {
      if (r.length <= idx || r.length < 2) continue;
      final ts = double.tryParse(r[1]) ?? 0;
      final val = double.tryParse(r[idx]) ?? 0;
      spots.add(FlSpot(ts, val));
    }
    spots.sort((a, b) => a.x.compareTo(b.x));

    if (spots.isEmpty) return const Center(child: Text('无有效数据点'));

    return Padding(
      padding: const EdgeInsets.all(12),
      child: LineChart(
        LineChartData(
          minY: _autoMin(spots.map((e) => e.y)),
          maxY: _autoMax(spots.map((e) => e.y)),
          lineBarsData: [
            LineChartBarData(
              isStrokeCapRound: true,
              isCurved: true,
              barWidth: 2.4,
              color: const Color(0xFF1565C0),
              dotData: const FlDotData(show: false),
              spots: spots,
            ),
          ],
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: (spots.length / 4).clamp(1, 6).toDouble(),
                getTitlesWidget: (v, _) => Text(
                  _formatTs(v.toInt()),
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 42,
                getTitlesWidget: (v, _) => Text(
                  v.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          borderData: FlBorderData(show: true),
        ),
      ),
    );
  }

  double _autoMin(Iterable<double> vals) {
    if (vals.isEmpty) return 0;
    final minV = vals.reduce((a, b) => a < b ? a : b);
    return (minV - 1).floorToDouble();
  }

  double _autoMax(Iterable<double> vals) {
    if (vals.isEmpty) return 0;
    final maxV = vals.reduce((a, b) => a > b ? a : b);
    return (maxV + 1).ceilToDouble();
  }

  String _formatTs(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${_two(dt.month)}/${_two(dt.day)}\n${_two(dt.hour)}:${_two(dt.minute)}';
  }

  List<int> _visibleColumnIndices() {
    // 仅展示核心列（去掉 epoch、烟雾状态列等冗余）
    final base = <int>[
      0, // 时间
      2, // 节点
      3, // 类型
      4, 5, 6, // 温度
      7, 8, 9, 10, // 湿度/CO/H2/压力
      12, 13, 14, // 烟雾外温、白烟、黑烟
      15, 16, 17, 18, 19, 20, 21, 22, 23, // PT100
      24, 25, 26, // 中内
      27, 28, 29, // 状态/预警/故障
    ];
    return base.where((i) => i >= 0 && i < _headers.length).toList();
  }

  double _currentTableWidth() {
    final idx = _visibleColumnIndices();
    double sum = 0;
    for (final i in idx) {
      sum += _colWidths[i];
    }
    return sum + idx.length * 2;
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';
}

