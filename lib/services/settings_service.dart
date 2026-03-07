import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  // 默认阈值设置
  static const double DEFAULT_TEMP_START = 80.0;
  static const double DEFAULT_TEMP_WARNING = 85.0;
  static const double DEFAULT_TEMP_FAULT = 90.0;
  static const double DEFAULT_H2_WARNING = 0.0;
  static const double DEFAULT_H2_FAULT = 2.0;
  static const double DEFAULT_CO_WARNING = 0.0;
  static const double DEFAULT_CO_FAULT = 50.0;
  static const double DEFAULT_SMOKE_FAULT = 0.34;
  static const double DEFAULT_HUMIDITY_WARNING = 60.0;
  static const double DEFAULT_HUMIDITY_FAULT = 75.0;
  static const int DEFAULT_HUMIDITY_FAULT_HOURS = 8;
  static const double DEFAULT_PRESSURE_WARNING = 105.0;
  static const double DEFAULT_PRESSURE_FAULT = 110.0;
  static const int DEFAULT_NODE_QUERY_RETRY_COUNT = 5; // 节点查询重试次数
  static const int DEFAULT_NODE_QUERY_INTERVAL_MS = 100; // 节点查询间隔时间（毫秒）
  static const int DEFAULT_NODE_DISCONNECT_TIMEOUT_MS = 40000; // 节点断开连接判断超时时间（毫秒，40秒）

  // 当前设置
  double _tempStart = DEFAULT_TEMP_START;
  double _tempWarning = DEFAULT_TEMP_WARNING;
  double _tempFault = DEFAULT_TEMP_FAULT;
  double _h2Warning = DEFAULT_H2_WARNING;
  double _h2Fault = DEFAULT_H2_FAULT;
  double _coWarning = DEFAULT_CO_WARNING;
  double _coFault = DEFAULT_CO_FAULT;
  double _smokeFault = DEFAULT_SMOKE_FAULT;
  double _humidityWarning = DEFAULT_HUMIDITY_WARNING;
  double _humidityFault = DEFAULT_HUMIDITY_FAULT;
  int _humidityFaultHours = DEFAULT_HUMIDITY_FAULT_HOURS;
  double _pressureWarning = DEFAULT_PRESSURE_WARNING;
  double _pressureFault = DEFAULT_PRESSURE_FAULT;
  
  // 节点查询配置
  int _nodeQueryRetryCount = DEFAULT_NODE_QUERY_RETRY_COUNT;
  int _nodeQueryIntervalMs = DEFAULT_NODE_QUERY_INTERVAL_MS;
  int _nodeDisconnectTimeoutMs = DEFAULT_NODE_DISCONNECT_TIMEOUT_MS;
  
  // 湿度修正（全局默认，按节点可覆盖）
  double _humidityCorrection = 0.0;
  
  // PT100十路参数修正
  List<double> _pt100Corrections = List<double>.filled(10, 0.0);
  
  // 防爆盒内环境参数修正
  double _upperTempCorrection = 0.0; // 上温度修正
  double _envTempCorrection = 0.0;   // 中温度修正
  double _lowerTempCorrection = 0.0; // 下温度修正
  
  // ABC三相内温度计算参数
  double _aK1 = 6.42; // A相K1参数（环境温度系数）
  double _aK2 = 2.5;  // A相K2参数（三相平均系数）
  double _bK1 = 6.42; // B相K1参数（环境温度系数）
  double _bK2 = 2.5;  // B相K2参数（三相平均系数）
  double _cK1 = 6.42; // C相K1参数（环境温度系数）
  double _cK2 = 2.5;  // C相K2参数（三相平均系数）

  // 获取器方法
  double get tempStart => _tempStart;
  double get tempWarning => _tempWarning;
  double get tempFault => _tempFault;
  double get h2Warning => _h2Warning;
  double get h2Fault => _h2Fault;
  double get coWarning => _coWarning;
  double get coFault => _coFault;
  double get smokeFault => _smokeFault;
  double get humidityWarning => _humidityWarning;
  double get humidityFault => _humidityFault;
  int get humidityFaultHours => _humidityFaultHours;
  double get pressureWarning => _pressureWarning;
  double get pressureFault => _pressureFault;
  int get nodeQueryRetryCount => _nodeQueryRetryCount;
  int get nodeQueryIntervalMs => _nodeQueryIntervalMs;
  int get nodeDisconnectTimeoutMs => _nodeDisconnectTimeoutMs;
  double get humidityCorrection => _humidityCorrection;
  List<double> get pt100Corrections => List.from(_pt100Corrections);
  double get upperTempCorrection => _upperTempCorrection;
  double get envTempCorrection => _envTempCorrection;
  double get lowerTempCorrection => _lowerTempCorrection;
  
  // ABC三相内温度计算参数getter
  double get aK1 => _aK1;
  double get aK2 => _aK2;
  double get bK1 => _bK1;
  double get bK2 => _bK2;
  double get cK1 => _cK1;
  double get cK2 => _cK2;

  // 初始化设置
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    // 如果本地首启为空（例如重装），尝试从外部备份恢复
    await _restorePrefsFromExternalIfEmpty(prefs);
    
    _tempStart = prefs.getDouble('temp_start') ?? DEFAULT_TEMP_START;
    _tempWarning = prefs.getDouble('temp_warning') ?? DEFAULT_TEMP_WARNING;
    _tempFault = prefs.getDouble('temp_fault') ?? DEFAULT_TEMP_FAULT;
    _h2Warning = prefs.getDouble('h2_warning') ?? DEFAULT_H2_WARNING;
    _h2Fault = prefs.getDouble('h2_fault') ?? DEFAULT_H2_FAULT;
    _coWarning = prefs.getDouble('co_warning') ?? DEFAULT_CO_WARNING;
    _coFault = prefs.getDouble('co_fault') ?? DEFAULT_CO_FAULT;
    _smokeFault = prefs.getDouble('smoke_fault') ?? DEFAULT_SMOKE_FAULT;
    _humidityWarning = prefs.getDouble('humidity_warning') ?? DEFAULT_HUMIDITY_WARNING;
    _humidityFault = prefs.getDouble('humidity_fault') ?? DEFAULT_HUMIDITY_FAULT;
    _humidityFaultHours = prefs.getInt('humidity_fault_hours') ?? DEFAULT_HUMIDITY_FAULT_HOURS;
    _pressureWarning = prefs.getDouble('pressure_warning') ?? DEFAULT_PRESSURE_WARNING;
    _pressureFault = prefs.getDouble('pressure_fault') ?? DEFAULT_PRESSURE_FAULT;
    _nodeQueryRetryCount = prefs.getInt('node_query_retry_count') ?? DEFAULT_NODE_QUERY_RETRY_COUNT;
    _nodeQueryIntervalMs = prefs.getInt('node_query_interval_ms') ?? DEFAULT_NODE_QUERY_INTERVAL_MS;
    _nodeDisconnectTimeoutMs = prefs.getInt('node_disconnect_timeout_ms') ?? DEFAULT_NODE_DISCONNECT_TIMEOUT_MS;
    _humidityCorrection = prefs.getDouble('humidity_correction') ?? 0.0;
    
    // 加载PT100参数修正
    final correctionsJson = prefs.getString('pt100_corrections');
    if (correctionsJson != null) {
      try {
        final List<dynamic> corrections = jsonDecode(correctionsJson);
        _pt100Corrections = corrections.cast<double>();
        if (_pt100Corrections.length != 10) {
          _pt100Corrections = List<double>.filled(10, 0.0);
        }
      } catch (e) {
        _pt100Corrections = List<double>.filled(10, 0.0);
      }
    }
    
    // 加载环境温度修正
    _upperTempCorrection = prefs.getDouble('upper_temp_correction') ?? 0.0;
    _envTempCorrection = prefs.getDouble('env_temp_correction') ?? 0.0;
    _lowerTempCorrection = prefs.getDouble('lower_temp_correction') ?? 0.0;
    
    // 初始化ABC三相内温度计算参数
    _aK1 = prefs.getDouble('a_k1') ?? 6.42;
    _aK2 = prefs.getDouble('a_k2') ?? 2.5;
    _bK1 = prefs.getDouble('b_k1') ?? 6.42;
    _bK2 = prefs.getDouble('b_k2') ?? 2.5;
    _cK1 = prefs.getDouble('c_k1') ?? 6.42;
    _cK2 = prefs.getDouble('c_k2') ?? 2.5;
  }

  // ================= 按节点分域的读取/写入 =================
  String _nk(String base, int nodeId) => '${base}_node_$nodeId';

  Future<Map<String, dynamic>> getAllSettingsForNode(int nodeId) async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'tempStart': prefs.getDouble(_nk('temp_start', nodeId)) ?? _tempStart,
      'tempWarning': prefs.getDouble(_nk('temp_warning', nodeId)) ?? _tempWarning,
      'tempFault': prefs.getDouble(_nk('temp_fault', nodeId)) ?? _tempFault,
      'h2Fault': prefs.getDouble(_nk('h2_fault', nodeId)) ?? _h2Fault,
      'h2Warning': prefs.getDouble(_nk('h2_warning', nodeId)) ?? _h2Warning,
      'coFault': prefs.getDouble(_nk('co_fault', nodeId)) ?? _coFault,
      'coWarning': prefs.getDouble(_nk('co_warning', nodeId)) ?? _coWarning,
      'smokeFault': prefs.getDouble(_nk('smoke_fault', nodeId)) ?? _smokeFault,
      'humidityWarning': prefs.getDouble(_nk('humidity_warning', nodeId)) ?? _humidityWarning,
      'humidityFault': prefs.getDouble(_nk('humidity_fault', nodeId)) ?? _humidityFault,
      'humidityFaultHours': prefs.getInt(_nk('humidity_fault_hours', nodeId)) ?? _humidityFaultHours,
      'pressureWarning': prefs.getDouble(_nk('pressure_warning', nodeId)) ?? _pressureWarning,
      'pressureFault': prefs.getDouble(_nk('pressure_fault', nodeId)) ?? _pressureFault,
      'humidityCorrection': prefs.getDouble(_nk('humidity_correction', nodeId)) ?? _humidityCorrection,
      'pt100Corrections': (() {
        final json = prefs.getString(_nk('pt100_corrections', nodeId));
        if (json == null) return List<double>.from(_pt100Corrections);
        try {
          final List<dynamic> list = jsonDecode(json);
          final casted = list.cast<double>();
          return casted.length == 10 ? casted : List<double>.filled(10, 0.0);
        } catch (_) {
          return List<double>.filled(10, 0.0);
        }
      })(),
      'upperTempCorrection': prefs.getDouble(_nk('upper_temp_correction', nodeId)) ?? _upperTempCorrection,
      'envTempCorrection': prefs.getDouble(_nk('env_temp_correction', nodeId)) ?? _envTempCorrection,
      'lowerTempCorrection': prefs.getDouble(_nk('lower_temp_correction', nodeId)) ?? _lowerTempCorrection,
      'aK1': prefs.getDouble(_nk('a_k1', nodeId)) ?? _aK1,
      'aK2': prefs.getDouble(_nk('a_k2', nodeId)) ?? _aK2,
      'bK1': prefs.getDouble(_nk('b_k1', nodeId)) ?? _bK1,
      'bK2': prefs.getDouble(_nk('b_k2', nodeId)) ?? _bK2,
      'cK1': prefs.getDouble(_nk('c_k1', nodeId)) ?? _cK1,
      'cK2': prefs.getDouble(_nk('c_k2', nodeId)) ?? _cK2,
    };
  }

  Future<void> updateTempThresholdsForNode(int nodeId, double start, double warning, double fault) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_nk('temp_start', nodeId), start);
    await prefs.setDouble(_nk('temp_warning', nodeId), warning);
    await prefs.setDouble(_nk('temp_fault', nodeId), fault);
    await _backupPrefsToExternal(prefs);
  }

  Future<void> updateGasThresholdsForNode(int nodeId, double h2Fault, double coFault, double smokeFault) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_nk('h2_fault', nodeId), h2Fault);
    await prefs.setDouble(_nk('co_fault', nodeId), coFault);
    await prefs.setDouble(_nk('smoke_fault', nodeId), smokeFault);
    await _backupPrefsToExternal(prefs);
  }

  Future<void> updateGasWarningThresholdsForNode(int nodeId, double h2Warning, double coWarning) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_nk('h2_warning', nodeId), h2Warning);
    await prefs.setDouble(_nk('co_warning', nodeId), coWarning);
    await _backupPrefsToExternal(prefs);
  }

  Future<void> updateHumidityThresholdsForNode(int nodeId, double warning, double fault, int faultHours) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_nk('humidity_warning', nodeId), warning);
    await prefs.setDouble(_nk('humidity_fault', nodeId), fault);
    await prefs.setInt(_nk('humidity_fault_hours', nodeId), faultHours);
    await _backupPrefsToExternal(prefs);
  }

  Future<void> updatePressureThresholdsForNode(int nodeId, double warning, double fault) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_nk('pressure_warning', nodeId), warning);
    await prefs.setDouble(_nk('pressure_fault', nodeId), fault);
    await _backupPrefsToExternal(prefs);
  }

  // 更新湿度修正（按节点）
  Future<void> updateHumidityCorrectionForNode(int nodeId, double correction) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_nk('humidity_correction', nodeId), correction);
    await _backupPrefsToExternal(prefs);
  }

  Future<void> updatePt100CorrectionsForNode(int nodeId, List<double> corrections) async {
    if (corrections.length != 10) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nk('pt100_corrections', nodeId), jsonEncode(corrections));
    await _backupPrefsToExternal(prefs);
  }

  Future<void> updateEnvTempCorrectionsForNode(int nodeId, double upperTemp, double envTemp, double lowerTemp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_nk('upper_temp_correction', nodeId), upperTemp);
    await prefs.setDouble(_nk('env_temp_correction', nodeId), envTemp);
    await prefs.setDouble(_nk('lower_temp_correction', nodeId), lowerTemp);
    await _backupPrefsToExternal(prefs);
  }

  // 更新温度阈值
  Future<void> updateTempThresholds(double start, double warning, double fault) async {
    _tempStart = start;
    _tempWarning = warning;
    _tempFault = fault;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('temp_start', start);
    await prefs.setDouble('temp_warning', warning);
    await prefs.setDouble('temp_fault', fault);
    await _backupPrefsToExternal(prefs);
  }

  // 更新气体阈值
  Future<void> updateGasThresholds(double h2Fault, double coFault, double smokeFault) async {
    _h2Fault = h2Fault;
    _coFault = coFault;
    _smokeFault = smokeFault;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('h2_fault', h2Fault);
    await prefs.setDouble('co_fault', coFault);
    await prefs.setDouble('smoke_fault', smokeFault);
    await _backupPrefsToExternal(prefs);
  }

  Future<void> updateGasWarningThresholds(double h2Warning, double coWarning) async {
    _h2Warning = h2Warning;
    _coWarning = coWarning;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('h2_warning', h2Warning);
    await prefs.setDouble('co_warning', coWarning);
    await _backupPrefsToExternal(prefs);
  }

  // 更新湿度阈值
  Future<void> updateHumidityThresholds(double warning, double fault, int faultHours) async {
    _humidityWarning = warning;
    _humidityFault = fault;
    _humidityFaultHours = faultHours;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('humidity_warning', warning);
    await prefs.setDouble('humidity_fault', fault);
    await prefs.setInt('humidity_fault_hours', faultHours);
    await _backupPrefsToExternal(prefs);
  }

  // 更新压力阈值
  Future<void> updatePressureThresholds(double warning, double fault) async {
    _pressureWarning = warning;
    _pressureFault = fault;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('pressure_warning', warning);
    await prefs.setDouble('pressure_fault', fault);
    await _backupPrefsToExternal(prefs);
  }
  
  // 更新节点查询配置
  Future<void> updateNodeQueryConfig(int retryCount, int intervalMs, int disconnectTimeoutMs) async {
    _nodeQueryRetryCount = retryCount;
    _nodeQueryIntervalMs = intervalMs;
    _nodeDisconnectTimeoutMs = disconnectTimeoutMs;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('node_query_retry_count', retryCount);
    await prefs.setInt('node_query_interval_ms', intervalMs);
    await prefs.setInt('node_disconnect_timeout_ms', disconnectTimeoutMs);
    await _backupPrefsToExternal(prefs);
  }

  // 更新湿度修正（全局）
  Future<void> updateHumidityCorrection(double correction) async {
    _humidityCorrection = correction;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('humidity_correction', correction);
    await _backupPrefsToExternal(prefs);
  }

  // 更新PT100参数修正
  Future<void> updatePt100Corrections(List<double> corrections) async {
    if (corrections.length != 10) return;
    _pt100Corrections = List.from(corrections);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pt100_corrections', jsonEncode(corrections));
    await _backupPrefsToExternal(prefs);
  }

  // 更新环境温度修正
  Future<void> updateEnvTempCorrections(double upperTemp, double envTemp, double lowerTemp) async {
    _upperTempCorrection = upperTemp;
    _envTempCorrection = envTemp;
    _lowerTempCorrection = lowerTemp;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('upper_temp_correction', upperTemp);
    await prefs.setDouble('env_temp_correction', envTemp);
    await prefs.setDouble('lower_temp_correction', lowerTemp);
    await _backupPrefsToExternal(prefs);
  }
  
  // 更新ABC三相内温度计算参数
  Future<void> updatePhaseKParams(double aK1, double aK2, double bK1, double bK2, double cK1, double cK2) async {
    _aK1 = aK1;
    _aK2 = aK2;
    _bK1 = bK1;
    _bK2 = bK2;
    _cK1 = cK1;
    _cK2 = cK2;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('a_k1', aK1);
    await prefs.setDouble('a_k2', aK2);
    await prefs.setDouble('b_k1', bK1);
    await prefs.setDouble('b_k2', bK2);
    await prefs.setDouble('c_k1', cK1);
    await prefs.setDouble('c_k2', cK2);
    await _backupPrefsToExternal(prefs);
  }
  
  // 更新ABC三相内温度计算参数（节点特定）
  Future<void> updatePhaseKParamsForNode(int nodeId, double aK1, double aK2, double bK1, double bK2, double cK1, double cK2) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_nk('a_k1', nodeId), aK1);
    await prefs.setDouble(_nk('a_k2', nodeId), aK2);
    await prefs.setDouble(_nk('b_k1', nodeId), bK1);
    await prefs.setDouble(_nk('b_k2', nodeId), bK2);
    await prefs.setDouble(_nk('c_k1', nodeId), cK1);
    await prefs.setDouble(_nk('c_k2', nodeId), cK2);
    await _backupPrefsToExternal(prefs);
  }

  // 重置所有设置为默认值
  Future<void> resetToDefaults() async {
    _tempStart = DEFAULT_TEMP_START;
    _tempWarning = DEFAULT_TEMP_WARNING;
    _tempFault = DEFAULT_TEMP_FAULT;
    _h2Fault = DEFAULT_H2_FAULT;
    _h2Warning = DEFAULT_H2_WARNING;
    _coFault = DEFAULT_CO_FAULT;
    _coWarning = DEFAULT_CO_WARNING;
    _smokeFault = DEFAULT_SMOKE_FAULT;
    _humidityWarning = DEFAULT_HUMIDITY_WARNING;
    _humidityFault = DEFAULT_HUMIDITY_FAULT;
    _humidityFaultHours = DEFAULT_HUMIDITY_FAULT_HOURS;
    _pressureWarning = DEFAULT_PRESSURE_WARNING;
    _pressureFault = DEFAULT_PRESSURE_FAULT;
    _nodeQueryRetryCount = DEFAULT_NODE_QUERY_RETRY_COUNT;
    _nodeQueryIntervalMs = DEFAULT_NODE_QUERY_INTERVAL_MS;
    _nodeDisconnectTimeoutMs = DEFAULT_NODE_DISCONNECT_TIMEOUT_MS;
    _pt100Corrections = List<double>.filled(10, 0.0);
    _upperTempCorrection = 0.0;
    _envTempCorrection = 0.0;
    _lowerTempCorrection = 0.0;

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await _backupPrefsToExternal(prefs);
  }

  // 获取所有设置的Map（用于显示）
  Map<String, dynamic> getAllSettings() {
    return {
      'tempStart': _tempStart > 0 ? _tempStart : DEFAULT_TEMP_START,
      'tempWarning': _tempWarning > 0 ? _tempWarning : DEFAULT_TEMP_WARNING,
      'tempFault': _tempFault > 0 ? _tempFault : DEFAULT_TEMP_FAULT,
      'h2Fault': _h2Fault,
      'coFault': _coFault,
      'smokeFault': _smokeFault,
      'humidityWarning': _humidityWarning,
      'humidityFault': _humidityFault,
      'humidityFaultHours': _humidityFaultHours,
      'pressureWarning': _pressureWarning,
      'pressureFault': _pressureFault,
      'nodeQueryRetryCount': _nodeQueryRetryCount,
      'nodeQueryIntervalMs': _nodeQueryIntervalMs,
      'nodeDisconnectTimeoutMs': _nodeDisconnectTimeoutMs,
      'pt100Corrections': List.from(_pt100Corrections),
      'upperTempCorrection': _upperTempCorrection,
      'envTempCorrection': _envTempCorrection,
      'lowerTempCorrection': _lowerTempCorrection,
      'aK1': _aK1,
      'aK2': _aK2,
      'bK1': _bK1,
      'bK2': _bK2,
      'cK1': _cK1,
      'cK2': _cK2,
    };
  }

  // ================= 外部备份：防止重装后丢失 =================
  static const String _backupFilePath = '/storage/emulated/0/sensor_settings_backup.json';

  Future<void> _backupPrefsToExternal(SharedPreferences prefs) async {
    try {
      final data = <String, dynamic>{};
      for (final key in prefs.getKeys()) {
        final value = prefs.get(key);
        if (value != null) data[key] = value;
      }
      final file = File(_backupFilePath);
      await file.writeAsString(jsonEncode(data));
      print('[Settings] 备份到外部存储: $_backupFilePath');
    } catch (e) {
      print('[Settings] 备份外部存储失败: $e');
    }
  }

  Future<void> _restorePrefsFromExternalIfEmpty(SharedPreferences prefs) async {
    try {
      if (prefs.getKeys().isNotEmpty) {
        return; // 已有数据，无需恢复
      }
      final file = File(_backupFilePath);
      if (!await file.exists()) return;
      final text = await file.readAsString();
      final Map<String, dynamic> data = jsonDecode(text);
      for (final entry in data.entries) {
        final key = entry.key;
        final value = entry.value;
        if (value is bool) {
          await prefs.setBool(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is String) {
          await prefs.setString(key, value);
        } else if (value is List) {
          await prefs.setString(key, jsonEncode(value));
        }
      }
      print('[Settings] 从外部存储恢复完成: $_backupFilePath');
    } catch (e) {
      print('[Settings] 从外部存储恢复失败: $e');
    }
  }
}
