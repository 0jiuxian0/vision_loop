import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

/// 全局设置仓库。
class SettingsRepository {
  const SettingsRepository();

  static const String _kSettingsKey = 'vision_loop.app_settings';

  /// 读取全局设置。
  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSettingsKey);
    final settings = AppSettings.decode(raw);
    return settings ?? AppSettings();
  }

  /// 保存全局设置。
  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSettingsKey, settings.encode());
  }
}

