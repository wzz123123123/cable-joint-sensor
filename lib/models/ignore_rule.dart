class IgnoreRule {
  final String id;
  final String nodeId;
  final String alertType;
  final String alertLevel;
  final String operator;
  final DateTime createTime;
  final String reason;
  final bool isActive;
  final DateTime? expiresAt; // 可选过期时间

  IgnoreRule({
    required this.id,
    required this.nodeId,
    required this.alertType,
    required this.alertLevel,
    required this.operator,
    required this.createTime,
    required this.reason,
    required this.isActive,
    this.expiresAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'nodeId': nodeId,
      'alertType': alertType,
      'alertLevel': alertLevel,
      'operator': operator,
      'createTime': createTime.millisecondsSinceEpoch,
      'reason': reason,
      'isActive': isActive,
      'expiresAt': expiresAt?.millisecondsSinceEpoch,
    };
  }

  factory IgnoreRule.fromJson(Map<String, dynamic> json) {
    return IgnoreRule(
      id: json['id'],
      nodeId: json['nodeId'],
      alertType: json['alertType'],
      alertLevel: json['alertLevel'],
      operator: json['operator'],
      createTime: DateTime.fromMillisecondsSinceEpoch(json['createTime']),
      reason: json['reason'],
      isActive: json['isActive'],
      expiresAt: (json['expiresAt'] == null) ? null : DateTime.fromMillisecondsSinceEpoch(json['expiresAt']),
    );
  }

  IgnoreRule copyWith({
    String? id,
    String? nodeId,
    String? alertType,
    String? alertLevel,
    String? operator,
    DateTime? createTime,
    String? reason,
    bool? isActive,
    DateTime? expiresAt,
  }) {
    return IgnoreRule(
      id: id ?? this.id,
      nodeId: nodeId ?? this.nodeId,
      alertType: alertType ?? this.alertType,
      alertLevel: alertLevel ?? this.alertLevel,
      operator: operator ?? this.operator,
      createTime: createTime ?? this.createTime,
      reason: reason ?? this.reason,
      isActive: isActive ?? this.isActive,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }
}
