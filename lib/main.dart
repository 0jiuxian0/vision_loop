import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'models/app_settings.dart';
import 'models/playlist_models.dart';
import 'services/playlist_repository.dart';
import 'services/settings_repository.dart';
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
        SettingsPage.routeName: (_) => const SettingsPage(),
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
                  child: Text('暂无幻灯片项目，点击下方按钮新建一个吧。'),
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
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
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
                onPressed: () {
                  Navigator.of(context).pushNamed(SettingsPage.routeName);
                },
                icon: const Icon(Icons.settings),
                label: const Text('设置'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _openEditor(),
                icon: const Icon(Icons.add),
                label: const Text('新建幻灯片'),
              ),
            ),
          ],
        ),
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
    debugPrint('[EditPage] _addImages: 开始选择图片');
    final files = await _picker.pickMultiImage();
    debugPrint('[EditPage] _addImages: 选择了${files.length}张图片');
    
    if (files.isEmpty) {
      debugPrint('[EditPage] _addImages: 未选择图片，退出');
      return;
    }

    final startIndex = _items.length;
    final newItems = <MediaItem>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final filePath = file.path;
      debugPrint('[EditPage] _addImages: 处理图片 $i - path=$filePath');
      
      // 检查文件是否存在
      final fileObj = File(filePath);
      final fileExists = await fileObj.exists();
      final fileSize = fileExists ? await fileObj.length() : 0;
      debugPrint('[EditPage] _addImages: 图片 $i 文件检查 - exists=$fileExists, size=$fileSize bytes');
      
      if (!fileExists) {
        debugPrint('[EditPage] _addImages: 图片 $i 文件不存在，跳过');
        continue;
      }

      // 直接使用原始路径，不复制
      newItems.add(
        MediaItem(
          id: generateId('mi'),
          type: MediaType.image,
          uri: filePath,
          orderIndex: startIndex + newItems.length,
        ),
      );
    }

    debugPrint('[EditPage] _addImages: 添加了${newItems.length}个媒体项到列表');
    setState(() {
      _items.addAll(newItems);
      _playlist = _playlist?.copyWith(items: _items);
    });
  }

  Future<void> _addVideo() async {
    debugPrint('[EditPage] _addVideo: 开始选择视频');
    final file = await _picker.pickVideo(
      source: ImageSource.gallery,
    );
    if (file == null) {
      debugPrint('[EditPage] _addVideo: 未选择视频，退出');
      return;
    }

    final filePath = file.path;
    debugPrint('[EditPage] _addVideo: 处理视频 - path=$filePath');
    
    // 检查文件是否存在
    final fileObj = File(filePath);
    final fileExists = await fileObj.exists();
    final fileSize = fileExists ? await fileObj.length() : 0;
    debugPrint('[EditPage] _addVideo: 视频文件检查 - exists=$fileExists, size=$fileSize bytes');
    
    if (!fileExists) {
      debugPrint('[EditPage] _addVideo: 文件不存在，退出');
      return;
    }

    // 直接使用原始路径，不复制
    final newItem = MediaItem(
      id: generateId('mi'),
      type: MediaType.video,
      uri: filePath,
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

  /// 读取图片文件的字节数据（编辑页使用）
  Future<Uint8List?> _loadImageBytes(File file) async {
    try {
      if (!await file.exists()) {
        debugPrint('[EditPage] _loadImageBytes: 文件不存在 - ${file.path}');
        return null;
      }

      final bytes = await file.readAsBytes();
      debugPrint('[EditPage] _loadImageBytes: 读取成功 - path=${file.path}, size=${bytes.length} bytes');
      return bytes;
    } catch (e, stackTrace) {
      debugPrint('[EditPage] _loadImageBytes: 读取失败 - path=${file.path}, error=$e');
      debugPrint('[EditPage] _loadImageBytes: 堆栈: $stackTrace');
      return null;
    }
  }

  String _fileName(String path) {
    // 简单从路径中提取文件名，兼容 / 和 \ 分隔符。
    final parts = path.split(RegExp(r'[\\/]+'));
    return parts.isNotEmpty ? parts.last : path;
  }

  Widget _buildMediaThumbnail(MediaItem item) {
    if (item.type == MediaType.image) {
      final file = File(item.uri);
      debugPrint('[EditPage] _buildMediaThumbnail: 构建图片缩略图 - path=${item.uri}');
      
      return FutureBuilder<Uint8List?>(
        future: _loadImageBytes(file),
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
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            );
          }

          if (snapshot.hasError) {
            debugPrint('[EditPage] _buildMediaThumbnail: 读取文件字节失败 - path=${item.uri}, error=${snapshot.error}');
            return const Icon(Icons.broken_image);
          }

          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            debugPrint('[EditPage] _buildMediaThumbnail: 文件字节为空 - path=${item.uri}');
            return const Icon(Icons.broken_image);
          }

          debugPrint('[EditPage] _buildMediaThumbnail: 文件字节读取成功 - path=${item.uri}, size=${bytes.length} bytes');
          
          // 检查文件头，判断图片格式
          String? format;
          if (bytes.length >= 2) {
            if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
              format = 'JPEG';
            } else if (bytes.length >= 8 && 
                       bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
              format = 'PNG';
            } else if (bytes.length >= 6 && 
                       bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
              format = 'GIF';
            } else if (bytes.length >= 12 && 
                       bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
              format = 'WEBP';
            }
          }
          debugPrint('[EditPage] _buildMediaThumbnail: 检测到的图片格式 - path=${item.uri}, format=$format');
          
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              bytes,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded) {
                  debugPrint('[EditPage] _buildMediaThumbnail: 缩略图同步加载完成 - path=${item.uri}');
                } else if (frame != null) {
                  debugPrint('[EditPage] _buildMediaThumbnail: 缩略图异步加载完成 - path=${item.uri}');
                } else {
                  debugPrint('[EditPage] _buildMediaThumbnail: 缩略图正在加载中 - path=${item.uri}');
                }
                return child;
              },
              errorBuilder: (context, error, stackTrace) {
                debugPrint('[EditPage] _buildMediaThumbnail: 缩略图解码失败！ - path=${item.uri}, error=$error');
                debugPrint('[EditPage] _buildMediaThumbnail: 错误堆栈: $stackTrace');
                return const Icon(Icons.broken_image);
              },
            ),
          );
        },
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
  final SettingsRepository _settingsRepository = const SettingsRepository();

  Playlist? _playlist;
  AppSettings? _settings;
  int _currentIndex = 0;
  bool _isPlaying = true;
  bool _isLoading = true;
  bool _showControls = false;

  VideoPlayerController? _videoController;
  Timer? _imageTimer;
  
  // 预加载缓存：存储图片的字节数据，key为MediaItem的id
  final Map<String, Uint8List> _preloadedImageCache = {};

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

    // 加载播放列表和全局设置
    final all = await _repository.loadAll();
    final playlist =
        all.firstWhere((p) => p.id == playlistId, orElse: () => all.first);
    final settings = await _settingsRepository.load();

    // 根据设置锁定屏幕方向
    if (settings.playbackOrientation == PlaybackOrientation.landscape) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }

    setState(() {
      _playlist = playlist;
      _settings = settings;
      _currentIndex = 0;
      _isLoading = false;
    });

    if (playlist.items.isNotEmpty) {
      // 预加载当前图片（第一张）
      final currentItem = playlist.items[0];
      if (currentItem.type == MediaType.image) {
        await _preloadImageAtIndex(0);
      }
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
    debugPrint('[Player] _startCurrent: 开始启动当前媒体, index=$_currentIndex');
    _cancelTimersAndVideo();

    final item = _currentItem;
    if (item == null) {
      debugPrint('[Player] _startCurrent: item为null，退出');
      return;
    }

    debugPrint('[Player] _startCurrent: 媒体项信息 - id=${item.id}, type=${item.type}, uri=${item.uri}, orderIndex=${item.orderIndex}');

    if (item.type == MediaType.image) {
      // 检查文件是否存在
      final file = File(item.uri);
      final exists = await file.exists();
      debugPrint('[Player] _startCurrent: 图片文件检查 - path=${item.uri}, exists=$exists, size=${exists ? await file.length() : 0}');
      
      if (!exists) {
        debugPrint('[Player] _startCurrent: 图片文件不存在！');
      }

      // 优先使用全局设置的切换间隔
      final durationSeconds = item.durationSeconds ??
          _settings?.slideDurationSeconds ??
          _playlist?.settings.slideDurationSeconds ??
          3;
      debugPrint('[Player] _startCurrent: 图片切换间隔=${durationSeconds}秒');
      
      if (_isPlaying) {
        _imageTimer = Timer(Duration(seconds: durationSeconds), () {
          debugPrint('[Player] _startCurrent: 图片定时器触发，准备切换到下一张');
          _next();
        });
      }
      if (mounted) {
        debugPrint('[Player] _startCurrent: 调用setState更新图片显示');
        setState(() {});
      }
      
      // 启动当前媒体后，后台预加载下一张和上一张图片（双向预加载）
      _preloadNextImage();
      _preloadPreviousImage();
    } else {
      final file = File(item.uri);
      final exists = await file.exists();
      debugPrint('[Player] _startCurrent: 视频文件检查 - path=${item.uri}, exists=$exists');
      
      final controller = VideoPlayerController.file(file);
      _videoController = controller;
      debugPrint('[Player] _startCurrent: 开始初始化视频控制器');
      await controller.initialize();
      debugPrint('[Player] _startCurrent: 视频控制器初始化完成 - initialized=${controller.value.isInitialized}, duration=${controller.value.duration}');
      await controller.setLooping(false);

      controller.addListener(() {
        if (!controller.value.isInitialized) return;
        if (controller.value.position >= controller.value.duration &&
            !controller.value.isLooping) {
          debugPrint('[Player] _startCurrent: 视频播放完成，准备切换到下一个');
          _next();
        }
      });

      if (_isPlaying) {
        debugPrint('[Player] _startCurrent: 开始播放视频');
        await controller.play();
      }
      if (mounted) {
        debugPrint('[Player] _startCurrent: 调用setState更新视频显示');
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

  /// 获取下一张图片的索引（考虑循环）
  int? _getNextImageIndex(int currentIndex) {
    if (_items.isEmpty) return null;
    final loop = _playlist?.settings.loop ?? true;
    var nextIndex = currentIndex + 1;
    if (nextIndex >= _items.length) {
      if (!loop) return null;
      nextIndex = 0;
    }
    // 只预加载图片，不预加载视频
    if (nextIndex < _items.length && _items[nextIndex].type == MediaType.image) {
      return nextIndex;
    }
    return null;
  }

  /// 获取上一张图片的索引（考虑循环）
  int? _getPreviousImageIndex(int currentIndex) {
    if (_items.isEmpty) return null;
    var prevIndex = currentIndex - 1;
    if (prevIndex < 0) {
      prevIndex = _items.length - 1;
    }
    // 只预加载图片，不预加载视频
    if (prevIndex >= 0 && prevIndex < _items.length && _items[prevIndex].type == MediaType.image) {
      return prevIndex;
    }
    return null;
  }

  /// 预加载指定索引的图片
  Future<void> _preloadImageAtIndex(int index) async {
    if (index < 0 || index >= _items.length) {
      debugPrint('[Player] _preloadImageAtIndex: 索引无效 - index=$index');
      return;
    }

    final item = _items[index];
    // 只预加载图片，不预加载视频
    if (item.type != MediaType.image) {
      debugPrint('[Player] _preloadImageAtIndex: 不是图片类型，跳过 - id=${item.id}, type=${item.type}');
      return;
    }

    // 如果已经预加载过，跳过
    if (_preloadedImageCache.containsKey(item.id)) {
      debugPrint('[Player] _preloadImageAtIndex: 图片已预加载 - id=${item.id}, index=$index');
      return;
    }

    debugPrint('[Player] _preloadImageAtIndex: 开始预加载图片 - id=${item.id}, index=$index, path=${item.uri}');
    
    try {
      final file = File(item.uri);
      if (!await file.exists()) {
        debugPrint('[Player] _preloadImageAtIndex: 文件不存在，跳过预加载 - path=${item.uri}');
        return;
      }

      final bytes = await file.readAsBytes();
      _preloadedImageCache[item.id] = bytes;
      debugPrint('[Player] _preloadImageAtIndex: 预加载完成 - id=${item.id}, size=${bytes.length} bytes');
    } catch (e, stackTrace) {
      debugPrint('[Player] _preloadImageAtIndex: 预加载失败 - id=${item.id}, error=$e');
      debugPrint('[Player] _preloadImageAtIndex: 堆栈: $stackTrace');
    }
  }

  /// 预加载下一张图片
  Future<void> _preloadNextImage() async {
    final nextIndex = _getNextImageIndex(_currentIndex);
    if (nextIndex != null) {
      await _preloadImageAtIndex(nextIndex);
    } else {
      debugPrint('[Player] _preloadNextImage: 没有下一张图片需要预加载');
    }
  }

  /// 预加载上一张图片
  Future<void> _preloadPreviousImage() async {
    final prevIndex = _getPreviousImageIndex(_currentIndex);
    if (prevIndex != null) {
      await _preloadImageAtIndex(prevIndex);
    } else {
      debugPrint('[Player] _preloadPreviousImage: 没有上一张图片需要预加载');
    }
  }

  Future<void> _next() async {
    debugPrint('[Player] _next: 开始切换到下一项, 当前index=$_currentIndex, 总数量=${_items.length}');
    if (_items.isEmpty) {
      debugPrint('[Player] _next: 媒体列表为空，退出');
      return;
    }
    final loop = _playlist?.settings.loop ?? true;
    var nextIndex = _currentIndex + 1;
    if (nextIndex >= _items.length) {
      if (!loop) {
        debugPrint('[Player] _next: 到达末尾且未开启循环，退出');
        return;
      }
      nextIndex = 0;
      debugPrint('[Player] _next: 到达末尾，循环到开头, nextIndex=$nextIndex');
    }
    debugPrint('[Player] _next: 准备切换到index=$nextIndex');
    // 先更新索引，触发UI重建，然后再启动新的媒体
    setState(() {
      _currentIndex = nextIndex;
    });
    debugPrint('[Player] _next: setState完成, _currentIndex已更新为=$_currentIndex');
    // 等待一帧，确保AnimatedSwitcher开始动画
    await Future.delayed(const Duration(milliseconds: 50));
    debugPrint('[Player] _next: 延迟完成，开始启动新媒体');
    await _startCurrent();
    // 切换后，预加载新的下一张图片
    _preloadNextImage();
  }

  Future<void> _previous() async {
    debugPrint('[Player] _previous: 开始切换到上一项, 当前index=$_currentIndex, 总数量=${_items.length}');
    if (_items.isEmpty) {
      debugPrint('[Player] _previous: 媒体列表为空，退出');
      return;
    }
    var prevIndex = _currentIndex - 1;
    if (prevIndex < 0) {
      prevIndex = _items.length - 1;
      debugPrint('[Player] _previous: 到达开头，循环到末尾, prevIndex=$prevIndex');
    }
    debugPrint('[Player] _previous: 准备切换到index=$prevIndex');
    // 先更新索引，触发UI重建，然后再启动新的媒体
    setState(() {
      _currentIndex = prevIndex;
    });
    debugPrint('[Player] _previous: setState完成, _currentIndex已更新为=$_currentIndex');
    // 等待一帧，确保AnimatedSwitcher开始动画
    await Future.delayed(const Duration(milliseconds: 50));
    debugPrint('[Player] _previous: 延迟完成，开始启动新媒体');
    await _startCurrent();
    // 切换后，预加载新的上一张图片
    _preloadPreviousImage();
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
        // 优先使用全局设置的切换间隔
        final durationSeconds = item.durationSeconds ??
            _settings?.slideDurationSeconds ??
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
    // 清理预加载缓存
    _preloadedImageCache.clear();
    // 离开播放页时恢复系统 UI 显示和屏幕方向。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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
                        duration: const Duration(milliseconds: 500),
                        switchInCurve: Curves.easeIn,
                        switchOutCurve: Curves.easeOut,
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
      debugPrint('[Player] _buildMediaContent: item为null，返回空容器');
      return Container(
        key: const ValueKey<String>('empty'),
        color: Colors.black,
      );
    }

    // 使用 item.id 和 _currentIndex 组合作为 key，确保每次切换时 key 都不同
    final key = ValueKey<String>('media_${item.id}_$_currentIndex');
    debugPrint('[Player] _buildMediaContent: 构建媒体内容 - id=${item.id}, type=${item.type}, index=$_currentIndex, key=${key.value}');

    if (item.type == MediaType.image) {
      final file = File(item.uri);
      debugPrint('[Player] _buildMediaContent: 构建图片 - path=${item.uri}');
      
      // 优先使用预加载的缓存数据
      final cachedBytes = _preloadedImageCache[item.id];
      
      // 不裁剪整张图片，按比例缩放，最长边铺满屏幕，另一边可能有黑边。
      return Container(
        key: key,
        color: Colors.black,
        alignment: Alignment.center,
        child: _buildImageFromBytes(
          item: item,
          cachedBytes: cachedBytes,
          file: file,
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

  /// 构建图片Widget，优先使用预加载的缓存数据
  Widget _buildImageFromBytes({
    required MediaItem item,
    Uint8List? cachedBytes,
    required File file,
  }) {
    // 如果缓存中有数据，直接使用（同步显示，无延迟）
    if (cachedBytes != null) {
      debugPrint('[Player] _buildImageFromBytes: 使用预加载缓存 - id=${item.id}, size=${cachedBytes.length} bytes');
      return _buildImageWidget(item: item, bytes: cachedBytes);
    }

    // 如果没有缓存，异步读取文件
    debugPrint('[Player] _buildImageFromBytes: 缓存未命中，从文件读取 - id=${item.id}, path=${item.uri}');
    return FutureBuilder<Uint8List?>(
      future: _loadImageBytesForPlayer(file),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }

        if (snapshot.hasError) {
          debugPrint('[Player] _buildImageFromBytes: 读取文件字节失败 - path=${item.uri}, error=${snapshot.error}');
          return Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: const Icon(
              Icons.broken_image,
              color: Colors.white54,
              size: 64,
            ),
          );
        }

        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          debugPrint('[Player] _buildImageFromBytes: 文件字节为空 - path=${item.uri}');
          return Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: const Icon(
              Icons.broken_image,
              color: Colors.white54,
              size: 64,
            ),
          );
        }

        // 读取成功后，缓存起来（下次切换回来时可以直接使用）
        _preloadedImageCache[item.id] = bytes;
        debugPrint('[Player] _buildImageFromBytes: 文件读取成功并缓存 - path=${item.uri}, size=${bytes.length} bytes');
        
        return _buildImageWidget(item: item, bytes: bytes);
      },
    );
  }

  /// 构建图片Widget（从字节数据）
  Widget _buildImageWidget({
    required MediaItem item,
    required Uint8List bytes,
  }) {
    // 检查文件头，判断图片格式
    String? format;
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
        format = 'JPEG';
      } else if (bytes.length >= 8 && 
                 bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
        format = 'PNG';
      } else if (bytes.length >= 6 && 
                 bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
        format = 'GIF';
      } else if (bytes.length >= 12 && 
                 bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
        format = 'WEBP';
      }
    }
    debugPrint('[Player] _buildImageWidget: 检测到的图片格式 - path=${item.uri}, format=$format');
    
    return Image.memory(
      bytes,
      fit: BoxFit.contain,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) {
          debugPrint('[Player] _buildImageWidget: 图片同步加载完成 - path=${item.uri}');
        } else if (frame != null) {
          debugPrint('[Player] _buildImageWidget: 图片异步加载完成 - path=${item.uri}');
        } else {
          debugPrint('[Player] _buildImageWidget: 图片正在加载中 - path=${item.uri}');
        }
        return child;
      },
      errorBuilder: (context, error, stackTrace) {
        debugPrint('[Player] _buildImageWidget: 图片解码失败！ - path=${item.uri}, error=$error');
        debugPrint('[Player] _buildImageWidget: 错误堆栈: $stackTrace');
        return Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: const Icon(
            Icons.broken_image,
            color: Colors.white54,
            size: 64,
          ),
        );
      },
    );
  }

  /// 读取图片文件的字节数据（播放页使用）
  Future<Uint8List?> _loadImageBytesForPlayer(File file) async {
    try {
      if (!await file.exists()) {
        debugPrint('[Player] _loadImageBytesForPlayer: 文件不存在 - ${file.path}');
        return null;
      }

      final bytes = await file.readAsBytes();
      debugPrint('[Player] _loadImageBytesForPlayer: 读取成功 - path=${file.path}, size=${bytes.length} bytes');
      return bytes;
    } catch (e, stackTrace) {
      debugPrint('[Player] _loadImageBytesForPlayer: 读取失败 - path=${file.path}, error=$e');
      debugPrint('[Player] _loadImageBytesForPlayer: 堆栈: $stackTrace');
      return null;
    }
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

/// 设置页面：配置全局播放设置。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  static const routeName = '/settings';

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsRepository _repository = const SettingsRepository();
  final TextEditingController _durationController = TextEditingController();

  AppSettings? _settings;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = await _repository.load();
    setState(() {
      _settings = settings;
      _durationController.text = settings.slideDurationSeconds.toString();
      _isLoading = false;
    });
  }

  Future<void> _saveSettings() async {
    if (_settings == null) return;

    final durationText = _durationController.text.trim();
    final duration = int.tryParse(durationText);
    if (duration == null || duration < 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('切换间隔必须是大于0的整数')),
      );
      return;
    }

    final updated = _settings!.copyWith(
      slideDurationSeconds: duration,
    );
    await _repository.save(updated);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存')),
    );
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _durationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _settings == null
              ? const Center(child: Text('加载设置失败'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // 播放模式设置
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '播放模式',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),
                            RadioListTile<PlaybackOrientation>(
                              title: const Text('竖屏'),
                              value: PlaybackOrientation.portrait,
                              groupValue: _settings!.playbackOrientation,
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() {
                                    _settings = _settings!.copyWith(
                                      playbackOrientation: value,
                                    );
                                  });
                                }
                              },
                            ),
                            RadioListTile<PlaybackOrientation>(
                              title: const Text('横屏'),
                              value: PlaybackOrientation.landscape,
                              groupValue: _settings!.playbackOrientation,
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() {
                                    _settings = _settings!.copyWith(
                                      playbackOrientation: value,
                                    );
                                  });
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 切换间隔设置
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
                            const Text(
                              '切换间隔',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _durationController,
                              decoration: const InputDecoration(
                                labelText: '图片切换间隔（秒）',
                                hintText: '例如：3',
                                border: OutlineInputBorder(),
                                helperText: '设置图片自动切换的时间间隔，单位为秒',
                              ),
                              keyboardType: TextInputType.number,
            ),
          ],
        ),
      ),
                    ),
                    const SizedBox(height: 24),
                    // 保存按钮
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          await _saveSettings();
                        },
                        icon: const Icon(Icons.check),
                        label: const Text('保存设置'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ),
                  ],
      ),
    );
  }
}
