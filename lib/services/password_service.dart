import 'package:shared_preferences/shared_preferences.dart';

class PasswordService {
  static final PasswordService _instance = PasswordService._internal();
  factory PasswordService() => _instance;
  PasswordService._internal();

  // 默认密码
  static const String DEFAULT_PASSWORD = '123456';
  
  // 当前密码
  String _currentPassword = DEFAULT_PASSWORD;

  // 初始化密码服务
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _currentPassword = prefs.getString('admin_password') ?? DEFAULT_PASSWORD;
  }

  // 验证密码
  bool verifyPassword(String inputPassword) {
    return inputPassword == _currentPassword;
  }

  // 修改密码
  Future<bool> changePassword(String oldPassword, String newPassword) async {
    // 验证原密码
    if (!verifyPassword(oldPassword)) {
      return false;
    }

    // 验证新密码格式（至少6位）
    if (newPassword.length < 6) {
      return false;
    }

    // 保存新密码
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('admin_password', newPassword);
    _currentPassword = newPassword;
    return true;
  }

  // 获取当前密码（用于调试，实际应用中不应该暴露）
  String getCurrentPassword() {
    return _currentPassword;
  }

  // 重置为默认密码
  Future<void> resetToDefault() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('admin_password', DEFAULT_PASSWORD);
    _currentPassword = DEFAULT_PASSWORD;
  }
}
