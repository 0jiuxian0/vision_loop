import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'models/playlist_models.dart';
import 'services/playlist_repository.dart';
import 'utils/id_generator.dart';

void main() {
  runApp(const VisionLoopApp());
}

/// Root widget of the Vision Loop application.
///
/// 当前仅包含基础路由和三个占位页面：
/// - 播放列表页（首页）
/// - 列表编辑页
/// - 播放页
class VisionLoopApp extends StatelessWidget {
  const VisionLoopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vision Loop',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      initialRoute: PlaylistListPage.routeName,
      routes: {
        PlaylistListPage.routeName: (_) => const PlaylistListPage(),
        PlaylistEditPage.routeName: (_) => const PlaylistEditPage(),
        PlayerPage.routeName: (_) => const PlayerPage(),
      },
    );
  }
}

/// 播放列表页：展示所有幻灯片项目。
class PlaylistListPage extends StatefulWidget {
  const PlaylistListPage({super.key});

  static const routeName = '/';

  @override
  State<PlaylistListPage> createState() => _PlaylistListPageState();
}

class _PlaylistListPageState extends State<PlaylistListPage> {
  final PlaylistRepository _repository = const PlaylistRepository();

  bool _isLoading = true;
  List<Playlist> _playlists = <Playlist>[];

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    setState(() {
      _isLoading = true;
    });
    final result = await _repository.loadAll();
    setState(() {
      _playlists = result;
      _isLoading = false;
    });
  }

  Future<void> _openEditor({Playlist? playlist}) async {
    final playlistId = playlist?.id;
    final result = await Navigator.of(context).pushNamed(
      PlaylistEditPage.routeName,
      arguments: playlistId,
    );

    // 如果编辑页返回 true，表示有保存操作，刷新列表。
    if (result == true) {
      await _loadPlaylists();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vision Loop 播放列表'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _playlists.isEmpty
              ? const Center(
                  child: Text('暂无幻灯片项目，点击右下角按钮新建一个吧。'),
                )
              : ListView.separated(
                  itemCount: _playlists.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final playlist = _playlists[index];
                    return ListTile(
                      title: Text(playlist.name),
                      subtitle: Text(
                        '共 ${playlist.items.length} 个媒体项',
                      ),
                      onTap: () => _openEditor(playlist: playlist),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (context) {
                              return AlertDialog(
                                title: const Text('删除幻灯片'),
                                content: Text('确定要删除 "${playlist.name}" 吗？'),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(false),
                                    child: const Text('取消'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(true),
                                    child: const Text('删除'),
                                  ),
                                ],
                              );
                            },
                          );

                          if (confirm == true) {
                            await _repository.deleteById(playlist.id);
                            await _loadPlaylists();
                          }
                        },
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('新建幻灯片'),
      ),
    );
  }
}

/// 列表编辑页：编辑单个幻灯片项目的基础信息（暂时不含媒体选择）。
class PlaylistEditPage extends StatefulWidget {
  const PlaylistEditPage({super.key});

  static const routeName = '/edit';

  @override
  State<PlaylistEditPage> createState() => _PlaylistEditPageState();
}

class _PlaylistEditPageState extends State<PlaylistEditPage> {
  final PlaylistRepository _repository = const PlaylistRepository();
  final TextEditingController _nameController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  Playlist? _playlist;
  List<MediaItem> _items = <MediaItem>[];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // 需要在 build 之后才能拿到路由参数，这里用 addPostFrameCallback。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initFromArguments();
    });
  }

  Future<void> _initFromArguments() async {
    final args = ModalRoute.of(context)?.settings.arguments;
    final String? playlistId = args is String ? args : null;

    if (playlistId == null) {
      // 新建项目。
      final now = DateTime.now();
      final playlist = Playlist(
        id: generateId('pl'),
        name: '',
        createdAt: now,
        updatedAt: now,
        items: <MediaItem>[],
      );
      setState(() {
        _playlist = playlist;
        _nameController.text = '';
        _isLoading = false;
      });
      return;
    }

    // 编辑已有项目。
    final all = await _repository.loadAll();
    final existing = all.firstWhere(
      (p) => p.id == playlistId,
      orElse: () => Playlist(
        id: playlistId,
        name: '未命名项目',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        items: <MediaItem>[],
      ),
    );

    setState(() {
      _playlist = existing;
      _nameController.text = existing.name;
      _items = List<MediaItem>.from(existing.items);
      _isLoading = false;
    });
  }

  Future<void> _addImages() async {
    final files = await _picker.pickMultiImage();
    if (files.isEmpty) {
      return;
    }

    final startIndex = _items.length;
    final newItems = <MediaItem>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      newItems.add(
        MediaItem(
          id: generateId('mi'),
          type: MediaType.image,
          uri: file.path,
          orderIndex: startIndex + i,
        ),
      );
    }

    setState(() {
      _items.addAll(newItems);
      _playlist = _playlist?.copyWith(items: _items);
    });
  }

  Future<void> _addVideo() async {
    final file = await _picker.pickVideo(
      source: ImageSource.gallery,
    );
    if (file == null) {
      return;
    }

    final newItem = MediaItem(
      id: generateId('mi'),
      type: MediaType.video,
      uri: file.path,
      orderIndex: _items.length,
    );

    setState(() {
      _items.add(newItem);
      _playlist = _playlist?.copyWith(items: _items);
    });
  }

  void _removeItem(int index) {
    setState(() {
      _items.removeAt(index);
      // 重新整理顺序索引。
      for (var i = 0; i < _items.length; i++) {
        _items[i] = _items[i].copyWith(orderIndex: i);
      }
      _playlist = _playlist?.copyWith(items: _items);
    });
  }

  String _fileName(String path) {
    // 简单从路径中提取文件名，兼容 / 和 \ 分隔符。
    final parts = path.split(RegExp(r'[\\/]+'));
    return parts.isNotEmpty ? parts.last : path;
  }

  Widget _buildMediaThumbnail(MediaItem item) {
    if (item.type == MediaType.image) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(item.uri),
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) {
            return const Icon(Icons.broken_image);
          },
        ),
      );
    }

    // 视频：生成真实缩略图
    return FutureBuilder<String?>(
      future: _generateVideoThumbnail(item.uri),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.grey.shade800,
            ),
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            ),
          );
        }

        if (snapshot.hasData && snapshot.data != null) {
          return SizedBox(
            width: 56,
            height: 56,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(
                    File(snapshot.data!),
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) {
                      return Container(
                        width: 56,
                        height: 56,
                        color: Colors.grey.shade800,
                        child: const Icon(
                          Icons.videocam,
                          color: Colors.white,
                        ),
                      );
                    },
                  ),
                  // 视频图标叠加层
                  Positioned(
                    bottom: 2,
                    right: 2,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Icon(
                        Icons.play_circle_filled,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        // 生成失败或没有数据时显示占位符
        return Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: Colors.grey.shade800,
          ),
          child: const Icon(
            Icons.videocam,
            color: Colors.white,
          ),
        );
      },
    );
  }

  Future<String?> _generateVideoThumbnail(String videoPath) async {
    try {
      final thumbnail = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: (await Directory.systemTemp).path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 200,
        quality: 75,
      );
      return thumbnail;
    } catch (e) {
      return null;
    }
  }

  Future<void> _save() async {
    final current = _playlist;
    if (current == null) return;

    final updated = current.copyWith(
      name: _nameController.text.trim().isEmpty
          ? '未命名项目'
          : _nameController.text.trim(),
      updatedAt: DateTime.now(),
      items: _items,
    );

    await _repository.upsert(updated);

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑幻灯片'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: '项目名称',
                      hintText: '例如：旅行 2024 国庆（可留空）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                Expanded(
                  child: _items.isEmpty
                      ? const Center(
                          child: Text('还没有添加任何媒体，点击下方按钮从相册选择。'),
                        )
                      : ListView.separated(
                          itemCount: _items.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            return ListTile(
                              leading: _buildMediaThumbnail(item),
                              title: Text(_fileName(item.uri)),
                              subtitle: Text(
                                item.type == MediaType.image ? '图片' : '视频',
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete),
                                onPressed: () => _removeItem(index),
                              ),
                            );
                          },
                        ),
                ),
                // 底部操作栏：返回、播放、保存
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    border: Border(
                      top: BorderSide(
                        color: Theme.of(context).dividerColor,
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('返回'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isLoading || _playlist == null
                              ? null
                              : () {
                                  Navigator.of(context).pushNamed(
                                    PlayerPage.routeName,
                                    arguments: _playlist!.id,
                                  );
                                },
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('播放'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _save,
                          icon: const Icon(Icons.check),
                          label: const Text('保存'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).primaryColor,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 添加媒体按钮
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _addImages,
                          icon: const Icon(Icons.photo),
                          label: const Text('添加图片'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _addVideo,
                          icon: const Icon(Icons.videocam),
                          label: const Text('添加视频'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// 播放页：全屏播放图片/视频，带简单淡入淡出过渡。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  static const routeName = '/player';

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  final PlaylistRepository _repository = const PlaylistRepository();

  Playlist? _playlist;
  int _currentIndex = 0;
  bool _isPlaying = true;
  bool _isLoading = true;
  bool _showControls = false;

  VideoPlayerController? _videoController;
  Timer? _imageTimer;

  @override
  void initState() {
    super.initState();
    // 进入播放页时开启沉浸式全屏（隐藏状态栏等）。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initFromArguments();
    });
  }

  Future<void> _initFromArguments() async {
    final args = ModalRoute.of(context)?.settings.arguments;
    final String? playlistId = args is String ? args : null;
    if (playlistId == null) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    final all = await _repository.loadAll();
    final playlist =
        all.firstWhere((p) => p.id == playlistId, orElse: () => all.first);

    setState(() {
      _playlist = playlist;
      _currentIndex = 0;
      _isLoading = false;
    });

    if (playlist.items.isNotEmpty) {
      await _startCurrent();
    }
  }

  List<MediaItem> get _items => _playlist?.items ?? <MediaItem>[];

  MediaItem? get _currentItem {
    if (_items.isEmpty || _currentIndex < 0 || _currentIndex >= _items.length) {
      return null;
    }
    return _items[_currentIndex];
  }

  Future<void> _startCurrent() async {
    _cancelTimersAndVideo();

    final item = _currentItem;
    if (item == null) return;

    if (item.type == MediaType.image) {
      final durationSeconds =
          item.durationSeconds ?? _playlist?.settings.slideDurationSeconds ?? 3;
      if (_isPlaying) {
        _imageTimer = Timer(Duration(seconds: durationSeconds), _next);
      }
      if (mounted) {
        setState(() {});
      }
    } else {
      final file = File(item.uri);
      final controller = VideoPlayerController.file(file);
      _videoController = controller;
      await controller.initialize();
      await controller.setLooping(false);

      controller.addListener(() {
        if (!controller.value.isInitialized) return;
        if (controller.value.position >= controller.value.duration &&
            !controller.value.isLooping) {
          _next();
        }
      });

      if (_isPlaying) {
        await controller.play();
      }
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _cancelTimersAndVideo() {
    _imageTimer?.cancel();
    _imageTimer = null;
    _videoController?.removeListener(() {});
    _videoController?.pause();
    _videoController?.dispose();
    _videoController = null;
  }

  Future<void> _next() async {
    if (_items.isEmpty) return;
    final loop = _playlist?.settings.loop ?? true;
    var nextIndex = _currentIndex + 1;
    if (nextIndex >= _items.length) {
      if (!loop) return;
      nextIndex = 0;
    }
    setState(() {
      _currentIndex = nextIndex;
    });
    await _startCurrent();
  }

  Future<void> _previous() async {
    if (_items.isEmpty) return;
    var prevIndex = _currentIndex - 1;
    if (prevIndex < 0) {
      prevIndex = _items.length - 1;
    }
    setState(() {
      _currentIndex = prevIndex;
    });
    await _startCurrent();
  }

  Future<void> _togglePlayPause() async {
    setState(() {
      _isPlaying = !_isPlaying;
    });

    final item = _currentItem;
    if (item == null) return;

    if (item.type == MediaType.image) {
      _imageTimer?.cancel();
      if (_isPlaying) {
        final durationSeconds = item.durationSeconds ??
            _playlist?.settings.slideDurationSeconds ??
            3;
        _imageTimer = Timer(Duration(seconds: durationSeconds), _next);
      }
    } else {
      final controller = _videoController;
      if (controller == null) return;
      if (_isPlaying) {
        await controller.play();
      } else {
        await controller.pause();
      }
    }
  }

  @override
  void dispose() {
    _cancelTimersAndVideo();
    // 离开播放页时恢复系统 UI 显示。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = _currentItem;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(
                  child: Text(
                    '当前项目没有媒体，请在编辑页添加。',
                    style: TextStyle(color: Colors.white),
                  ),
                )
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() {
                      _showControls = !_showControls;
                    });
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        transitionBuilder: (child, animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: child,
                          );
                        },
                        child: _buildMediaContent(item),
                      ),
                      if (_showControls) ...[
                        // 顶部返回 + 标题栏。
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          child: SafeArea(
                            child: Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              color: Colors.black54,
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.arrow_back),
                                    color: Colors.white,
                                    onPressed: () {
                                      Navigator.of(context).pop();
                                    },
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      _playlist?.name ?? '播放预览',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // 底部控制条。
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: SafeArea(
                            child: Container(
                              margin: const EdgeInsets.all(8),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: _buildControls(context),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _buildMediaContent(MediaItem? item) {
    if (item == null) {
      return const SizedBox.shrink();
    }

    final key = ValueKey<String>('media_${item.id}');

    if (item.type == MediaType.image) {
      // 不裁剪整张图片，按比例缩放，最长边铺满屏幕，另一边可能有黑边。
      return Container(
        key: key,
        color: Colors.black,
        alignment: Alignment.center,
        child: Image.file(
          File(item.uri),
          fit: BoxFit.contain,
        ),
      );
    }

    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    // 视频同样保持完整画面，按比例缩放至最长边铺满，另一边允许留黑边。
    return Container(
      key: key,
      color: Colors.black,
      alignment: Alignment.center,
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          iconSize: 32,
          color: Colors.white,
          icon: const Icon(Icons.skip_previous),
          onPressed: _previous,
        ),
        const SizedBox(width: 16),
        IconButton(
          iconSize: 40,
          color: Colors.white,
          icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
          onPressed: _togglePlayPause,
        ),
        const SizedBox(width: 16),
        IconButton(
          iconSize: 32,
          color: Colors.white,
          icon: const Icon(Icons.skip_next),
          onPressed: _next,
        ),
      ],
    );
  }
}
