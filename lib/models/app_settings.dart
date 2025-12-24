import 'dart:convert';

/// 播放模式：横屏或竖屏。
enum PlaybackOrientation {
  portrait, // 竖屏
  landscape, // 横屏
}

/// 播放顺序模式。
enum PlaybackMode {
  sequential, // 顺序播放
  reverse, // 倒序播放
  random, // 随机播放
}

PlaybackOrientation playbackOrientationFromString(String value) {
  switch (value) {
    case 'portrait':
      return PlaybackOrientation.portrait;
    case 'landscape':
      return PlaybackOrientation.landscape;
    default:
      return PlaybackOrientation.landscape;
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
    this.playbackOrientation = PlaybackOrientation.landscape,
    this.slideDurationSeconds = 3,
    this.playbackMode = PlaybackMode.sequential,
  });

  /// 播放模式：横屏或竖屏。
  final PlaybackOrientation playbackOrientation;

  /// 图片切换间隔（秒）。
  final int slideDurationSeconds;

  /// 播放顺序模式。
  final PlaybackMode playbackMode;

  AppSettings copyWith({
    PlaybackOrientation? playbackOrientation,
    int? slideDurationSeconds,
    PlaybackMode? playbackMode,
  }) {
    return AppSettings(
      playbackOrientation: playbackOrientation ?? this.playbackOrientation,
      slideDurationSeconds: slideDurationSeconds ?? this.slideDurationSeconds,
      playbackMode: playbackMode ?? this.playbackMode,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'playbackOrientation': playbackOrientationToString(playbackOrientation),
      'slideDurationSeconds': slideDurationSeconds,
      'playbackMode': _playbackModeToString(playbackMode),
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      playbackOrientation: playbackOrientationFromString(
        json['playbackOrientation'] as String? ?? 'landscape',
      ),
      slideDurationSeconds: json['slideDurationSeconds'] as int? ?? 3,
      playbackMode: _playbackModeFromString(
        json['playbackMode'] as String? ?? 'sequential',
      ),
    );
  }

  static String _playbackModeToString(PlaybackMode mode) {
    switch (mode) {
      case PlaybackMode.sequential:
        return 'sequential';
      case PlaybackMode.reverse:
        return 'reverse';
      case PlaybackMode.random:
        return 'random';
    }
  }

  static PlaybackMode _playbackModeFromString(String value) {
    switch (value) {
      case 'sequential':
        return PlaybackMode.sequential;
      case 'reverse':
        return PlaybackMode.reverse;
      case 'random':
        return PlaybackMode.random;
      default:
        return PlaybackMode.sequential;
    }
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

