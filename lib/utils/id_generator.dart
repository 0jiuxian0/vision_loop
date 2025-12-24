import 'dart:math';

/// 非严格唯一，但在本地单机应用中足够使用的简单 ID 生成器。
///
/// 格式类似：`pl_1703320000000_123456`
String generateId([String prefix = 'pl']) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final rand = Random().nextInt(999999);
  return '${prefix}_$now\_$rand';
}


