import 'dart:convert';

/// 媒体类型：图片或视频。
enum MediaType {
  image,
  video,
}

MediaType mediaTypeFromString(String value) {
  switch (value) {
    case 'image':
      return MediaType.image;
    case 'video':
      return MediaType.video;
    default:
      return MediaType.image;
  }
}

String mediaTypeToString(MediaType type) {
  switch (type) {
    case MediaType.image:
      return 'image';
    case MediaType.video:
      return 'video';
  }
}

/// 单个媒体项（图片或视频）。
class MediaItem {
  MediaItem({
    required this.id,
    required this.type,
    required this.uri,
    required this.orderIndex,
    this.durationSeconds,
  });

  final String id;
  final MediaType type;
  final String uri;
  final int orderIndex;

  /// 对图片是停留时长；对视频是裁剪后的时长（可选）。
  final int? durationSeconds;

  MediaItem copyWith({
    String? id,
    MediaType? type,
    String? uri,
    int? orderIndex,
    int? durationSeconds,
  }) {
    return MediaItem(
      id: id ?? this.id,
      type: type ?? this.type,
      uri: uri ?? this.uri,
      orderIndex: orderIndex ?? this.orderIndex,
      durationSeconds: durationSeconds ?? this.durationSeconds,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'type': mediaTypeToString(type),
      'uri': uri,
      'orderIndex': orderIndex,
      'durationSeconds': durationSeconds,
    };
  }

  factory MediaItem.fromJson(Map<String, dynamic> json) {
    return MediaItem(
      id: json['id'] as String,
      type: mediaTypeFromString(json['type'] as String),
      uri: json['uri'] as String,
      orderIndex: (json['orderIndex'] as num).toInt(),
      durationSeconds: (json['durationSeconds'] as num?)?.toInt(),
    );
  }
}

/// 播放列表的全局设置。
class PlaylistSettings {
  const PlaylistSettings({
    this.slideDurationSeconds = 3,
    this.loop = true,
    this.transition = 'fade',
  });

  /// 图片默认停留时间（秒）。
  final int slideDurationSeconds;

  /// 是否循环播放。
  final bool loop;

  /// 过渡效果类型（首版只用 'fade'）。
  final String transition;

  PlaylistSettings copyWith({
    int? slideDurationSeconds,
    bool? loop,
    String? transition,
  }) {
    return PlaylistSettings(
      slideDurationSeconds: slideDurationSeconds ?? this.slideDurationSeconds,
      loop: loop ?? this.loop,
      transition: transition ?? this.transition,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'slideDurationSeconds': slideDurationSeconds,
      'loop': loop,
      'transition': transition,
    };
  }

  factory PlaylistSettings.fromJson(Map<String, dynamic> json) {
    return PlaylistSettings(
      slideDurationSeconds:
          (json['slideDurationSeconds'] as num?)?.toInt() ?? 3,
      loop: (json['loop'] as bool?) ?? true,
      transition: (json['transition'] as String?) ?? 'fade',
    );
  }
}

/// 一个幻灯片项目（播放列表）。
class Playlist {
  Playlist({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.items,
    this.settings = const PlaylistSettings(),
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final PlaylistSettings settings;
  final List<MediaItem> items;

  Playlist copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    DateTime? updatedAt,
    PlaylistSettings? settings,
    List<MediaItem>? items,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      settings: settings ?? this.settings,
      items: items ?? this.items,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'settings': settings.toJson(),
      'items': items.map((e) => e.toJson()).toList(),
    };
  }

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      settings: PlaylistSettings.fromJson(
        json['settings'] as Map<String, dynamic>,
      ),
      items: (json['items'] as List<dynamic>)
          .map(
            (e) => MediaItem.fromJson(e as Map<String, dynamic>),
          )
          .toList(),
    );
  }

  /// 将一组播放列表编码为 JSON 字符串，方便存储。
  static String encodeList(List<Playlist> playlists) {
    final list = playlists.map((p) => p.toJson()).toList();
    return jsonEncode(list);
  }

  /// 从 JSON 字符串解码为播放列表集合。
  static List<Playlist> decodeList(String source) {
    if (source.isEmpty) {
      return <Playlist>[];
    }
    final dynamic decoded = jsonDecode(source);
    if (decoded is! List) {
      return <Playlist>[];
    }
    return decoded
        .map(
          (e) => Playlist.fromJson(e as Map<String, dynamic>),
        )
        .toList();
  }
}


