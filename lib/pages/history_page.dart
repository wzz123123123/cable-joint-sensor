import 'package:flutter/material.dart';
import 'history_search_page.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史数据', style: TextStyle(fontSize: 24)),
        backgroundColor: const Color(0xFFCBBE8E),
      ),
      body: Center(
        child: ElevatedButton(
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


