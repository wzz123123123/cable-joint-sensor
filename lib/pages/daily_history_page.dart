import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../services/csv_logger_service.dart';
import '../services/password_service.dart';

class DailyHistoryPage extends StatefulWidget {
  const DailyHistoryPage({super.key});

  @override
  State<DailyHistoryPage> createState() => _DailyHistoryPageState();
}

class _DailyHistoryPageState extends State<DailyHistoryPage> {
  late String dateText;
  String tableText = '';
  List<List<String>> _rows = <List<String>>[];
  List<String> _headers = const [
    '时间',
    '毫秒时间戳', // 隐藏显示但保留用于排序
    '节点',
    '传感器类型',
    '上温度(°C)',
    '中温度(°C)',
    '下温度(°C)',
    '湿度(%RH)',
    'CO(ppm)',
    'H2(%LEL)',
    '压力(kPa)',
    '烟雾状态', // 隐藏显示
    '烟雾外温(°C)',
    '白烟',
    '黑烟',
    'A相左外','A相中','A相右外','B相左外','B相中','B相右外','C相左外','C相中','C相右外',
    'A相中内','B相中内','C相中内',
    '状态',
    '预警信息',
    '故障信息',
  ];
  List<String> _nodeOptions = const ['06', '07']; // 固定两个节点选项
  String _selectedNode = '06'; // 默认选择节点06
  String _statusFilter = '全部';
  String _sensorTypeFilter = '全部';
  // 各列固定宽度，保证表头与数据对齐
  final List<double> _colWidths = <double>[
    180, // 时间
    140, // 毫秒时间戳
    60,  // 节点
    100, // 传感器类型
    110, // 上温度
    110, // 中温度
    110, // 下温度
    110, // 湿度
    90,  // CO
    100, // H2
    110, // 压力
    100, // 烟雾状态（隐藏显示）
    130, // 烟雾外温
    100, // 白烟
    100, // 黑烟
    90,  // A相左外
    90,  // A相中
    90,  // A相右外
    90,  // B相左外
    90,  // B相中
    90,  // B相右外
    90,  // C相左外
    90,  // C相中
    90,  // C相右外
    90,  // A相中内
    90,  // B相中内
    90,  // C相中内
    100, // 状态
    400, // 预警信息
    400, // 故障信息
  ];

  @override
  void initState() {
    super.initState();
    final d = DateTime.now();
    String to2(int n) => n < 10 ? '0$n' : '$n';
    dateText = '${d.year}-${to2(d.month)}-${to2(d.day)}';
  }

  // 显示清空数据对话框
  void _showClearDataDialog() {
    final passwordController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('清空数据'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('此操作将删除当天的所有数据并重新创建文件。'),
                const SizedBox(height: 16),
                const Text('请输入密码以确认操作：'),
                const SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '密码',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (PasswordService().verifyPassword(passwordController.text)) {
                  Navigator.of(context).pop();
                  await _clearTodayData();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('密码错误！'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                foregroundColor: Colors.white,
              ),
              child: const Text('确认清空'),
            ),
          ],
        );
      },
    );
  }

  // 清空指定节点当天数据
  Future<void> _clearTodayData() async {
    try {
      final nodeId = int.parse(_selectedNode);
      await CsvLoggerService.instance.clearNodeTodayData(nodeId);
      setState(() {
        _rows.clear();
        tableText = '节点${_selectedNode}数据已清空';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('节点${_selectedNode}当天数据已清空'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('清空数据失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // 显示保存位置选择对话框
  void _showSaveLocationDialog() {
    final passwordController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('选择保存位置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('选择新的日志文件保存位置。'),
                const SizedBox(height: 16),
                const Text('请输入密码以确认操作：'),
                const SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '密码',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (PasswordService().verifyPassword(passwordController.text)) {
                  Navigator.of(context).pop();
                  await _selectSaveLocation();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('密码错误！'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
                foregroundColor: Colors.white,
              ),
              child: const Text('确认选择'),
            ),
          ],
        );
      },
    );
  }

  // 选择保存位置
  Future<void> _selectSaveLocation() async {
    try {
      // 让用户选择保存位置
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      
      if (selectedDirectory == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('未选择保存位置'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      // 设置新的保存位置
      await CsvLoggerService.instance.setCustomLogsPath(selectedDirectory);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('日志保存位置已设置为: $selectedDirectory'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('设置保存位置失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
               Container(
                 padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                 decoration: const BoxDecoration(
                   color: Color(0xFFCBBE8E),
                 ),
                 child: Row(
                   children: [
                     ElevatedButton(
                       onPressed: () => Navigator.pop(context),
                       style: ElevatedButton.styleFrom(
                         backgroundColor: const Color(0xFF424242),
                         foregroundColor: Colors.white,
                         shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                         elevation: 2,
                         padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                       ),
                       child: const Row(
                         mainAxisSize: MainAxisSize.min,
                         children: [
                           Icon(Icons.arrow_back, size: 36),
                           SizedBox(width: 8),
                           Text('返回', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                         ],
                       ),
                     ),
                     const Icon(Icons.history, color: Colors.black, size: 48),
                     const SizedBox(width: 16),
                     const Expanded(
                       child: Text(
                         '每日历史数据',
                         textAlign: TextAlign.center,
                         style: TextStyle(fontSize: 44, fontWeight: FontWeight.bold, color: Colors.black),
                       ),
                     ),
                     const SizedBox(width: 8),
                     // 清空数据按钮
                     ElevatedButton(
                       onPressed: _showClearDataDialog,
                       style: ElevatedButton.styleFrom(
                         backgroundColor: const Color(0xFFD32F2F),
                         foregroundColor: Colors.white,
                         shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                         elevation: 2,
                       ),
                       child: const Text('清空', style: TextStyle(fontSize: 20)),
                     ),
                     const SizedBox(width: 8),
                     // 保存位置选择按钮
                     ElevatedButton(
                       onPressed: _showSaveLocationDialog,
                       style: ElevatedButton.styleFrom(
                         backgroundColor: const Color(0xFF1976D2),
                         foregroundColor: Colors.white,
                         shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                         elevation: 2,
                       ),
                       child: const Text('保存位置', style: TextStyle(fontSize: 20)),
                     ),
                   ],
                 ),
               ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 12,
                  children: [
                    const Text('选择日期: ', style: TextStyle(fontSize: 24)),
                    SizedBox(
                      width: 250,
                      height: 60,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today, size: 40),
                        label: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              dateText.split('-')[0] + '年' + dateText.split('-')[1] + '月',
                              style: const TextStyle(fontSize: 20),
                            ),
                            Text(
                              dateText.split('-')[2] + '日',
                              style: const TextStyle(fontSize: 20),
                            ),
                          ],
                        ),
                        onPressed: () async {
                          final now = DateTime.now();
                          final parts = dateText.split('-');
                          DateTime? initial;
                          try { initial = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2])); } catch (_) { initial = now; }
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: initial!,
                            firstDate: DateTime(now.year - 2),
                            lastDate: DateTime(now.year + 2),
                          );
                          if (picked != null) {
                            String to2(int n) => n < 10 ? '0$n' : '$n';
                            setState(() => dateText = '${picked.year}-${to2(picked.month)}-${to2(picked.day)}');
                          }
                        },
                      ),
                    ),
                    const Text('节点: ', style: TextStyle(fontSize: 24, color: Colors.black)),
                    SizedBox(
                      width: 120,
                      height: 50,
                      child: DropdownButton<String>(
                        value: _selectedNode,
                        isExpanded: true,
                        style: const TextStyle(fontSize: 24),
                        items: _nodeOptions
                            .map((e) => DropdownMenuItem<String>(value: e, child: Text(e, style: const TextStyle(fontSize: 24, color: Colors.black))))
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _selectedNode = v);
                        },
                      ),
                    ),
                    // 状态筛选
                    const Text('状态: ', style: TextStyle(fontSize: 24, color: Colors.black)),
                    SizedBox(
                      width: 150,
                      height: 50,
                      child: DropdownButton<String>(
                        value: _statusFilter,
                        isExpanded: true,
                        style: const TextStyle(fontSize: 24),
                        items: const [
                          DropdownMenuItem(value: '全部', child: Text('全部', style: TextStyle(fontSize: 24, color: Colors.black))),
                          DropdownMenuItem(value: 'OK', child: Text('OK', style: TextStyle(fontSize: 24, color: Colors.black))),
                          DropdownMenuItem(value: 'EMPTY', child: Text('EMPTY', style: TextStyle(fontSize: 24, color: Colors.black))),
                          DropdownMenuItem(value: 'INVALID', child: Text('INVALID', style: TextStyle(fontSize: 24, color: Colors.black))),
                          DropdownMenuItem(value: 'DISCONNECTED', child: Text('DISCONNECTED', style: TextStyle(fontSize: 24, color: Colors.black))),
                        ],
                        onChanged: (v) { if (v != null) setState(() => _statusFilter = v); },
                      ),
                    ),
                    // 传感器类型筛选
                    const Text('类型: ', style: TextStyle(fontSize: 24, color: Colors.black)),
                    SizedBox(
                      width: 150,
                      height: 50,
                      child: DropdownButton<String>(
                        value: _sensorTypeFilter,
                        isExpanded: true,
                        style: const TextStyle(fontSize: 24),
                        items: const [
                          DropdownMenuItem(value: '全部', child: Text('全部', style: TextStyle(fontSize: 24, color: Colors.black))),
                          DropdownMenuItem(value: '1', child: Text('温湿度', style: TextStyle(fontSize: 24, color: Colors.black))),
                          DropdownMenuItem(value: '2', child: Text('CO', style: TextStyle(fontSize: 24, color: Colors.black))),
                          DropdownMenuItem(value: '3', child: Text('H2', style: TextStyle(fontSize: 24, color: Colors.black))),
                          DropdownMenuItem(value: '4', child: Text('压力', style: TextStyle(fontSize: 24, color: Colors.black))),
                          DropdownMenuItem(value: '5', child: Text('烟雾', style: TextStyle(fontSize: 24, color: Colors.black))),
                          DropdownMenuItem(value: '7', child: Text('PT100', style: TextStyle(fontSize: 24, color: Colors.black))),
                        ],
                        onChanged: (v) { if (v != null) setState(() => _sensorTypeFilter = v); },
                      ),
                    ),
                     SizedBox(
                       height: 50,
                       child: ElevatedButton.icon(
                         icon: const Icon(Icons.search, size: 40),
                         label: const Text('查找', style: TextStyle(fontSize: 24)),
                         style: ElevatedButton.styleFrom(
                           backgroundColor: const Color(0xFF01579B),
                           foregroundColor: Colors.white,
                           shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                           elevation: 2,
                         ),
                         onPressed: () async {
                           try {
                             final date = DateTime.parse(dateText);
                             final nodeId = int.parse(_selectedNode);
                             final rows = await CsvLoggerService.instance.readNodeCsvByDate(nodeId, date);
                             setState(() {
                               _rows = rows;
                               tableText = '节点${_selectedNode}共 ${rows.length} 行记录';
                             });
                           } catch (e) {
                             setState(() => tableText = '读取节点${_selectedNode}数据失败: $e');
                           }
                         },
                       ),
                     ),
                     SizedBox(
                       height: 50,
                       child: ElevatedButton.icon(
                         icon: const Icon(Icons.refresh, size: 40),
                         label: const Text('重置', style: TextStyle(fontSize: 24)),
                         style: ElevatedButton.styleFrom(
                           backgroundColor: const Color(0xFF757575),
                           foregroundColor: Colors.white,
                           shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                           elevation: 2,
                         ),
                         onPressed: () {
                           setState(() {
                            _selectedNode = '06';
                             _statusFilter = '全部';
                             _sensorTypeFilter = '全部';
                           });
                         },
                       ),
                     ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: _currentTableWidth(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tableText),
                          const SizedBox(height: 8),
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
                                  constraints: const BoxConstraints(
                                    minHeight: 20,
                                    maxHeight: 30,
                                  ),
                                  alignment: Alignment.center,
                                  decoration: const BoxDecoration(
                                    border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 1)),
                                  ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(4.0),
                                    child: Text(
                                      _headers[i],
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF424242)),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _filteredRows().length,
                              itemBuilder: (context, index) {
                                final r = _filteredRows()[index];
                                final status = r.length > 25 ? r[25] : '';
                                final bg = _statusBg(status);
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
                                        constraints: const BoxConstraints(
                                          minHeight: 20,
                                          maxHeight: 40, // 减小行高
                                        ),
                                        alignment: Alignment.center,
                                        decoration: const BoxDecoration(
                                          border: Border.fromBorderSide(BorderSide(color: Colors.black, width: 1)),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.all(6.0),
                                          child: Text(
                                            v,
                                            textAlign: TextAlign.center,
                                            maxLines: null,
                                            overflow: TextOverflow.visible,
                                            softWrap: true,
                                            style: const TextStyle(fontSize: 14),
                                          ),
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
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<List<String>> _filteredRows() {
    // 数据已经是按节点过滤的，直接使用
    var rows = List<List<String>>.from(_rows);
    
    // 状态过滤
    if (_statusFilter != '全部') {
      rows = rows.where((r) => r.length > 25 && r[25] == _statusFilter).toList();
    }
    // 传感器类型过滤：按对应列是否有值，而非严格匹配类型列
    if (_sensorTypeFilter != '全部') {
      bool match(List<String> r) {
        switch (_sensorTypeFilter) {
          case '1': // 温湿度
            return r.length > 5 && (r[4].isNotEmpty || r[5].isNotEmpty);
          case '2': // CO
            return r.length > 6 && r[6].isNotEmpty;
          case '3': // H2
            return r.length > 7 && r[7].isNotEmpty;
          case '4': // 压力
            return r.length > 9 && (r[8].isNotEmpty || r[9].isNotEmpty);
          case '5': // 烟雾（去除状态列）
            return r.length > 13 && (r[11].isNotEmpty || r[12].isNotEmpty || r[13].isNotEmpty);
          case '7': // PT100
            return r.length > 24 && (r[14].isNotEmpty || r[15].isNotEmpty || r[16].isNotEmpty || r[17].isNotEmpty || r[18].isNotEmpty || r[19].isNotEmpty || r[20].isNotEmpty || r[21].isNotEmpty || r[22].isNotEmpty || r[23].isNotEmpty);
          case '8': // 状态
            return r.length > 25 && r[25].isNotEmpty;
        }
        return true;
      }
      rows = rows.where(match).toList();
    }
    // 再按时间戳（epoch_ms）降序排列，最新在最上面
    rows.sort((a, b) {
      int pa = 0;
      int pb = 0;
      if (a.length > 1) {
        pa = int.tryParse(a[1]) ?? 0;
      }
      if (b.length > 1) {
        pb = int.tryParse(b[1]) ?? 0;
      }
      return pb.compareTo(pa);
    });
    return rows;
  }

  Color _statusBg(String status) {
    switch (status) {
      case 'DISCONNECTED':
        return const Color(0xFFFFCDD2); // 红浅
      case 'EMPTY':
        return const Color(0xFFFFF9C4); // 黄浅
      case 'INVALID':
        return const Color(0xFFFFE0B2); // 橙浅
      default:
        return const Color(0xFFE8F5E9); // 绿浅
    }
  }

  double _totalTableWidth() {
    double sum = 0;
    for (final w in _colWidths) {
      sum += w;
    }
    return sum;
  }

  List<int> _visibleColumnIndices() {
    // 当选择具体的传感器类型时，只展示该类型相关列
    if (_sensorTypeFilter != '全部') {
      // 定义各类型对应的列索引
      // 0:时间,1:epoch,2:节点,3:类型, 剩余对应数据列
      final base = [0, 2, 3];
      switch (_sensorTypeFilter) {
        case '1': // 温湿度（上中下温度一起展示）
          return [...base, 4, 5, 6, 7]; // 上温度、中温度、下温度、湿度
        case '2': // CO
          return [...base, 8];
        case '3': // H2
          return [...base, 9];
        case '4': // 压力
          return [...base, 10, 6]; // 压力、下温度
        case '5': // 烟雾
          return [...base, 12, 13, 14]; // 烟雾外温、白烟、黑烟
        case '7': // PT100 → 展示9列（A/B/C相各3个测点）
          return [...base, 15,16,17,18,19,20,21,22,23]; // A/B/C相左中右
      }
    }
    // 默认展示全部列，按所需顺序重排：时间/节点/类型 → 主要数据列
    final ordered = <int>[
      0, // 时间
      2, // 节点
      3, // 类型
      4,  // 上温度
      5,  // 中温度
      6,  // 下温度
      7,  // 湿度
      8,  // CO
      9,  // H2
      10, // 压力
      12, // 烟雾外温
      13, // 白烟
      14, // 黑烟
      15,16,17,18,19,20,21,22,23, // A/B/C相左中右
      24,25,26, // A/B/C相中内
      27,28,29, // 状态/预警/故障
    ];
    // 过滤掉超界或不存在的索引以防未来改动
    return ordered.where((i) => i >= 0 && i < _headers.length && i != 1 && i != 11).toList();
  }

  double _currentTableWidth() {
    final idx = _visibleColumnIndices();
    double sum = 0;
    for (final i in idx) {
      sum += _colWidths[i];
    }
    // 为每个单元格1px边框预留更充足的余量，避免各类筛选下的像素累计误差
    return sum + (idx.length * 2).toDouble();
  }
}


