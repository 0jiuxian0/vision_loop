import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'models/app_settings.dart' show AppSettings, PlaybackOrientation, PlaybackMode, PlaybackDurationUnit;
import 'models/playlist_models.dart';
import 'services/playlist_repository.dart';
import 'services/settings_repository.dart';
import 'services/media_file_manager.dart';
import 'services/logger.dart';
import 'services/log_exporter.dart';
import 'utils/id_generator.dart';

// Platform Channel 用于调用原生图片解码器
const MethodChannel _imageDecoderChannel = MethodChannel('com.example.vision_loop/image_decoder');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 初始化日志系统
  final logger = Logger();
  await logger.initialize();
  
  // 捕获 Flutter 框架异常
  FlutterError.onError = (FlutterErrorDetails details) {
    logger.error('Flutter', '未捕获的 Flutter 异常', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  
  // 捕获异步异常
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    logger.error('Platform', '未捕获的平台异常', error, stack);
    return true;
  };
  
  // 初始化文件管理器（在后台进行，不阻塞 UI）
  // initialize() 内部已经会清理孤立文件，所以不需要重复调用
  MediaFileManager().initialize().catchError((error) {
    logger.error('main', '文件管理器初始化失败', error);
    // 即使初始化失败，也继续启动应用
  });
  
  logger.info('main', '应用启动');
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
      initialRoute: MainPage.routeName,
      routes: {
        MainPage.routeName: (_) => const MainPage(),
        PlaylistEditPage.routeName: (_) => const PlaylistEditPage(),
        PlayerPage.routeName: (_) => const PlayerPage(),
      },
    );
  }
}

/// 主页面：包含底部导航栏，切换首页和设置页。
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  static const routeName = '/';

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _currentIndex = 0;
  final GlobalKey<_PlaylistListPageState> _playlistListPageKey = GlobalKey<_PlaylistListPageState>();

  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      PlaylistListPage(key: _playlistListPageKey),
      const SettingsPage(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      persistentFooterButtons: _currentIndex == 0
          ? [
              // 新建幻灯片按钮
              ElevatedButton.icon(
                onPressed: () {
                  _playlistListPageKey.currentState?.openEditor();
                },
                icon: const Icon(Icons.add),
                label: const Text('新建幻灯片'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
              // 清空全部按钮（使用 ValueListenableBuilder 动态更新状态）
              Builder(
                builder: (context) {
                  final state = _playlistListPageKey.currentState;
                  if (state == null) {
                    // 如果状态还未初始化，显示禁用按钮
                    return ElevatedButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.delete_sweep),
                      label: const Text('清空全部'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                    );
                  }
                  return ValueListenableBuilder<int>(
                    valueListenable: state.playlistCountNotifier,
                    builder: (context, count, child) {
                      return ElevatedButton.icon(
                        onPressed: count == 0
                            ? null
                            : () {
                                state.clearAllPlaylists();
                              },
                        icon: const Icon(Icons.delete_sweep),
                        label: const Text('清空全部'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                      );
                    },
                  );
                },
              ),
            ]
          : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: '首页',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
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
  final MediaFileManager _fileManager = MediaFileManager();

  bool _isLoading = true;
  List<Playlist> _playlists = <Playlist>[];
  final ValueNotifier<int> _playlistCountNotifier = ValueNotifier<int>(0);
  ViewMode _viewMode = ViewMode.grid; // 默认网格视图

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  @override
  void dispose() {
    _playlistCountNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylists() async {
    setState(() {
      _isLoading = true;
    });
    final result = await _repository.loadAll();
    // 按 sortOrder 排序
    result.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    setState(() {
      _playlists = result;
      _isLoading = false;
    });
    // 通知列表数量变化
    _playlistCountNotifier.value = _playlists.length;
  }

  Future<void> _openEditor({Playlist? playlist}) async {
    final playlistId = playlist?.id;
    await Navigator.of(context).pushNamed(
      PlaylistEditPage.routeName,
      arguments: playlistId,
    );

    // 无论返回什么值，都刷新列表（因为编辑页会实时保存，包括全面屏手势返回）
    await _loadPlaylists();
  }

  /// 公开方法：打开编辑器（供 MainPage 调用）
  void openEditor() {
    _openEditor();
  }

  /// 公开方法：清空所有播放列表（供 MainPage 调用）
  void clearAllPlaylists() {
    _clearAllPlaylists();
  }

  /// 公开 getter：获取播放列表（供 MainPage 调用）
  List<Playlist> get playlists => _playlists;

  /// 公开 getter：获取播放列表数量通知器（供 MainPage 调用）
  ValueNotifier<int> get playlistCountNotifier => _playlistCountNotifier;

  /// 构建可拖拽排序的播放列表项
  Widget _buildReorderablePlaylistItem(Playlist playlist, int index) {
    return Container(
      key: ValueKey(playlist.id), // 使用 playlist.id 作为唯一 key
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.grey, width: 0.5),
        ),
      ),
      child: ListTile(
        leading: _buildPlaylistThumbnail(playlist),
        title: Text(playlist.name),
        subtitle: Text(
          '共 ${playlist.items.length} 个媒体项',
        ),
        onTap: () => _openEditor(playlist: playlist),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 播放按钮
            IconButton(
              icon: const Icon(Icons.play_arrow),
              onPressed: playlist.items.isEmpty
                  ? null
                  : () {
                      Navigator.of(context).pushNamed(
                        PlayerPage.routeName,
                        arguments: playlist.id,
                      );
                    },
              tooltip: '播放',
            ),
            const SizedBox(width: 4),
            // 拖拽手柄图标
            const Icon(Icons.drag_handle, color: Colors.grey),
            const SizedBox(width: 8),
            // 删除按钮
            IconButton(
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
                  // 获取播放列表中所有媒体文件的路径
                  final filePaths = playlist.items.map((item) => item.uri).toList();
                  
                  // 删除播放列表
                  await _repository.deleteById(playlist.id);
                  
                  // 减少所有文件的引用计数
                  try {
                    await _fileManager.decrementRefCounts(filePaths);
                    debugPrint('[PlaylistListPage] 已减少播放列表文件的引用计数 - playlistId=${playlist.id}');
                  } catch (e) {
                    debugPrint('[PlaylistListPage] 减少引用计数失败 - playlistId=${playlist.id}, error=$e');
                  }
                  
                  // 删除后需要重新分配 sortOrder
                  final all = await _repository.loadAll();
                  final updated = <Playlist>[];
                  for (var i = 0; i < all.length; i++) {
                    updated.add(all[i].copyWith(sortOrder: i));
                  }
                  await _repository.saveAll(updated);
                  // 刷新列表（会自动更新 _playlistCountNotifier）
                  await _loadPlaylists();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 清空所有播放列表
  Future<void> _clearAllPlaylists() async {
    if (_playlists.isEmpty) {
      // 如果列表已经为空，不需要显示确认对话框
      return;
    }

    // 显示确认对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清空'),
        content: Text('确定要清空所有 ${_playlists.length} 个播放列表吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // 收集所有播放列表中的文件路径
      final allFilePaths = <String>[];
      for (final playlist in _playlists) {
        allFilePaths.addAll(playlist.items.map((item) => item.uri));
      }
      
      // 删除所有播放列表
      for (final playlist in _playlists) {
        await _repository.deleteById(playlist.id);
      }
      
      // 减少所有文件的引用计数
      try {
        await _fileManager.decrementRefCounts(allFilePaths);
        debugPrint('[PlaylistListPage] _clearAllPlaylists: 已减少所有文件的引用计数');
      } catch (e) {
        debugPrint('[PlaylistListPage] _clearAllPlaylists: 减少引用计数失败 - error=$e');
      }
      
      // 刷新列表（会自动更新 _playlistCountNotifier）
      await _loadPlaylists();
      debugPrint('[PlaylistListPage] _clearAllPlaylists: 已清空所有播放列表');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vision Loop 播放列表'),
        actions: [
          // 视图切换按钮
          IconButton(
            icon: Icon(_viewMode == ViewMode.list ? Icons.grid_view : Icons.view_list),
            onPressed: () {
              setState(() {
                _viewMode = _viewMode == ViewMode.list ? ViewMode.grid : ViewMode.list;
              });
            },
            tooltip: _viewMode == ViewMode.list ? '切换到网格视图' : '切换到列表视图',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _playlists.isEmpty
              ? const Center(
                  child: Text('暂无幻灯片项目，点击左下角按钮新建一个吧。'),
                )
              : _viewMode == ViewMode.list
                  ? ReorderableListView(
                      padding: const EdgeInsets.only(bottom: 80), // 底部 padding，为底部工具栏留出空间
                      onReorder: (oldIndex, newIndex) async {
                        // 如果新位置在旧位置之后，需要调整索引（因为移除旧项后，后面的项会前移）
                        if (newIndex > oldIndex) {
                          newIndex -= 1;
                        }
                        
                        // 移动项目
                        final playlist = _playlists.removeAt(oldIndex);
                        _playlists.insert(newIndex, playlist);
                        
                        // 重新分配 sortOrder（从 0 开始）
                        final updatedPlaylists = <Playlist>[];
                        for (var i = 0; i < _playlists.length; i++) {
                          updatedPlaylists.add(_playlists[i].copyWith(sortOrder: i));
                        }
                        
                        // 保存所有播放列表
                        await _repository.saveAll(updatedPlaylists);
                        
                        // 刷新列表
                        await _loadPlaylists();
                        debugPrint('[PlaylistListPage] ListView onReorder: 从位置 $oldIndex 移动到 $newIndex');
                      },
                      children: [
                        for (var index = 0; index < _playlists.length; index++)
                          _buildReorderablePlaylistItem(_playlists[index], index),
                      ],
                    )
                  : _buildPlaylistGridView(      ),
    );
  }

  /// 构建播放列表网格视图（支持拖拽排序）
  Widget _buildPlaylistGridView() {
    return ReorderableGridView.count(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 80), // 底部 padding，为底部工具栏留出空间
      crossAxisCount: 2, // 2列
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 0.75, // 宽高比，可以根据需要调整
      children: [
        for (var index = 0; index < _playlists.length; index++)
          _buildPlaylistGridItem(_playlists[index], index),
      ],
      onReorder: (oldIndex, newIndex) async {
        // 如果新位置在旧位置之后，需要调整索引（因为移除旧项后，后面的项会前移）
        if (newIndex > oldIndex) {
          newIndex -= 1;
        }
        
        // 移动项目
        final playlist = _playlists.removeAt(oldIndex);
        _playlists.insert(newIndex, playlist);
        
        // 重新分配 sortOrder（从 0 开始）
        final updatedPlaylists = <Playlist>[];
        for (var i = 0; i < _playlists.length; i++) {
          updatedPlaylists.add(_playlists[i].copyWith(sortOrder: i));
        }
        
        // 保存所有播放列表
        await _repository.saveAll(updatedPlaylists);
        
        // 刷新列表
        await _loadPlaylists();
        debugPrint('[PlaylistListPage] GridView onReorder: 从位置 $oldIndex 移动到 $newIndex');
      },
    );
  }

  /// 构建播放列表网格项
  Widget _buildPlaylistGridItem(Playlist playlist, int index) {
    return Card(
      key: ValueKey(playlist.id), // 使用 playlist.id 作为唯一 key，用于拖拽排序
      elevation: 2,
      child: InkWell(
        onTap: () => _openEditor(playlist: playlist),
        borderRadius: BorderRadius.circular(4),
        child: Stack(
        children: [
          // 主要内容区域
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 预览图（占主要空间）
              Expanded(
                flex: 3,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  child: _buildPlaylistThumbnailForGrid(playlist),
                ),
              ),
              // 操作按钮区域（预览图和信息区域之间）
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  border: Border(
                    top: BorderSide(color: Colors.grey.shade300, width: 0.5),
                    bottom: BorderSide(color: Colors.grey.shade300, width: 0.5),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // 播放按钮
                    Expanded(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: playlist.items.isEmpty
                              ? null
                              : () {
                                  Navigator.of(context).pushNamed(
                                    PlayerPage.routeName,
                                    arguments: playlist.id,
                                  );
                                },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: const Icon(
                              Icons.play_arrow,
                              size: 18,
                              color: Colors.blue,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 分隔线
                    Container(
                      width: 0.5,
                      color: Colors.grey.shade300,
                    ),
                    // 删除按钮
                    Expanded(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (context) {
                                return AlertDialog(
                                  title: const Text('删除幻灯片'),
                                  content: Text('确定要删除 "${playlist.name}" 吗？'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(context).pop(false),
                                      child: const Text('取消'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.of(context).pop(true),
                                      child: const Text('删除'),
                                    ),
                                  ],
                                );
                              },
                            );

                            if (confirm == true) {
                              // 获取播放列表中所有媒体文件的路径
                              final filePaths = playlist.items.map((item) => item.uri).toList();
                              
                              // 删除播放列表
                              await _repository.deleteById(playlist.id);
                              
                              // 减少所有文件的引用计数
                              try {
                                await _fileManager.decrementRefCounts(filePaths);
                                debugPrint('[PlaylistListPage] 已减少播放列表文件的引用计数 - playlistId=${playlist.id}');
                              } catch (e) {
                                debugPrint('[PlaylistListPage] 减少引用计数失败 - playlistId=${playlist.id}, error=$e');
                              }
                              
                              // 删除后需要重新分配 sortOrder
                              final all = await _repository.loadAll();
                              final updated = <Playlist>[];
                              for (var i = 0; i < all.length; i++) {
                                updated.add(all[i].copyWith(sortOrder: i));
                              }
                              await _repository.saveAll(updated);
                              // 刷新列表（会自动更新 _playlistCountNotifier）
                              await _loadPlaylists();
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: const Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: Colors.red,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 底部信息区域
              Expanded(
                flex: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
          children: [
                      // 播放列表名称（截断显示）
            Text(
                        playlist.name,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      // 媒体数量
                      Text(
                        '共 ${playlist.items.length} 个媒体项',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey[600],
                        ),
            ),
          ],
        ),
      ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }

  /// 构建播放列表网格视图的预览图（更大的尺寸）
  Widget _buildPlaylistThumbnailForGrid(Playlist playlist) {
    // 如果没有媒体项，显示默认图标
    if (playlist.items.isEmpty) {
      return Container(
        color: Colors.grey.shade300,
        child: const Center(
          child: Icon(Icons.image, color: Colors.grey, size: 48),
        ),
      );
    }

    // 获取第一个媒体项
    final firstItem = playlist.items.first;
    
    if (firstItem.type == MediaType.image) {
      return _buildImageThumbnailForGrid(firstItem.uri);
    } else {
      return _buildVideoThumbnailForGrid(firstItem.uri);
    }
  }

  /// 构建图片缩略图（网格视图，更大的尺寸）
  Widget _buildImageThumbnailForGrid(String imagePath) {
    final file = File(imagePath);
    return FutureBuilder<Uint8List?>(
      future: _loadImageBytesForList(file),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            color: Colors.grey.shade800,
            child: const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
          );
        }

        if (snapshot.hasError || snapshot.data == null || snapshot.data!.isEmpty) {
          // 尝试使用原生解码器
          return FutureBuilder<Uint8List?>(
            future: _decodeImageWithNativeForList(imagePath),
            builder: (context, nativeSnapshot) {
              if (nativeSnapshot.connectionState == ConnectionState.waiting) {
                return Container(
                  color: Colors.grey.shade800,
                  child: const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                );
              }

              if (nativeSnapshot.hasData && nativeSnapshot.data != null) {
                return Image.memory(
                  nativeSnapshot.data!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) {
                    return Container(
                      color: Colors.grey.shade300,
                      child: const Icon(Icons.broken_image, color: Colors.grey),
                    );
                  },
                );
              }

              return Container(
                color: Colors.grey.shade300,
                child: const Icon(Icons.broken_image, color: Colors.grey),
              );
            },
          );
        }

        return Image.memory(
          snapshot.data!,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            // Flutter解码失败，尝试原生解码器
            return FutureBuilder<Uint8List?>(
              future: _decodeImageWithNativeForList(imagePath),
              builder: (context, nativeSnapshot) {
                if (nativeSnapshot.connectionState == ConnectionState.waiting) {
                  return Container(
                    color: Colors.grey.shade800,
                    child: const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  );
                }

                if (nativeSnapshot.hasData && nativeSnapshot.data != null) {
                  return Image.memory(
                    nativeSnapshot.data!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) {
                      return Container(
                        color: Colors.grey.shade300,
                        child: const Icon(Icons.broken_image, color: Colors.grey),
                      );
                    },
                  );
                }

                return Container(
                  color: Colors.grey.shade300,
                  child: const Icon(Icons.broken_image, color: Colors.grey),
                );
              },
            );
          },
        );
      },
    );
  }

  /// 构建视频缩略图（网格视图，更大的尺寸）
  Widget _buildVideoThumbnailForGrid(String videoPath) {
    return FutureBuilder<String?>(
      future: _generateVideoThumbnailForList(videoPath),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            color: Colors.grey.shade800,
            child: const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
          );
        }

        if (snapshot.hasData && snapshot.data != null) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(snapshot.data!),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) {
                  return Container(
                    color: Colors.grey.shade800,
                    child: const Icon(Icons.videocam, color: Colors.white),
                  );
                },
              ),
              // 视频图标叠加层
              Positioned(
                bottom: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(
                    Icons.play_circle_filled,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          );
        }

        return Container(
          color: Colors.grey.shade800,
          child: const Icon(Icons.videocam, color: Colors.white),
        );
      },
    );
  }

  /// 构建播放列表的预览图（使用第一个媒体项）
  Widget _buildPlaylistThumbnail(Playlist playlist) {
    // 如果没有媒体项，显示默认图标
    if (playlist.items.isEmpty) {
      return Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Colors.grey.shade300,
        ),
        child: const Icon(Icons.image, color: Colors.grey),
      );
    }

    // 获取第一个媒体项
    final firstItem = playlist.items.first;
    
    if (firstItem.type == MediaType.image) {
      return _buildImageThumbnail(firstItem.uri);
    } else {
      return _buildVideoThumbnail(firstItem.uri);
    }
  }

  /// 构建图片缩略图
  Widget _buildImageThumbnail(String imagePath) {
    final file = File(imagePath);
    return FutureBuilder<Uint8List?>(
      future: _loadImageBytesForList(file),
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

        if (snapshot.hasError || snapshot.data == null || snapshot.data!.isEmpty) {
          // 尝试使用原生解码器
          return FutureBuilder<Uint8List?>(
            future: _decodeImageWithNativeForList(imagePath),
            builder: (context, nativeSnapshot) {
              if (nativeSnapshot.connectionState == ConnectionState.waiting) {
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

              if (nativeSnapshot.hasData && nativeSnapshot.data != null) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    nativeSnapshot.data!,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) {
                      return Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.grey.shade300,
                        ),
                        child: const Icon(Icons.broken_image, color: Colors.grey),
                      );
                    },
                  ),
                );
              }

              return Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey.shade300,
                ),
                child: const Icon(Icons.broken_image, color: Colors.grey),
              );
            },
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            snapshot.data!,
            width: 56,
            height: 56,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              // Flutter解码失败，尝试原生解码器
              return FutureBuilder<Uint8List?>(
                future: _decodeImageWithNativeForList(imagePath),
                builder: (context, nativeSnapshot) {
                  if (nativeSnapshot.connectionState == ConnectionState.waiting) {
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

                  if (nativeSnapshot.hasData && nativeSnapshot.data != null) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        nativeSnapshot.data!,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) {
                          return Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.grey.shade300,
                            ),
                            child: const Icon(Icons.broken_image, color: Colors.grey),
                          );
                        },
                      ),
                    );
                  }

                  return Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.grey.shade300,
                    ),
                    child: const Icon(Icons.broken_image, color: Colors.grey),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  /// 构建视频缩略图
  Widget _buildVideoThumbnail(String videoPath) {
    return FutureBuilder<String?>(
      future: _generateVideoThumbnailForList(videoPath),
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

        if (snapshot.hasData && snapshot.data != null) {
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(snapshot.data!),
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) {
                    return Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.grey.shade800,
                      ),
                      child: const Icon(Icons.videocam, color: Colors.white),
                    );
                  },
                ),
              ),
              // 视频图标叠加层
              Positioned(
                bottom: 2,
                right: 2,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
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
          );
        }

        return Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: Colors.grey.shade800,
          ),
          child: const Icon(Icons.videocam, color: Colors.white),
        );
      },
    );
  }

  /// 读取图片文件的字节数据（列表页使用）
  Future<Uint8List?> _loadImageBytesForList(File file) async {
    try {
      if (!await file.exists()) {
        return null;
      }
      return await file.readAsBytes();
    } catch (e) {
      return null;
    }
  }

  /// 使用原生解码器解码图片（列表页使用）
  Future<Uint8List?> _decodeImageWithNativeForList(String imagePath) async {
    try {
      final result = await _imageDecoderChannel.invokeMethod<Uint8List>('decodeImage', {
        'path': imagePath,
      });
      return result;
    } catch (e) {
      return null;
    }
  }

  /// 生成视频缩略图（列表页使用）
  Future<String?> _generateVideoThumbnailForList(String videoPath) async {
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
}

/// 视图模式枚举
enum ViewMode {
  list,  // 列表视图
  grid,  // 网格视图
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
  final MediaFileManager _fileManager = MediaFileManager();

  Playlist? _playlist;
  List<MediaItem> _items = <MediaItem>[];
  bool _isLoading = true;
  ViewMode _viewMode = ViewMode.grid; // 默认网格视图

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
      // 获取所有播放列表，计算新的 sortOrder
      final playlistRepo = const PlaylistRepository();
      final allPlaylists = await playlistRepo.loadAll();
      final maxSortOrder = allPlaylists.isEmpty 
          ? -1 
          : allPlaylists.map((p) => p.sortOrder).reduce((a, b) => a > b ? a : b);
      
      final playlist = Playlist(
        id: generateId('pl'),
        name: '',
        createdAt: now,
        updatedAt: now,
        items: <MediaItem>[],
        sortOrder: maxSortOrder + 1, // 新项放在最后
      );
    setState(() {
      _playlist = playlist;
      _nameController.text = '';
      _isLoading = false;
    });
    // 监听名称变化，实时保存
    _nameController.addListener(_onNameChanged);
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
    // 监听名称变化，实时保存
    _nameController.addListener(_onNameChanged);
  }

  void _onNameChanged() {
    // 延迟保存，避免频繁保存
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _autoSave();
      }
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
    int skippedCount = 0;
    
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final originalPath = file.path;
      debugPrint('[EditPage] _addImages: 处理图片 $i - path=$originalPath');
      
      try {
        // 提取原始文件名
        final originalFileName = _fileName(originalPath);
        
        // 使用文件管理器添加文件（去重）
        final managedPath = await _fileManager.addFile(originalPath);
        debugPrint('[EditPage] _addImages: 图片 $i 已添加到文件管理器 - managedPath=$managedPath, originalFileName=$originalFileName');
        
        // 检查当前幻灯片中是否已存在该文件
        final alreadyExists = _items.any((item) => item.uri == managedPath);
        if (alreadyExists) {
          debugPrint('[EditPage] _addImages: 图片 $i 已存在于当前幻灯片中，跳过 - path=$managedPath');
          skippedCount++;
          continue;
        }
        
        newItems.add(
          MediaItem(
            id: generateId('mi'),
            type: MediaType.image,
            uri: managedPath,
            orderIndex: startIndex + newItems.length,
            originalFileName: originalFileName,
          ),
        );
      } catch (e) {
        debugPrint('[EditPage] _addImages: 图片 $i 处理失败 - error=$e');
        continue;
      }
    }
    
    if (skippedCount > 0) {
      debugPrint('[EditPage] _addImages: 跳过了 $skippedCount 个重复文件');
    }

    debugPrint('[EditPage] _addImages: 添加了${newItems.length}个媒体项到列表');
    
    if (newItems.isEmpty) {
      // 如果没有添加任何新项，显示提示信息
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(skippedCount > 0 
              ? '所有图片都已存在于当前幻灯片中' 
              : '未添加任何图片'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    
    setState(() {
      _items.addAll(newItems);
      _playlist = _playlist?.copyWith(items: _items);
    });
    
    // 如果有跳过的文件，显示提示信息
    if (skippedCount > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已添加 ${newItems.length} 个图片，跳过了 $skippedCount 个重复文件'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    
    // 实时保存
    _autoSave();
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

    final originalPath = file.path;
    debugPrint('[EditPage] _addVideo: 处理视频 - path=$originalPath');
    
    try {
      // 提取原始文件名
      final originalFileName = _fileName(originalPath);
      
      // 使用文件管理器添加文件（去重）
      final managedPath = await _fileManager.addFile(originalPath);
      debugPrint('[EditPage] _addVideo: 视频已添加到文件管理器 - managedPath=$managedPath, originalFileName=$originalFileName');
      
      // 检查当前幻灯片中是否已存在该文件
      final alreadyExists = _items.any((item) => item.uri == managedPath);
      if (alreadyExists) {
        debugPrint('[EditPage] _addVideo: 视频已存在于当前幻灯片中，跳过 - path=$managedPath');
        // 显示提示信息
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('该视频已存在于当前幻灯片中'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }
      
      final newItem = MediaItem(
        id: generateId('mi'),
        type: MediaType.video,
        uri: managedPath,
        orderIndex: _items.length,
        originalFileName: originalFileName,
      );

      setState(() {
        _items.add(newItem);
        _playlist = _playlist?.copyWith(items: _items);
      });
      // 实时保存
      _autoSave();
    } catch (e) {
      debugPrint('[EditPage] _addVideo: 视频处理失败 - error=$e');
    }
  }

  void _removeItem(int index) async {
    // 获取要删除的文件路径
    final removedItem = _items[index];
    final filePath = removedItem.uri;
    
    setState(() {
      _items.removeAt(index);
      // 重新整理顺序索引。
      for (var i = 0; i < _items.length; i++) {
        _items[i] = _items[i].copyWith(orderIndex: i);
      }
      _playlist = _playlist?.copyWith(items: _items);
    });
    
    // 减少文件引用计数
    try {
      await _fileManager.decrementRefCount(filePath);
      debugPrint('[EditPage] _removeItem: 已减少文件引用计数 - path=$filePath');
    } catch (e) {
      debugPrint('[EditPage] _removeItem: 减少引用计数失败 - path=$filePath, error=$e');
    }
    
    // 实时保存
    _autoSave();
  }

  /// 通过 ID 删除媒体项
  void _removeItemById(String itemId) {
    final index = _items.indexWhere((item) => item.id == itemId);
    if (index != -1) {
      _removeItem(index);
    }
  }

  /// 构建可拖拽排序的列表项
  Widget _buildReorderableItem(MediaItem item, int index) {
    return Container(
      key: ValueKey(item.id), // 使用 item.id 作为唯一 key
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.grey, width: 0.5),
        ),
      ),
      child: ListTile(
        leading: _buildMediaThumbnail(item),
        title: Text(_getDisplayFileName(item)),
        subtitle: Text(
          item.type == MediaType.image ? '图片' : '视频',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽手柄图标
            const Icon(Icons.drag_handle, color: Colors.grey),
            const SizedBox(width: 8),
            // 删除按钮
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => _removeItemById(item.id),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建网格视图（支持拖拽排序）
  Widget _buildGridView() {
    return ReorderableGridView.count(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 80), // 底部 padding，为底部工具栏留出空间
      crossAxisCount: 2, // 2列
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 0.75, // 宽高比，可以根据需要调整
      children: [
        for (var index = 0; index < _items.length; index++)
          _buildGridItem(_items[index], index),
      ],
      onReorder: (oldIndex, newIndex) {
        // 如果新位置在旧位置之后，需要调整索引（因为移除旧项后，后面的项会前移）
        if (newIndex > oldIndex) {
          newIndex -= 1;
        }
        
        setState(() {
          // 移动项目
          final item = _items.removeAt(oldIndex);
          _items.insert(newIndex, item);
          
          // 重新整理顺序索引
          for (var i = 0; i < _items.length; i++) {
            _items[i] = _items[i].copyWith(orderIndex: i);
          }
          _playlist = _playlist?.copyWith(items: _items);
        });
        
        // 实时保存
        _autoSave();
        debugPrint('[EditPage] GridView onReorder: 从位置 $oldIndex 移动到 $newIndex');
      },
    );
  }

  /// 构建网格项
  Widget _buildGridItem(MediaItem item, int index) {
    return Card(
      key: ValueKey(item.id), // 使用 item.id 作为唯一 key，用于拖拽排序
      elevation: 2,
      child: Stack(
        children: [
          // 主要内容区域
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 预览图（占主要空间）
              Expanded(
                flex: 3,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  child: _buildMediaThumbnailForGrid(item),
                ),
              ),
              // 操作按钮区域（预览图和信息区域之间）
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  border: Border(
                    top: BorderSide(color: Colors.grey.shade300, width: 0.5),
                    bottom: BorderSide(color: Colors.grey.shade300, width: 0.5),
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _removeItemById(item.id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: const Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: Colors.red,
                      ),
                    ),
                  ),
                ),
              ),
              // 底部信息区域
              Expanded(
                flex: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 文件名（截断显示）
                      Text(
                        _getDisplayFileName(item),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      // 类型标签
                      Text(
                        item.type == MediaType.image ? '图片' : '视频',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 构建网格视图的缩略图（更大的尺寸）
  Widget _buildMediaThumbnailForGrid(MediaItem item) {
    if (item.type == MediaType.image) {
      final file = File(item.uri);
      return FutureBuilder<Uint8List?>(
        future: _loadImageBytes(file),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Container(
              color: Colors.grey.shade800,
              child: const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            );
          }

          if (snapshot.hasError) {
            return Container(
              color: Colors.grey.shade800,
              child: const Icon(Icons.broken_image, color: Colors.white),
            );
          }

          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            return Container(
              color: Colors.grey.shade800,
              child: const Icon(Icons.broken_image, color: Colors.white),
            );
          }

          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              // Flutter解码失败，尝试原生解码器
              return FutureBuilder<Uint8List?>(
                future: _decodeImageWithNativeForEdit(item.uri),
                builder: (context, nativeSnapshot) {
                  if (nativeSnapshot.connectionState == ConnectionState.waiting) {
                    return Container(
                      color: Colors.grey.shade800,
                      child: const Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    );
                  }

                  if (nativeSnapshot.hasData && nativeSnapshot.data != null) {
                    return Image.memory(
                      nativeSnapshot.data!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) {
                        return Container(
                          color: Colors.grey.shade800,
                          child: const Icon(Icons.broken_image, color: Colors.white),
                        );
                      },
                    );
                  }

                  return Container(
                    color: Colors.grey.shade800,
                    child: const Icon(Icons.broken_image, color: Colors.white),
                  );
                },
              );
            },
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
            color: Colors.grey.shade800,
            child: const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
          );
        }

        if (snapshot.hasData && snapshot.data != null) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(snapshot.data!),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) {
                  return Container(
                    color: Colors.grey.shade800,
                    child: const Icon(Icons.videocam, color: Colors.white),
                  );
                },
              ),
              // 视频图标叠加层
              Positioned(
                bottom: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(
                    Icons.play_circle_filled,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          );
        }

        return Container(
          color: Colors.grey.shade800,
          child: const Icon(Icons.videocam, color: Colors.white),
        );
      },
    );
  }

  /// 清空所有媒体项
  Future<void> _clearAllItems() async {
    if (_items.isEmpty) {
      // 如果列表已经为空，不需要显示确认对话框
      return;
    }

    // 显示确认对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清空'),
        content: Text('确定要清空所有 ${_items.length} 个媒体项吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // 获取所有要删除的文件路径
      final filePaths = _items.map((item) => item.uri).toList();
      
      setState(() {
        _items.clear();
        _playlist = _playlist?.copyWith(items: _items);
      });
      
      // 减少所有文件的引用计数
      try {
        await _fileManager.decrementRefCounts(filePaths);
        debugPrint('[EditPage] _clearAllItems: 已减少所有文件的引用计数');
      } catch (e) {
        debugPrint('[EditPage] _clearAllItems: 减少引用计数失败 - error=$e');
      }
      
      // 实时保存
      _autoSave();
      debugPrint('[EditPage] _clearAllItems: 已清空所有媒体项');
    }
  }

  /// 使用原生Android解码器解码图片（编辑页使用）
  Future<Uint8List?> _decodeImageWithNativeForEdit(String imagePath) async {
    try {
      debugPrint('[EditPage] _decodeImageWithNativeForEdit: 尝试使用原生解码器 - path=$imagePath');
      final result = await _imageDecoderChannel.invokeMethod<Uint8List>('decodeImage', {
        'path': imagePath,
      });
      if (result != null) {
        debugPrint('[EditPage] _decodeImageWithNativeForEdit: 原生解码成功 - path=$imagePath, size=${result.length} bytes');
        return result;
      } else {
        debugPrint('[EditPage] _decodeImageWithNativeForEdit: 原生解码返回null - path=$imagePath');
        return null;
      }
    } on PlatformException catch (e) {
      debugPrint('[EditPage] _decodeImageWithNativeForEdit: 原生解码失败 - path=$imagePath, error=${e.code}: ${e.message}');
      return null;
    } catch (e, stackTrace) {
      debugPrint('[EditPage] _decodeImageWithNativeForEdit: 原生解码异常 - path=$imagePath, error=$e');
      debugPrint('[EditPage] _decodeImageWithNativeForEdit: 堆栈: $stackTrace');
      return null;
    }
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

  /// 获取媒体项的显示名称（优先使用原始文件名）
  String _getDisplayFileName(MediaItem item) {
    // 优先使用原始文件名，如果没有则从路径中提取
    return item.originalFileName ?? _fileName(item.uri);
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
                debugPrint('[EditPage] _buildMediaThumbnail: Flutter解码失败！尝试原生解码器 - path=${item.uri}, error=$error');
                
                // Flutter解码失败，尝试原生解码器
                return FutureBuilder<Uint8List?>(
                  future: _decodeImageWithNativeForEdit(item.uri),
                  builder: (context, nativeSnapshot) {
                    if (nativeSnapshot.connectionState == ConnectionState.waiting) {
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
                    
                    if (nativeSnapshot.hasData && nativeSnapshot.data != null) {
                      debugPrint('[EditPage] _buildMediaThumbnail: 原生解码器成功 - path=${item.uri}');
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          nativeSnapshot.data!,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            debugPrint('[EditPage] _buildMediaThumbnail: 原生解码器结果也无法显示 - path=${item.uri}');
                            return const Icon(Icons.broken_image);
                          },
                        ),
                      );
                    }
                    
                    // 原生解码器也失败
                    debugPrint('[EditPage] _buildMediaThumbnail: 原生解码器也失败 - path=${item.uri}');
                    return const Icon(Icons.broken_image);
                  },
                );
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

  /// 格式化日期时间为字符串 yyyy-MM-dd HH:mm:ss
  String _formatDateTime(DateTime dateTime) {
    final year = dateTime.year.toString();
    final month = dateTime.month.toString().padLeft(2, '0');
    final day = dateTime.day.toString().padLeft(2, '0');
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final second = dateTime.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute:$second';
  }

  /// 实时保存播放列表
  Future<void> _autoSave() async {
    final current = _playlist;
    if (current == null) return;

    final nameText = _nameController.text.trim();
    final name = nameText.isEmpty ? _formatDateTime(DateTime.now()) : nameText;

    final updated = current.copyWith(
      name: name,
      updatedAt: DateTime.now(),
      items: _items,
    );

    await _repository.upsert(updated);
    debugPrint('[EditPage] _autoSave: 自动保存完成 - id=${updated.id}, name=${updated.name}');
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// 处理返回操作，确保返回时刷新首页列表
  Future<bool> _onWillPop() async {
    // 离开前保存一次
    await _autoSave();
    // 返回 true 表示允许返回，并且会触发首页刷新
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('编辑幻灯片'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              // 离开前保存一次
              await _autoSave();
              if (mounted) {
                Navigator.of(context).pop(true);
              }
            },
          ),
          actions: [
            // 视图切换按钮
            IconButton(
              icon: Icon(_viewMode == ViewMode.list ? Icons.grid_view : Icons.view_list),
              onPressed: () {
                setState(() {
                  _viewMode = _viewMode == ViewMode.list ? ViewMode.grid : ViewMode.list;
                });
              },
              tooltip: _viewMode == ViewMode.list ? '切换到网格视图' : '切换到列表视图',
            ),
          ],
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
                      : _viewMode == ViewMode.list
                          ? ReorderableListView(
                              padding: const EdgeInsets.only(bottom: 80), // 底部 padding，为底部工具栏留出空间
                              onReorder: (oldIndex, newIndex) {
                                // 如果新位置在旧位置之后，需要调整索引（因为移除旧项后，后面的项会前移）
                                if (newIndex > oldIndex) {
                                  newIndex -= 1;
                                }
                                
                                setState(() {
                                  // 移动项目
                                  final item = _items.removeAt(oldIndex);
                                  _items.insert(newIndex, item);
                                  
                                  // 重新整理顺序索引
                                  for (var i = 0; i < _items.length; i++) {
                                    _items[i] = _items[i].copyWith(orderIndex: i);
                                  }
                                  _playlist = _playlist?.copyWith(items: _items);
                                });
                                
                                // 实时保存
                                _autoSave();
                                debugPrint('[EditPage] onReorder: 从位置 $oldIndex 移动到 $newIndex');
                              },
                              children: [
                                for (var index = 0; index < _items.length; index++)
                                  _buildReorderableItem(_items[index], index),
                              ],
                            )
                          : _buildGridView(),
                ),
              ],
            ),
      bottomNavigationBar: BottomAppBar(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // 播放按钮
            IconButton(
              icon: const Icon(Icons.play_arrow),
              onPressed: _isLoading || _playlist == null || _items.isEmpty
                  ? null
                  : () {
                      Navigator.of(context).pushNamed(
                        PlayerPage.routeName,
                        arguments: _playlist!.id,
                      );
                    },
              tooltip: '播放',
            ),
            // 添加图片按钮
            IconButton(
              icon: const Icon(Icons.photo),
              onPressed: _addImages,
              tooltip: '添加图片',
            ),
            // 添加视频按钮
            IconButton(
              icon: const Icon(Icons.videocam),
              onPressed: _addVideo,
              tooltip: '添加视频',
            ),
            // 清空全部按钮
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: _items.isEmpty ? null : _clearAllItems,
              color: Colors.red,
              tooltip: '清空全部',
            ),
          ],
        ),
      ),
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
  final Logger _logger = Logger();

  Playlist? _playlist;
  AppSettings? _settings;
  int _currentIndex = 0;
  bool _isPlaying = true;
  bool _isLoading = true;
  bool _showControls = false;

  VideoPlayerController? _videoController;
  Timer? _imageTimer;
  Timer? _playbackDurationTimer; // 播放时长限制定时器
  
  // 预加载缓存：存储图片的字节数据，key为MediaItem的id
  final Map<String, Uint8List> _preloadedImageCache = {};
  
  // 随机播放模式：已播放的索引列表（用于避免重复）
  final List<int> _randomPlayedIndices = [];

  @override
  void initState() {
    super.initState();
    // 进入播放页时开启沉浸式全屏（隐藏状态栏等）。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // 启用 wakelock 防止锁屏
    WakelockPlus.enable();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initFromArguments();
    });
  }

  Future<void> _initFromArguments() async {
    final args = ModalRoute.of(context)?.settings.arguments;
    final String? playlistId = args is String ? args : null;
    if (playlistId == null) {
      _logger.warning('Playback', '播放页面初始化失败：未提供播放列表ID');
      _logger.info('UI', 'setState调用 - 原因=播放页面初始化失败');
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
    
    _logger.info('Playback', '播放开始 - playlistId=$playlistId, itemCount=${playlist.items.length}, mode=${settings.playbackMode}, loop=${playlist.settings.loop}');
    
    // 重置随机播放历史
    _randomPlayedIndices.clear();

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

    // 启动播放时长限制定时器
    _startPlaybackDurationTimer();

    if (playlist.items.isNotEmpty) {
      // 预加载当前图片（第一张）
      final currentItem = playlist.items[0];
      if (currentItem.type == MediaType.image) {
        await _preloadImageAtIndex(0);
      }
      await _startCurrent();
    }
  }

  /// 启动播放时长限制定时器
  void _startPlaybackDurationTimer() {
    // 取消之前的定时器
    _playbackDurationTimer?.cancel();
    
    if (_settings == null) {
      return;
    }
    
    final maxDuration = _settings!.maxPlaybackDuration;
    if (maxDuration == null) {
      // 不限制播放时长
      debugPrint('[Player] 播放时长限制：不限制');
      return;
    }
    
    debugPrint('[Player] 播放时长限制：${maxDuration.inSeconds} 秒');
    
    // 启动定时器
    _playbackDurationTimer = Timer(maxDuration, () {
      debugPrint('[Player] 播放时长已到，退出播放页面');
      // 禁用 wakelock
      WakelockPlus.disable();
      // 退出播放页面
      if (mounted) {
        Navigator.of(context).pop();
      }
    });
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
      final fileSize = exists ? await file.length() : 0;
      _logger.info('Image', '切换到图片 - index=$_currentIndex, path=${item.uri}, exists=$exists, size=$fileSize bytes');
      
      if (!exists) {
        _logger.error('Image', '图片文件不存在', null);
        return;
      }

      _logger.info('Image', '开始加载图片 - path=${item.uri}');

      // 优先使用全局设置的切换间隔
      final durationSeconds = item.durationSeconds ??
          _settings?.slideDurationSeconds ??
          _playlist?.settings.slideDurationSeconds ??
          3;
      _logger.info('Image', '图片切换间隔=${durationSeconds}秒');
      
      if (_isPlaying) {
        _imageTimer = Timer(Duration(seconds: durationSeconds), () {
          _logger.info('Image', '图片定时器触发，准备切换到下一张 - index=$_currentIndex');
          _next();
        });
      }
      if (mounted) {
        _logger.info('UI', 'setState调用 - 原因=图片显示, currentIndex=$_currentIndex');
        setState(() {});
      }
      
      // 启动当前媒体后，后台预加载下一张和上一张图片（双向预加载）
      _preloadNextImage();
      _preloadPreviousImage();
    } else {
      final file = File(item.uri);
      final exists = await file.exists();
      final fileSize = exists ? await file.length() : 0;
      _logger.info('Video', '视频文件检查 - path=${item.uri}, exists=$exists, size=$fileSize bytes');
      
      if (!exists) {
        _logger.error('Video', '视频文件不存在', null);
        return;
      }
      
      try {
        _logger.info('Video', '创建控制器 - path=${item.uri}');
        final controller = VideoPlayerController.file(file);
        _videoController = controller;
        
        _logger.info('Video', '初始化开始 - path=${item.uri}');
        await controller.initialize();
        
        final isInitialized = controller.value.isInitialized;
        final duration = controller.value.duration;
        final size = controller.value.size;
        
        if (!isInitialized) {
          _logger.error('Video', '视频控制器初始化失败 - path=${item.uri}, isInitialized=false', null);
          return;
        }
        
        _logger.info('Video', '初始化成功 - path=${item.uri}, duration=${duration.inSeconds}s, size=${size.width}x${size.height}');
        await controller.setLooping(false);

        // 用于控制日志记录频率
        int lastLoggedPositionSeconds = -1;
        
        controller.addListener(() {
          if (!controller.value.isInitialized) {
            _logger.warning('Video', '控制器未初始化，跳过监听回调');
            return;
          }
          
          final position = controller.value.position;
          final duration = controller.value.duration;
          final isPlaying = controller.value.isPlaying;
          final currentPositionSeconds = position.inSeconds;
          
          // 每5秒记录一次播放状态
          if (currentPositionSeconds != lastLoggedPositionSeconds && 
              currentPositionSeconds % 5 == 0) {
            _logger.info('Video', '播放状态 - path=${item.uri}, position=${currentPositionSeconds}s/${duration.inSeconds}s, isPlaying=$isPlaying');
            lastLoggedPositionSeconds = currentPositionSeconds;
          }
          
          if (position >= duration && !controller.value.isLooping) {
            _logger.info('Video', '视频播放完成 - path=${item.uri}, duration=${duration.inSeconds}s');
            _next();
          }
        });

        if (_isPlaying) {
          _logger.info('Video', '播放开始 - path=${item.uri}');
          await controller.play();
        }
        
        if (mounted) {
          _logger.info('UI', 'setState调用 - 原因=视频初始化完成, path=${item.uri}');
          setState(() {});
        }
      } catch (e, stackTrace) {
        _logger.error('Video', '视频初始化异常 - path=${item.uri}', e, stackTrace);
        // 尝试清理控制器
        try {
          _videoController?.dispose();
          _videoController = null;
        } catch (_) {}
      }
    }
  }

  void _cancelTimersAndVideo() {
    _imageTimer?.cancel();
    _imageTimer = null;
    
    if (_videoController != null) {
      try {
        final path = _currentItem?.uri ?? 'unknown';
        _logger.info('Video', '释放控制器 - path=$path');
        _videoController?.removeListener(() {});
        _videoController?.pause();
        _videoController?.dispose();
        _videoController = null;
        _logger.info('Video', '控制器已释放 - path=$path');
      } catch (e, stackTrace) {
        _logger.error('Video', '释放控制器失败', e, stackTrace);
      }
    }
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
      _logger.warning('Image', '预加载 - 索引无效 - index=$index');
      return;
    }

    final item = _items[index];
    // 只预加载图片，不预加载视频
    if (item.type != MediaType.image) {
      _logger.info('Image', '预加载 - 不是图片类型，跳过 - id=${item.id}, type=${item.type.toString().split('.').last}');
      return;
    }

    // 如果已经预加载过，跳过
    if (_preloadedImageCache.containsKey(item.id)) {
      _logger.info('Image', '预加载 - 图片已预加载 - id=${item.id}, index=$index');
      return;
    }

    _logger.info('Image', '预加载开始 - index=$index, path=${item.uri}');
    
    try {
      final file = File(item.uri);
      if (!await file.exists()) {
        _logger.warning('Image', '预加载 - 文件不存在，跳过 - path=${item.uri}');
        return;
      }

      final bytes = await file.readAsBytes();
      _preloadedImageCache[item.id] = bytes;
      _logger.info('Image', '预加载完成 - index=$index, path=${item.uri}, size=${bytes.length} bytes');
      
      // 记录内存使用情况
      _logMemoryUsage();
    } catch (e, stackTrace) {
      _logger.error('Image', '预加载失败 - index=$index, path=${item.uri}', e, stackTrace);
    }
  }

  /// 记录内存使用情况
  void _logMemoryUsage() {
    try {
      final cacheCount = _preloadedImageCache.length;
      int totalSize = 0;
      for (final bytes in _preloadedImageCache.values) {
        totalSize += bytes.length;
      }
      final totalSizeMB = (totalSize / (1024 * 1024)).toStringAsFixed(2);
      _logger.info('Memory', '预加载缓存 - count=$cacheCount, totalSize=$totalSizeMB MB');
    } catch (e) {
      // 忽略内存统计错误
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

  /// 根据播放模式计算下一个索引
  int _calculateNextIndex() {
    if (_items.isEmpty) return 0;
    
    final mode = _settings?.playbackMode ?? PlaybackMode.sequential;
    final loop = _playlist?.settings.loop ?? true;
    
    switch (mode) {
      case PlaybackMode.sequential:
        var nextIndex = _currentIndex + 1;
        if (nextIndex >= _items.length) {
          if (!loop) {
            return _currentIndex; // 不循环，停留在当前位置
          }
          nextIndex = 0;
        }
        return nextIndex;
        
      case PlaybackMode.reverse:
        var nextIndex = _currentIndex - 1;
        if (nextIndex < 0) {
          if (!loop) {
            return _currentIndex; // 不循环，停留在当前位置
          }
          nextIndex = _items.length - 1;
        }
        return nextIndex;
        
      case PlaybackMode.random:
        // 如果所有项都已播放过，重置列表
        if (_randomPlayedIndices.length >= _items.length) {
          debugPrint('[Player] _calculateNextIndex: 随机模式 - 所有项已播放，重置列表');
          _randomPlayedIndices.clear();
        }
        
        // 生成未播放的索引列表
        final unplayedIndices = List.generate(
          _items.length,
          (index) => index,
        ).where((index) => !_randomPlayedIndices.contains(index)).toList();
        
        if (unplayedIndices.isEmpty) {
          // 如果所有项都已播放，随机选择一个
          return _currentIndex;
        }
        
        // 从未播放的索引中随机选择一个
        final random = unplayedIndices[DateTime.now().millisecondsSinceEpoch % unplayedIndices.length];
        return random;
    }
  }

  Future<void> _next() async {
    debugPrint('[Player] _next: 开始切换到下一项, 当前index=$_currentIndex, 总数量=${_items.length}');
    if (_items.isEmpty) {
      debugPrint('[Player] _next: 媒体列表为空，退出');
      return;
    }
    
    final mode = _settings?.playbackMode ?? PlaybackMode.sequential;
    final loop = _playlist?.settings.loop ?? true;
    
    final nextIndex = _calculateNextIndex();
    
    // 检查是否到达末尾且不循环
    if (nextIndex == _currentIndex && mode == PlaybackMode.sequential) {
      if (!loop) {
        debugPrint('[Player] _next: 到达末尾且未开启循环，退出');
        return;
      }
    }
    
    debugPrint('[Player] _next: 播放模式=${mode.toString().split('.').last}, 准备切换到index=$nextIndex');
    
    // 如果是随机模式，记录已播放的索引
    if (mode == PlaybackMode.random) {
      if (!_randomPlayedIndices.contains(_currentIndex)) {
        _randomPlayedIndices.add(_currentIndex);
      }
      if (!_randomPlayedIndices.contains(nextIndex)) {
        _randomPlayedIndices.add(nextIndex);
      }
      debugPrint('[Player] _next: 随机模式 - 已播放索引列表: $_randomPlayedIndices');
    }
    
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

  /// 根据播放模式计算上一个索引
  int _calculatePreviousIndex() {
    if (_items.isEmpty) return 0;
    
    final mode = _settings?.playbackMode ?? PlaybackMode.sequential;
    final loop = _playlist?.settings.loop ?? true;
    
    switch (mode) {
      case PlaybackMode.sequential:
        var prevIndex = _currentIndex - 1;
        if (prevIndex < 0) {
          if (!loop) {
            return _currentIndex; // 不循环，停留在当前位置
          }
          prevIndex = _items.length - 1;
        }
        return prevIndex;
        
      case PlaybackMode.reverse:
        var prevIndex = _currentIndex + 1;
        if (prevIndex >= _items.length) {
          if (!loop) {
            return _currentIndex; // 不循环，停留在当前位置
          }
          prevIndex = 0;
        }
        return prevIndex;
        
      case PlaybackMode.random:
        // 随机模式下，上一个应该是随机播放历史中的上一个
        // 如果历史为空，随机选择一个
        if (_randomPlayedIndices.isEmpty || _randomPlayedIndices.length == 1) {
          final random = DateTime.now().millisecondsSinceEpoch % _items.length;
          return random;
        }
        
        // 找到当前索引在历史中的位置
        final currentPos = _randomPlayedIndices.indexOf(_currentIndex);
        if (currentPos > 0) {
          // 返回历史中的上一个
          return _randomPlayedIndices[currentPos - 1];
        } else {
          // 如果当前是第一个，返回历史中的最后一个
          return _randomPlayedIndices[_randomPlayedIndices.length - 1];
        }
    }
  }

  Future<void> _previous() async {
    _logger.info('Playback', '切换到上一项 - currentIndex=$_currentIndex, totalCount=${_items.length}');
    if (_items.isEmpty) {
      _logger.warning('Playback', '媒体列表为空，退出');
      return;
    }
    
    final mode = _settings?.playbackMode ?? PlaybackMode.sequential;
    final prevIndex = _calculatePreviousIndex();
    
    _logger.info('Playback', '计算上一个索引 - mode=${mode.toString().split('.').last}, currentIndex=$_currentIndex, prevIndex=$prevIndex');
    
    // 记录切换信息
    final currentItem = _currentItem;
    final prevItem = prevIndex < _items.length ? _items[prevIndex] : null;
    if (currentItem != null && prevItem != null) {
      _logger.info('Playback', '从 ${currentItem.type.toString().split('.').last} 切换到 ${prevItem.type.toString().split('.').last} - fromIndex=$_currentIndex, toIndex=$prevIndex');
    }
    
    // 先更新索引，触发UI重建，然后再启动新的媒体
    _logger.info('UI', 'setState调用 - 原因=切换到上一项, fromIndex=$_currentIndex, toIndex=$prevIndex');
    setState(() {
      _currentIndex = prevIndex;
    });
    // 等待一帧，确保AnimatedSwitcher开始动画
    await Future.delayed(const Duration(milliseconds: 50));
    await _startCurrent();
    // 切换后，预加载新的上一张图片
    _preloadPreviousImage();
  }

  Future<void> _togglePlayPause() async {
    _logger.info('UI', 'setState调用 - 原因=播放/暂停切换, isPlaying=$_isPlaying -> ${!_isPlaying}');
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
    _logger.info('Playback', '播放页面销毁 - currentIndex=$_currentIndex');
    _cancelTimersAndVideo();
    // 取消播放时长定时器
    _playbackDurationTimer?.cancel();
    // 禁用 wakelock
    WakelockPlus.disable();
    // 清理预加载缓存
    final cacheCount = _preloadedImageCache.length;
    _preloadedImageCache.clear();
    _logger.info('Memory', '清理预加载缓存 - count=$cacheCount');
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
                    _logger.info('UI', 'setState调用 - 原因=显示/隐藏控制条, showControls=$_showControls -> ${!_showControls}');
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
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: IntrinsicWidth(
                                child: Container(
                                  margin: const EdgeInsets.all(8),
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  child: _buildControls(context),
                                ),
                              ),
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
      _logger.warning('UI', '构建媒体内容 - item为null，返回空容器');
      return Container(
        key: const ValueKey<String>('empty'),
        color: Colors.black,
      );
    }

    // 使用 item.id 和 _currentIndex 组合作为 key，确保每次切换时 key 都不同
    final key = ValueKey<String>('media_${item.id}_$_currentIndex');
    _logger.info('UI', '构建媒体内容 - id=${item.id}, type=${item.type.toString().split('.').last}, index=$_currentIndex, key=${key.value}');

    if (item.type == MediaType.image) {
      final file = File(item.uri);
      _logger.info('Image', '构建图片Widget - path=${item.uri}');
      
      // 优先使用预加载的缓存数据
      final cachedBytes = _preloadedImageCache[item.id];
      final hasCache = cachedBytes != null;
      _logger.info('Image', '图片缓存状态 - path=${item.uri}, hasCache=$hasCache, cacheSize=${hasCache ? cachedBytes.length : 0} bytes');
      
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
      _logger.warning('Video', 'UI构建 - controller为null或未初始化, controller=${controller != null}, initialized=${controller?.value.isInitialized}');
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    final aspectRatio = controller.value.aspectRatio;
    final size = controller.value.size;
    _logger.info('Video', 'UI构建 - path=${item.uri}, aspectRatio=$aspectRatio, size=${size.width}x${size.height}, VideoPlayer widget创建');
    
    // 视频同样保持完整画面，按比例缩放至最长边铺满，另一边允许留黑边。
    return Container(
      key: key,
      color: Colors.black,
      alignment: Alignment.center,
      child: AspectRatio(
        aspectRatio: aspectRatio,
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
      _logger.info('Image', '使用预加载缓存 - path=${item.uri}, size=${cachedBytes.length} bytes');
      return _buildImageWidget(item: item, bytes: cachedBytes);
    }

    // 如果没有缓存，异步读取文件
    _logger.info('Image', '缓存未命中，从文件读取 - path=${item.uri}');
    return FutureBuilder<Uint8List?>(
      future: _loadImageBytesForPlayer(file),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }

        if (snapshot.hasError) {
          _logger.error('Image', '读取文件字节失败 - path=${item.uri}', snapshot.error);
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
          _logger.error('Image', '文件字节为空 - path=${item.uri}', null);
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
        _logger.info('Image', '文件读取成功并缓存 - path=${item.uri}, size=${bytes.length} bytes');
        
        // 记录内存使用情况
        _logMemoryUsage();
        
        return _buildImageWidget(item: item, bytes: bytes);
      },
    );
  }

  /// 使用原生Android解码器解码图片
  Future<Uint8List?> _decodeImageWithNative(String imagePath) async {
    try {
      _logger.info('Image', '尝试使用原生解码器 - path=$imagePath');
      final result = await _imageDecoderChannel.invokeMethod<Uint8List>('decodeImage', {
        'path': imagePath,
      });
      if (result != null) {
        _logger.info('Image', '原生解码成功 - path=$imagePath, size=${result.length} bytes');
        return result;
      } else {
        _logger.warning('Image', '原生解码返回null - path=$imagePath');
        return null;
      }
    } on PlatformException catch (e) {
      _logger.error('Image', '原生解码失败 - path=$imagePath, code=${e.code}', e.message);
      return null;
    } catch (e, stackTrace) {
      _logger.error('Image', '原生解码异常 - path=$imagePath', e, stackTrace);
      return null;
    }
  }

  /// 检查文件路径是否是系统缓存路径
  bool _isSystemCachePath(String path) {
    // 如果文件名是纯数字.jpg，可能是系统处理的副本
    final fileName = path.split('/').last;
    // 检查是否是纯数字开头的文件名（如 1000029412.jpg）
    if (RegExp(r'^\d+\.(jpg|jpeg|png)$', caseSensitive: false).hasMatch(fileName)) {
      debugPrint('[Player] _isSystemCachePath: 检测到系统缓存路径格式 - path=$path, fileName=$fileName');
      return true;
    }
    return false;
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
    _logger.info('Image', '图片Widget构建 - path=${item.uri}, format=$format, bytes=${bytes.length}');
    
    // 如果是系统缓存路径格式，直接使用原生解码器
    final isSystemCache = _isSystemCachePath(item.uri);
    
    if (isSystemCache) {
      _logger.info('Image', '检测到系统缓存路径，使用原生解码器 - path=${item.uri}');
      return FutureBuilder<Uint8List?>(
        future: _decodeImageWithNative(item.uri),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
          
          if (snapshot.hasError) {
            _logger.error('Image', '原生解码器失败 - path=${item.uri}', snapshot.error);
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
          
          final nativeBytes = snapshot.data;
          if (nativeBytes == null || nativeBytes.isEmpty) {
            _logger.error('Image', '原生解码器返回空数据 - path=${item.uri}', null);
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
          
          _logger.info('Image', '原生解码器成功，显示图片 - path=${item.uri}, size=${nativeBytes.length} bytes');
          return Image.memory(
            nativeBytes,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              _logger.error('Image', '原生解码器结果也无法显示 - path=${item.uri}', error, stackTrace);
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
        },
      );
    }
    
    // 普通路径，先尝试Flutter解码器
    return Image.memory(
      bytes,
      fit: BoxFit.contain,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) {
          _logger.info('Image', '图片同步加载完成 - path=${item.uri}');
        } else if (frame != null) {
          _logger.info('Image', '图片异步加载完成 - path=${item.uri}');
        } else {
          _logger.info('Image', '图片正在加载中 - path=${item.uri}');
        }
        return child;
      },
      errorBuilder: (context, error, stackTrace) {
        _logger.error('Image', 'Flutter解码失败，尝试原生解码器 - path=${item.uri}', error, stackTrace);
        
        // Flutter解码失败，尝试原生解码器作为降级方案
        return FutureBuilder<Uint8List?>(
          future: _decodeImageWithNative(item.uri),
          builder: (context, nativeSnapshot) {
            if (nativeSnapshot.connectionState == ConnectionState.waiting) {
              return Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(color: Colors.white),
              );
            }
            
            if (nativeSnapshot.hasError) {
              _logger.error('Image', '原生解码器也失败 - path=${item.uri}', nativeSnapshot.error);
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
            
            final nativeBytes = nativeSnapshot.data;
            if (nativeBytes == null || nativeBytes.isEmpty) {
              _logger.error('Image', '原生解码器返回空数据 - path=${item.uri}', null);
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
            
            _logger.info('Image', '原生解码器成功，显示图片 - path=${item.uri}, size=${nativeBytes.length} bytes');
            return Image.memory(
              nativeBytes,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                _logger.error('Image', '原生解码器结果也无法显示 - path=${item.uri}', error, stackTrace);
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
          },
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
  final TextEditingController _playbackDurationController = TextEditingController();
  final FocusNode _durationFocusNode = FocusNode();
  final Logger _logger = Logger();
  final LogExporter _logExporter = LogExporter();

  AppSettings? _settings;
  bool _isLoading = true;
  bool _isExportingLogs = false;
  bool _isClearingLogs = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    // 监听切换间隔输入变化，实时保存
    _durationController.addListener(_onDurationChanged);
    // 监听播放时长输入变化，实时保存
    _playbackDurationController.addListener(_onPlaybackDurationChanged);
    // 监听切换间隔输入框焦点变化
    _durationFocusNode.addListener(_onDurationFocusChanged);
  }

  void _onDurationFocusChanged() {
    // 当输入框失去焦点且为空时，填充默认值3
    if (!_durationFocusNode.hasFocus && _settings != null) {
      final text = _durationController.text.trim();
      if (text.isEmpty) {
        final defaultSeconds = 3;
        String displayValue;
        switch (_settings!.slideDurationUnit) {
          case PlaybackDurationUnit.hours:
            displayValue = (defaultSeconds ~/ 3600).toString();
            break;
          case PlaybackDurationUnit.minutes:
            displayValue = (defaultSeconds ~/ 60).toString();
            break;
          case PlaybackDurationUnit.seconds:
            displayValue = defaultSeconds.toString();
            break;
        }
        _durationController.text = displayValue;
        // 保存设置
        _autoSaveSettings();
      }
    }
  }

  void _onDurationChanged() {
    // 延迟保存，避免频繁保存
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _autoSaveSettings();
      }
    });
  }

  void _onPlaybackDurationChanged() {
    // 延迟保存，避免频繁保存
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _autoSaveSettings();
      }
    });
  }

  Future<void> _loadSettings() async {
    final settings = await _repository.load();
    setState(() {
      _settings = settings;
      // 根据单位显示切换间隔值
      _durationController.text = _getSlideDurationDisplayValue(settings);
      // 根据单位显示播放时长值
      _playbackDurationController.text = _getPlaybackDurationDisplayValue(settings);
      _isLoading = false;
    });
  }

  /// 根据单位获取切换间隔的显示值
  String _getSlideDurationDisplayValue(AppSettings settings) {
    switch (settings.slideDurationUnit) {
      case PlaybackDurationUnit.hours:
        return (settings.slideDurationSeconds ~/ 3600).toString();
      case PlaybackDurationUnit.minutes:
        return (settings.slideDurationSeconds ~/ 60).toString();
      case PlaybackDurationUnit.seconds:
        return settings.slideDurationSeconds.toString();
    }
  }

  /// 根据单位获取播放时长的显示值
  String _getPlaybackDurationDisplayValue(AppSettings settings) {
    if (settings.maxPlaybackDurationSeconds == -1) {
      return '';
    }
    switch (settings.playbackDurationUnit) {
      case PlaybackDurationUnit.hours:
        return (settings.maxPlaybackDurationSeconds ~/ 3600).toString();
      case PlaybackDurationUnit.minutes:
        return (settings.maxPlaybackDurationSeconds ~/ 60).toString();
      case PlaybackDurationUnit.seconds:
        return settings.maxPlaybackDurationSeconds.toString();
    }
  }

  /// 根据输入值和单位计算总秒数
  int _calculateTotalSeconds(String value, PlaybackDurationUnit unit) {
    final intValue = int.tryParse(value.trim());
    if (intValue == null || intValue < 0) {
      return -1; // 无效值，返回 -1 表示不限制
    }
    if (intValue == 0) {
      return -1; // 0 也表示不限制
    }
    switch (unit) {
      case PlaybackDurationUnit.hours:
        return intValue * 3600;
      case PlaybackDurationUnit.minutes:
        return intValue * 60;
      case PlaybackDurationUnit.seconds:
        return intValue;
    }
  }

  /// 实时保存设置
  Future<void> _autoSaveSettings() async {
    if (_settings == null) return;

    // 计算切换间隔（总秒数）
    final durationText = _durationController.text.trim();
    // 如果输入为空，使用默认值3秒
    final finalDurationText = durationText.isEmpty ? '3' : durationText;
    final slideDurationSeconds = _calculateTotalSeconds(
      finalDurationText,
      _settings!.slideDurationUnit,
    );
    // 如果计算结果是 -1（无效值），使用默认值3秒
    final finalSlideDurationSeconds = (slideDurationSeconds != -1 && slideDurationSeconds >= 1) 
        ? slideDurationSeconds 
        : 3;
    
    // 计算播放时长限制（总秒数）
    final playbackDurationText = _playbackDurationController.text.trim();
    final maxPlaybackDurationSeconds = _calculateTotalSeconds(
      playbackDurationText,
      _settings!.playbackDurationUnit,
    );
    
    final updated = _settings!.copyWith(
      slideDurationSeconds: finalSlideDurationSeconds,
      maxPlaybackDurationSeconds: maxPlaybackDurationSeconds,
    );
    await _repository.save(updated);
    debugPrint('[SettingsPage] _autoSaveSettings: 自动保存完成 - orientation=${updated.playbackOrientation}, mode=${updated.playbackMode}, slideDuration=${updated.slideDurationSeconds}s, maxPlaybackDuration=${updated.maxPlaybackDurationSeconds}s');
  }

  @override
  void dispose() {
    _durationController.dispose();
    _playbackDurationController.dispose();
    _durationFocusNode.dispose();
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
                    // 播放方向设置
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
                            const Text(
                              '播放方向',
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
                                  // 实时保存
                                  _autoSaveSettings();
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
                                  // 实时保存
                                  _autoSaveSettings();
                                }
                              },
            ),
          ],
        ),
      ),
                    ),
                    const SizedBox(height: 16),
                    // 播放顺序模式设置
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '播放顺序',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),
                            RadioListTile<PlaybackMode>(
                              title: const Text('顺序'),
                              value: PlaybackMode.sequential,
                              groupValue: _settings!.playbackMode,
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() {
                                    _settings = _settings!.copyWith(
                                      playbackMode: value,
                                    );
                                  });
                                  // 实时保存
                                  _autoSaveSettings();
                                }
                              },
                            ),
                            RadioListTile<PlaybackMode>(
                              title: const Text('倒序'),
                              value: PlaybackMode.reverse,
                              groupValue: _settings!.playbackMode,
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() {
                                    _settings = _settings!.copyWith(
                                      playbackMode: value,
                                    );
                                  });
                                  // 实时保存
                                  _autoSaveSettings();
                                }
                              },
                            ),
                            RadioListTile<PlaybackMode>(
                              title: const Text('随机'),
                              value: PlaybackMode.random,
                              groupValue: _settings!.playbackMode,
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() {
                                    _settings = _settings!.copyWith(
                                      playbackMode: value,
                                    );
                                  });
                                  // 实时保存
                                  _autoSaveSettings();
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
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: TextField(
                                    controller: _durationController,
                                    decoration: const InputDecoration(
                                      labelText: '切换间隔',
                                      hintText: '例如：3',
                                      border: OutlineInputBorder(),
                                      helperText: '设置图片自动切换的时间间隔',
                                    ),
                                    keyboardType: TextInputType.number,
                                    focusNode: _durationFocusNode,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 1,
                                  child: DropdownButtonFormField<PlaybackDurationUnit>(
                                    value: _settings!.slideDurationUnit,
                                    decoration: const InputDecoration(
                                      labelText: '单位',
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                        value: PlaybackDurationUnit.hours,
                                        child: Text('小时'),
                                      ),
                                      DropdownMenuItem(
                                        value: PlaybackDurationUnit.minutes,
                                        child: Text('分钟'),
                                      ),
                                      DropdownMenuItem(
                                        value: PlaybackDurationUnit.seconds,
                                        child: Text('秒'),
                                      ),
                                    ],
                                    onChanged: (value) {
                                      if (value != null) {
                                        // 先保存当前输入的值（转换为总秒数）
                                        final currentText = _durationController.text.trim();
                                        final totalSeconds = _calculateTotalSeconds(
                                          currentText,
                                          _settings!.slideDurationUnit,
                                        );
                                        // 如果计算结果是 -1（无效值），使用当前设置的值
                                        final finalTotalSeconds = (totalSeconds != -1 && totalSeconds >= 1) 
                                            ? totalSeconds 
                                            : _settings!.slideDurationSeconds;
                                        
                                        setState(() {
                                          // 更新单位
                                          _settings = _settings!.copyWith(
                                            slideDurationUnit: value,
                                            slideDurationSeconds: finalTotalSeconds,
                                          );
                                          // 根据新单位更新显示值
                                          _durationController.text = _getSlideDurationDisplayValue(_settings!);
                                        });
                                        // 实时保存
                                        _autoSaveSettings();
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
          ],
        ),
      ),
                    ),
                    const SizedBox(height: 16),
                    // 播放时长限制设置
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '播放时长限制',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: TextField(
                                    controller: _playbackDurationController,
                                    decoration: InputDecoration(
                                      labelText: '时长',
                                      hintText: '留空表示不限制',
                                      border: const OutlineInputBorder(),
                                      helperText: '留空或输入 0 表示不限制播放时长',
                                    ),
                                    keyboardType: TextInputType.number,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 1,
                                  child: DropdownButtonFormField<PlaybackDurationUnit>(
                                    value: _settings!.playbackDurationUnit,
                                    decoration: const InputDecoration(
                                      labelText: '单位',
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                        value: PlaybackDurationUnit.hours,
                                        child: Text('小时'),
                                      ),
                                      DropdownMenuItem(
                                        value: PlaybackDurationUnit.minutes,
                                        child: Text('分钟'),
                                      ),
                                      DropdownMenuItem(
                                        value: PlaybackDurationUnit.seconds,
                                        child: Text('秒'),
                                      ),
                                    ],
                                    onChanged: (value) {
                                      if (value != null) {
                                        // 先保存当前输入的值（转换为总秒数）
                                        final currentText = _playbackDurationController.text.trim();
                                        final totalSeconds = _calculateTotalSeconds(
                                          currentText,
                                          _settings!.playbackDurationUnit,
                                        );
                                        
                                        setState(() {
                                          // 更新单位
                                          _settings = _settings!.copyWith(
                                            playbackDurationUnit: value,
                                            maxPlaybackDurationSeconds: totalSeconds,
                                          );
                                          // 根据新单位更新显示值
                                          _playbackDurationController.text = _getPlaybackDurationDisplayValue(_settings!);
                                        });
                                        // 实时保存
                                        _autoSaveSettings();
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 日志管理
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '日志管理',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '导出应用日志用于问题诊断和调试',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: _isExportingLogs ? null : _exportLogs,
                                    icon: _isExportingLogs
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.file_download),
                                    label: Text(_isExportingLogs ? '导出中...' : '导出日志'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.blue,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: _isClearingLogs ? null : _clearLogs,
                                    icon: _isClearingLogs
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.delete_sweep),
                                    label: Text(_isClearingLogs ? '清除中...' : '清除日志'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.orange,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
      ),
    );
  }

  /// 导出日志
  Future<void> _exportLogs() async {
    setState(() {
      _isExportingLogs = true;
    });

    try {
      final filePath = await _logExporter.exportLogs();
      if (mounted) {
        // 提取文件名
        final fileName = filePath.split(Platform.pathSeparator).last;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('日志已保存到: $fileName'),
            duration: const Duration(seconds: 3),
            action: SnackBarAction(
              label: '确定',
              onPressed: () {},
            ),
          ),
        );
      }
    } catch (e) {
      _logger.error('SettingsPage', '导出日志失败', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导出失败: $e'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isExportingLogs = false;
        });
      }
    }
  }

  /// 清除日志
  Future<void> _clearLogs() async {
    // 显示确认对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清除'),
        content: const Text('确定要清除所有日志吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除', style: TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() {
      _isClearingLogs = true;
    });

    try {
      await _logger.clearAllLogs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('日志已清除'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      _logger.error('SettingsPage', '清除日志失败', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('清除失败: $e'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isClearingLogs = false;
        });
      }
    }
  }
}
