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

/// 播放时长单位。
enum PlaybackDurationUnit {
  hours,   // 小时
  minutes, // 分钟
  seconds, // 秒
}

/// 全局应用设置。
class AppSettings {
  AppSettings({
    this.playbackOrientation = PlaybackOrientation.landscape,
    this.slideDurationSeconds = 3,
    this.playbackMode = PlaybackMode.sequential,
    this.maxPlaybackDurationSeconds = -1, // -1 表示不限制
    this.playbackDurationUnit = PlaybackDurationUnit.seconds,
    this.slideDurationUnit = PlaybackDurationUnit.seconds,
  });

  /// 播放模式：横屏或竖屏。
  final PlaybackOrientation playbackOrientation;

  /// 图片切换间隔（秒）。
  final int slideDurationSeconds;

  /// 播放顺序模式。
  final PlaybackMode playbackMode;

  /// 最大播放时长（秒）。-1 表示不限制。
  final int maxPlaybackDurationSeconds;

  /// 播放时长单位（用于设置页面显示和输入）。
  final PlaybackDurationUnit playbackDurationUnit;

  /// 切换间隔单位（用于设置页面显示和输入）。
  final PlaybackDurationUnit slideDurationUnit;

  AppSettings copyWith({
    PlaybackOrientation? playbackOrientation,
    int? slideDurationSeconds,
    PlaybackMode? playbackMode,
    int? maxPlaybackDurationSeconds,
    PlaybackDurationUnit? playbackDurationUnit,
    PlaybackDurationUnit? slideDurationUnit,
  }) {
    return AppSettings(
      playbackOrientation: playbackOrientation ?? this.playbackOrientation,
      slideDurationSeconds: slideDurationSeconds ?? this.slideDurationSeconds,
      playbackMode: playbackMode ?? this.playbackMode,
      maxPlaybackDurationSeconds: maxPlaybackDurationSeconds ?? this.maxPlaybackDurationSeconds,
      playbackDurationUnit: playbackDurationUnit ?? this.playbackDurationUnit,
      slideDurationUnit: slideDurationUnit ?? this.slideDurationUnit,
    );
  }

  /// 获取播放时长限制的 Duration 对象。如果为 -1，返回 null。
  Duration? get maxPlaybackDuration {
    if (maxPlaybackDurationSeconds == -1) {
      return null;
    }
    return Duration(seconds: maxPlaybackDurationSeconds);
  }

  Map<String, dynamic> toJson() {
    return {
      'playbackOrientation': playbackOrientationToString(playbackOrientation),
      'slideDurationSeconds': slideDurationSeconds,
      'playbackMode': _playbackModeToString(playbackMode),
      'maxPlaybackDurationSeconds': maxPlaybackDurationSeconds,
      'playbackDurationUnit': _playbackDurationUnitToString(playbackDurationUnit),
      'slideDurationUnit': _playbackDurationUnitToString(slideDurationUnit),
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
      maxPlaybackDurationSeconds: json['maxPlaybackDurationSeconds'] as int? ?? -1,
      playbackDurationUnit: _playbackDurationUnitFromString(
        json['playbackDurationUnit'] as String? ?? 'seconds',
      ),
      slideDurationUnit: _playbackDurationUnitFromString(
        json['slideDurationUnit'] as String? ?? 'seconds',
      ),
    );
  }

  static String _playbackDurationUnitToString(PlaybackDurationUnit unit) {
    switch (unit) {
      case PlaybackDurationUnit.hours:
        return 'hours';
      case PlaybackDurationUnit.minutes:
        return 'minutes';
      case PlaybackDurationUnit.seconds:
        return 'seconds';
    }
  }

  static PlaybackDurationUnit _playbackDurationUnitFromString(String value) {
    switch (value) {
      case 'hours':
        return PlaybackDurationUnit.hours;
      case 'minutes':
        return PlaybackDurationUnit.minutes;
      case 'seconds':
        return PlaybackDurationUnit.seconds;
      default:
        return PlaybackDurationUnit.hours;
    }
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

