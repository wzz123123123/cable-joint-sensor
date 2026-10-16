import 'package:flutter/material.dart';
import 'history_search_page.dart';

/// 历史数据入口页面（跳转到查询页）
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史数据', style: TextStyle(fontSize: 20)),
        backgroundColor: const Color(0xFFCBBE8E),
      ),
      body: Center(
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HistorySearchPage()),
            );
          },
          child: const Text('查询历史记录'),
        ),
      ),
    );
  }
}
