import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/index_page.dart';
import 'pages/history_page.dart';
import 'pages/daily_history_page.dart';
import 'pages/data_detail_page.dart';
import 'pages/file_manager_page.dart';
import 'providers/sensor_provider.dart';
import 'models/node_data.dart';
import 'services/settings_service.dart';
import 'services/password_service.dart';
import 'services/csv_logger_service.dart';
import 'services/serial_debug_logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 初始化设置服务
  await SettingsService().initialize();
  // 初始化密码服务
  await PasswordService().initialize();
  // 初始化CSV日志服务
  await CsvLoggerService.instance.initialize();
  await SerialDebugLogger.instance.initialize();
  await SerialDebugLogger.instance.log('数据记录目录: ${CsvLoggerService.instance.displayPath}');
  runApp(const SensorApp());
}

class SensorApp extends StatelessWidget {
  const SensorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => SensorProvider()..initialize(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: '电缆接头检测',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF303F9F)),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFFB6A56A),
        ),
        initialRoute: '/',
        routes: {
          '/': (_) => const IndexPage(),
          '/history': (_) => const HistoryPage(),
          '/daily': (_) => const DailyHistoryPage(),
          '/files': (_) => const FileManagerPage(),
        },
        // 详情页需要参数，用 onGenerateRoute
        onGenerateRoute: (settings) {
          if (settings.name == '/detail') {
            final args = settings.arguments as Map<String, dynamic>?;
            final int nodeId = (args?['nodeId'] as int?) ?? 0;
            final NodeData? nodeData = args?['nodeData'] as NodeData?;
            return MaterialPageRoute(
              builder: (_) => DataDetailPage(nodeId: nodeId, nodeData: nodeData),
            );
          }
          return null;
        },
      ),
    );
  }
}
