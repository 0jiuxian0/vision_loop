import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist_models.dart';

/// Key used to store playlists JSON in [SharedPreferences].
const String _kPlaylistsKey = 'vision_loop.playlists';

/// 简单的本地播放列表仓库。
///
/// - 使用 `shared_preferences` 将所有播放列表序列化为 JSON 存储。
/// - 目前不做复杂并发控制，后续如有需要可以再扩展。
class PlaylistRepository {
  const PlaylistRepository();

  /// 读取所有播放列表。
  Future<List<Playlist>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPlaylistsKey);
    if (raw == null || raw.isEmpty) {
      return <Playlist>[];
    }
    return Playlist.decodeList(raw);
  }

  /// 保存一组播放列表，覆盖原有数据。
  Future<void> saveAll(List<Playlist> playlists) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = Playlist.encodeList(playlists);
    await prefs.setString(_kPlaylistsKey, encoded);
  }

  /// 新增或更新一个播放列表。
  ///
  /// 如果 `playlist.id` 已存在，则覆盖；否则追加。
  Future<void> upsert(Playlist playlist) async {
    final all = await loadAll();
    final index = all.indexWhere((p) => p.id == playlist.id);
    if (index >= 0) {
      all[index] = playlist;
    } else {
      all.add(playlist);
    }
    await saveAll(all);
  }

  /// 根据 id 删除播放列表。
  Future<void> deleteById(String id) async {
    final all = await loadAll();
    all.removeWhere((p) => p.id == id);
    await saveAll(all);
  }
}


