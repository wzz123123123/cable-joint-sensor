import 'package:flutter/material.dart';
import 'history_result_page.dart';

class HistorySearchPage extends StatefulWidget {
  const HistorySearchPage({super.key});

  @override
  State<HistorySearchPage> createState() => _HistorySearchPageState();
}

class _HistorySearchPageState extends State<HistorySearchPage> {
  final List<String> _nodeOptions = const ['01', '02', '03', '04', '05'];
  String _selectedNode = '01';
  // 参数key，例如 upper_temp、middle_temp 等
  String _selectedSensorType = 'upper_temp';
  DateTime _startDate = DateTime.now();
  DateTime _endDate = DateTime.now();
  TimeOfDay _startTime = TimeOfDay.now();
  TimeOfDay _endTime = TimeOfDay.now();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
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
                    const Icon(Icons.search, color: Colors.black, size: 30),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '历史记录查询',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  color: const Color(0xFFF5F5F5),
                  padding: const EdgeInsets.all(18),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildSectionTitle('选择节点'),
                        _cardWrapper(
                          DropdownButton<String>(
                            value: _selectedNode,
                            isExpanded: true,
                            style: const TextStyle(fontSize: 18, color: Colors.black),
                            items: _nodeOptions
                                .map((e) => DropdownMenuItem<String>(
                                      value: e,
                                      child: Text('节点 $e', style: const TextStyle(fontSize: 18, color: Colors.black)),
                                    ))
                                .toList(),
                            onChanged: (v) {
                              if (v != null) {
                                setState(() => _selectedNode = v);
                              }
                            },
                          ),
                        ),
                        const SizedBox(height: 22),

                        _buildSectionTitle('选择参数（每次查询一个）'),
                        _cardWrapper(
                          DropdownButton<String>(
                            value: _selectedSensorType,
                            isExpanded: true,
                            style: const TextStyle(fontSize: 18, color: Colors.black),
                            items: _parameterOptions(),
                            onChanged: (v) {
                              if (v != null) {
                                setState(() => _selectedSensorType = v);
                              }
                            },
                          ),
                        ),
                        const SizedBox(height: 22),

                        _buildSectionTitle('开始时间'),
                        _cardWrapper(_buildDateTimePicker(
                          date: _startDate,
                          time: _startTime,
                          onDateChanged: (d) => setState(() => _startDate = d),
                          onTimeChanged: (t) => setState(() => _startTime = t),
                        )),
                        const SizedBox(height: 14),

                        _buildSectionTitle('结束时间'),
                        _cardWrapper(_buildDateTimePicker(
                          date: _endDate,
                          time: _endTime,
                          onDateChanged: (d) => setState(() => _endDate = d),
                          onTimeChanged: (t) => setState(() => _endTime = t),
                        )),
                        const SizedBox(height: 26),

                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.search, size: 22),
                                label: const Text('开始查询', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF1565C0),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                ),
                                onPressed: _onSearch,
                              ),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton(
                              onPressed: _reset,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF757575),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              ),
                              child: const Text('重置', style: TextStyle(fontSize: 16)),
                            ),
                          ],
                        ),
                      ],
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

  void _onSearch() {
    final startDateTime = DateTime(
      _startDate.year,
      _startDate.month,
      _startDate.day,
      _startTime.hour,
      _startTime.minute,
    );
    final endDateTime = DateTime(
      _endDate.year,
      _endDate.month,
      _endDate.day,
      _endTime.hour,
      _endTime.minute,
    );

    if (endDateTime.isBefore(startDateTime)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('结束时间必须晚于开始时间'), backgroundColor: Colors.red),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HistoryResultPage(
          nodeId: int.parse(_selectedNode),
          sensorType: _selectedSensorType,
          startDateTime: startDateTime,
          endDateTime: endDateTime,
        ),
      ),
    );
  }

  void _reset() {
    setState(() {
      _selectedNode = '01';
      _selectedSensorType = 'upper_temp';
      _startDate = DateTime.now();
      _endDate = DateTime.now();
      _startTime = TimeOfDay.now();
      _endTime = TimeOfDay.now();
    });
  }

  Widget _buildSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
      ),
    );
  }

  Widget _cardWrapper(Widget child) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey[300]!),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }

  List<DropdownMenuItem<String>> _parameterOptions() {
    return const [
      DropdownMenuItem(value: 'upper_temp', child: Text('上温度(°C)')),
      DropdownMenuItem(value: 'middle_temp', child: Text('中温度(°C)')),
      DropdownMenuItem(value: 'lower_temp', child: Text('下温度(°C)')),
      DropdownMenuItem(value: 'humidity', child: Text('湿度(%RH)')),
      DropdownMenuItem(value: 'co', child: Text('CO(ppm)')),
      DropdownMenuItem(value: 'h2', child: Text('H2(%LEL)')),
      DropdownMenuItem(value: 'pressure', child: Text('压力(kPa)')),
      DropdownMenuItem(value: 'smoke_external_temp', child: Text('烟雾外温(°C)')),
      DropdownMenuItem(value: 'white_smoke', child: Text('白烟')),
      DropdownMenuItem(value: 'black_smoke', child: Text('黑烟')),
      DropdownMenuItem(value: 'pt100_a_left', child: Text('A相左外(PT100)')),
      DropdownMenuItem(value: 'pt100_a_middle', child: Text('A相中(PT100)')),
      DropdownMenuItem(value: 'pt100_a_right', child: Text('A相右外(PT100)')),
      DropdownMenuItem(value: 'pt100_b_left', child: Text('B相左外(PT100)')),
      DropdownMenuItem(value: 'pt100_b_middle', child: Text('B相中(PT100)')),
      DropdownMenuItem(value: 'pt100_b_right', child: Text('B相右外(PT100)')),
      DropdownMenuItem(value: 'pt100_c_left', child: Text('C相左外(PT100)')),
      DropdownMenuItem(value: 'pt100_c_middle', child: Text('C相中(PT100)')),
      DropdownMenuItem(value: 'pt100_c_right', child: Text('C相右外(PT100)')),
      DropdownMenuItem(value: 'core_a', child: Text('A相中内(°C)')),
      DropdownMenuItem(value: 'core_b', child: Text('B相中内(°C)')),
      DropdownMenuItem(value: 'core_c', child: Text('C相中内(°C)')),
      DropdownMenuItem(value: 'status', child: Text('状态')),
    ];
  }

  Widget _buildDateTimePicker({
    required DateTime date,
    required TimeOfDay time,
    required ValueChanged<DateTime> onDateChanged,
    required ValueChanged<TimeOfDay> onTimeChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 22),
                label: Text(
                  '${date.year}-${_two(date.month)}-${_two(date.day)}',
                  style: const TextStyle(fontSize: 16),
                ),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: date,
                    firstDate: DateTime(date.year - 2),
                    lastDate: DateTime(date.year + 2),
                  );
                  if (picked != null) onDateChanged(picked);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.access_time, size: 22),
                label: Text(
                  '${_two(time.hour)}:${_two(time.minute)}',
                  style: const TextStyle(fontSize: 16),
                ),
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: time,
                  );
                  if (picked != null) onTimeChanged(picked);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';
}

