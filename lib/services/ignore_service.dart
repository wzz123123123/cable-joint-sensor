import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ignore_rule.dart';

class IgnoreService {
  static final IgnoreService _instance = IgnoreService._internal();
  factory IgnoreService() => _instance;
  IgnoreService._internal();

  static const String _ignoreRulesKey = 'ignore_rules';
  final List<IgnoreRule> _ignoreRules = [];

  // 初始化忽略规则
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final rulesJson = prefs.getString(_ignoreRulesKey);
    
    if (rulesJson != null) {
      try {
        final List<dynamic> rulesList = jsonDecode(rulesJson);
        _ignoreRules.clear();
        _ignoreRules.addAll(
          rulesList.map((json) => IgnoreRule.fromJson(json)).toList()
        );
      } catch (e) {
        print('加载忽略规则失败: $e');
        _ignoreRules.clear();
      }
    }
  }

  // 添加忽略规则
  Future<void> addIgnoreRule({
    required String nodeId,
    required String alertType,
    required String alertLevel,
    required String operator,
    required String reason,
    DateTime? expiresAt,
  }) async {
    final rule = IgnoreRule(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      nodeId: nodeId,
      alertType: alertType,
      alertLevel: alertLevel,
      operator: operator,
      createTime: DateTime.now(),
      reason: reason,
      isActive: true,
      expiresAt: expiresAt,
    );

    _ignoreRules.add(rule);
    await _saveRules();
  }

  // 删除忽略规则
  Future<void> removeIgnoreRule(String ruleId) async {
    _ignoreRules.removeWhere((rule) => rule.id == ruleId);
    await _saveRules();
  }

  // 激活/停用忽略规则
  Future<void> toggleIgnoreRule(String ruleId, bool isActive) async {
    final index = _ignoreRules.indexWhere((rule) => rule.id == ruleId);
    if (index != -1) {
      _ignoreRules[index] = _ignoreRules[index].copyWith(isActive: isActive);
      await _saveRules();
    }
  }

  // 检查是否应该忽略某个预警/故障
  bool shouldIgnoreAlert({
    required String nodeId,
    required String alertType,
    required String alertLevel,
  }) {
    final now = DateTime.now();
    // 自动清理过期规则
    _ignoreRules.removeWhere((r) => r.expiresAt != null && r.expiresAt!.isBefore(now));
    return _ignoreRules.any((rule) =>
        rule.isActive &&
        rule.nodeId == nodeId &&
        rule.alertType == alertType &&
        rule.alertLevel == alertLevel &&
        (rule.expiresAt == null || rule.expiresAt!.isAfter(now)));
  }

  // 获取所有忽略规则
  List<IgnoreRule> getAllIgnoreRules() {
    return List.from(_ignoreRules);
  }

  // 获取指定节点的忽略规则
  List<IgnoreRule> getIgnoreRulesByNode(String nodeId) {
    return _ignoreRules.where((rule) => rule.nodeId == nodeId).toList();
  }

  // 获取活跃的忽略规则
  List<IgnoreRule> getActiveIgnoreRules() {
    return _ignoreRules.where((rule) => rule.isActive).toList();
  }

  // 保存忽略规则到本地存储
  Future<void> _saveRules() async {
    final prefs = await SharedPreferences.getInstance();
    final rulesJson = jsonEncode(_ignoreRules.map((rule) => rule.toJson()).toList());
    await prefs.setString(_ignoreRulesKey, rulesJson);
  }

  // 清空所有忽略规则
  Future<void> clearAllRules() async {
    _ignoreRules.clear();
    await _saveRules();
  }

  // 按节点清空忽略规则
  Future<void> clearRulesForNode(String nodeId) async {
    _ignoreRules.removeWhere((rule) => rule.nodeId == nodeId);
    await _saveRules();
  }

  // 获取忽略规则统计信息
  Map<String, int> getIgnoreStats() {
    final stats = <String, int>{};
    for (final rule in _ignoreRules) {
      final key = '${rule.alertType}_${rule.alertLevel}';
      stats[key] = (stats[key] ?? 0) + 1;
    }
    return stats;
  }
}
