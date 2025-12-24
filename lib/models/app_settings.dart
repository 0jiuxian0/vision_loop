import 'dart:convert';

/// 播放模式：横屏或竖屏。
enum PlaybackOrientation {
  portrait, // 竖屏
  landscape, // 横屏
}

PlaybackOrientation playbackOrientationFromString(String value) {
  switch (value) {
    case 'portrait':
      return PlaybackOrientation.portrait;
    case 'landscape':
      return PlaybackOrientation.landscape;
    default:
      return PlaybackOrientation.portrait;
  }
}

String playbackOrientationToString(PlaybackOrientation orientation) {
  switch (orientation) {
    case PlaybackOrientation.portrait:
      return 'portrait';
    case PlaybackOrientation.landscape:
      return 'landscape';
  }
}

/// 全局应用设置。
class AppSettings {
  AppSettings({
    this.playbackOrientation = PlaybackOrientation.portrait,
    this.slideDurationSeconds = 3,
  });

  /// 播放模式：横屏或竖屏。
  final PlaybackOrientation playbackOrientation;

  /// 图片切换间隔（秒）。
  final int slideDurationSeconds;

  AppSettings copyWith({
    PlaybackOrientation? playbackOrientation,
    int? slideDurationSeconds,
  }) {
    return AppSettings(
      playbackOrientation: playbackOrientation ?? this.playbackOrientation,
      slideDurationSeconds: slideDurationSeconds ?? this.slideDurationSeconds,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'playbackOrientation': playbackOrientationToString(playbackOrientation),
      'slideDurationSeconds': slideDurationSeconds,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      playbackOrientation: playbackOrientationFromString(
        json['playbackOrientation'] as String? ?? 'portrait',
      ),
      slideDurationSeconds: json['slideDurationSeconds'] as int? ?? 3,
    );
  }

  /// 从 JSON 字符串解码。
  static AppSettings? decode(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) {
      return null;
    }
    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return AppSettings.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  /// 编码为 JSON 字符串。
  String encode() {
    return jsonEncode(toJson());
  }
}

