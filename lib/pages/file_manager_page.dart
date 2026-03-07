import 'package:flutter/material.dart';

class FileManagerPage extends StatelessWidget {
  const FileManagerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件/记录'),
        backgroundColor: const Color(0xFFCBBE8E),
      ),
      body: const Center(
        child: Text('文件管理与帧记录占位（后续接入 RawFrameLogger 与导出）'),
      ),
    );
  }
}


