import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 媒体文件管理器：负责文件去重、引用计数和自动清理
class MediaFileManager {
  static const String _prefsKeyHashToPath = 'media_file_hash_to_path';
  static const String _prefsKeyRefCount = 'media_file_ref_count';
  
  // 文件哈希 -> 文件路径映射
  Map<String, String> _hashToPath = {};
  
  // 文件路径 -> 引用计数映射
  Map<String, int> _fileRefCount = {};
  
  // 应用文件目录
  late Directory _appFilesDir;
  
  bool _initialized = false;

  /// 初始化文件管理器
  Future<void> initialize() async {
    if (_initialized) return;
    
    try {
      // 获取应用文件目录
      final appDir = await _getAppFilesDirectory();
      _appFilesDir = appDir;
      
      // 确保目录存在
      if (!await _appFilesDir.exists()) {
        await _appFilesDir.create(recursive: true);
      }
      
      // 从 SharedPreferences 加载数据
      await _loadFromPrefs();
      
      // 清理孤立文件（在后台执行，不阻塞初始化）
      cleanupOrphanedFiles().catchError((error) {
        print('[MediaFileManager] 清理孤立文件失败: $error');
      });
      
      _initialized = true;
    } catch (e) {
      print('[MediaFileManager] 初始化失败: $e');
      // 即使初始化失败，也标记为已初始化，避免重复尝试
      _initialized = true;
      rethrow;
    }
  }

  /// 获取应用文件目录
  Future<Directory> _getAppFilesDirectory() async {
    // 使用应用文档目录下的 media_files 子目录
    // 文档目录在应用卸载时会被清理，适合存储用户数据
    final appDocDir = await getApplicationDocumentsDirectory();
    final mediaFilesDir = Directory(path.join(appDocDir.path, 'media_files'));
    return mediaFilesDir;
  }

  /// 获取应用缓存目录
  Future<Directory> _getAppCacheDirectory() async {
    final cacheDir = await getTemporaryDirectory();
    return cacheDir;
  }

  /// 判断文件是否在应用缓存目录中（image_picker 创建的临时文件）
  Future<bool> _isInCacheDirectory(String filePath) async {
    try {
      // 方法1：检查路径中是否包含 /cache/ 目录（image_picker 在 Android 上使用的路径）
      final normalizedFilePath = path.normalize(filePath);
      if (normalizedFilePath.contains('/cache/')) {
        return true;
      }
      
      // 方法2：使用 path_provider 获取的缓存目录路径
      final cacheDir = await _getAppCacheDirectory();
      final normalizedCachePath = path.normalize(cacheDir.path);
      return normalizedFilePath.startsWith(normalizedCachePath);
    } catch (e) {
      // 如果获取缓存目录失败，保守处理，不删除文件
      return false;
    }
  }

  /// 判断文件是否是我们管理的文件（避免误删）
  bool _isManagedFile(String filePath) {
    // 检查文件是否在我们的管理目录中
    final normalizedFilePath = path.normalize(filePath);
    final normalizedAppFilesPath = path.normalize(_appFilesDir.path);
    return normalizedFilePath.startsWith(normalizedAppFilesPath);
  }

  /// 安全删除临时文件
  Future<void> _safeDeleteTempFile(String filePath) async {
    try {
      // 只删除缓存目录中的文件，且不是我们管理的文件
      final isInCache = await _isInCacheDirectory(filePath);
      final isManaged = _isManagedFile(filePath);
      
      if (isInCache && !isManaged) {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
          debugPrint('[MediaFileManager] 已删除临时文件: $filePath');
        }
      }
    } catch (e) {
      // 删除失败不影响主流程，只记录日志
      debugPrint('[MediaFileManager] 删除临时文件失败: $filePath, error: $e');
    }
  }

  /// 从 SharedPreferences 加载数据
  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 加载哈希到路径映射
    final hashToPathJson = prefs.getString(_prefsKeyHashToPath);
    if (hashToPathJson != null) {
      final map = jsonDecode(hashToPathJson) as Map<String, dynamic>;
      _hashToPath = map.map((key, value) => MapEntry(key, value as String));
    }
    
    // 加载引用计数
    final refCountJson = prefs.getString(_prefsKeyRefCount);
    if (refCountJson != null) {
      final map = jsonDecode(refCountJson) as Map<String, dynamic>;
      _fileRefCount = map.map((key, value) => MapEntry(key, value as int));
    }
  }

  /// 保存数据到 SharedPreferences
  Future<void> _saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 保存哈希到路径映射
    await prefs.setString(_prefsKeyHashToPath, jsonEncode(_hashToPath));
    
    // 保存引用计数
    await prefs.setString(_prefsKeyRefCount, jsonEncode(_fileRefCount));
  }

  /// 计算文件哈希值（MD5）
  Future<String> _calculateFileHash(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('File does not exist: $filePath');
    }
    
    final bytes = await file.readAsBytes();
    final hash = md5.convert(bytes);
    return hash.toString();
  }

  /// 获取文件扩展名
  String _getFileExtension(String filePath) {
    return path.extension(filePath).toLowerCase();
  }

  /// 添加文件（去重）
  /// 返回应用目录中的文件路径
  Future<String> addFile(String originalPath) async {
    if (!_initialized) {
      await initialize();
    }
    
    final originalFile = File(originalPath);
    if (!await originalFile.exists()) {
      throw Exception('Original file does not exist: $originalPath');
    }
    
    // 计算文件哈希
    final hash = await _calculateFileHash(originalPath);
    final extension = _getFileExtension(originalPath);
    final targetFileName = '$hash$extension';
    final targetPath = path.join(_appFilesDir.path, targetFileName);
    
    // 检查是否已存在相同哈希的文件
    String finalPath;
    bool needDeleteOriginal = false;
    
    if (_hashToPath.containsKey(hash)) {
      final existingPath = _hashToPath[hash]!;
      final existingFile = File(existingPath);
      
      // 验证文件确实存在
      if (await existingFile.exists()) {
        // 文件已存在，增加引用计数
        _incrementRefCount(existingPath);
        await _saveToPrefs();
        finalPath = existingPath;
        needDeleteOriginal = true; // 文件已存在，可以删除原始临时文件
      } else {
        // 文件不存在，从映射中移除
        _hashToPath.remove(hash);
        _fileRefCount.remove(existingPath);
        // 继续执行复制流程
        final targetFile = File(targetPath);
        
        // 如果目标文件已存在（可能是之前复制但映射丢失），直接使用
        if (await targetFile.exists()) {
          _hashToPath[hash] = targetPath;
          _incrementRefCount(targetPath);
          await _saveToPrefs();
          finalPath = targetPath;
          needDeleteOriginal = true; // 文件已存在，可以删除原始临时文件
        } else {
          // 复制文件到应用目录
          await originalFile.copy(targetPath);
          
          // 更新映射和引用计数
          _hashToPath[hash] = targetPath;
          _incrementRefCount(targetPath);
          await _saveToPrefs();
          finalPath = targetPath;
          needDeleteOriginal = true; // 文件已复制，可以删除原始临时文件
        }
      }
    } else {
      // 文件不存在，需要复制到应用目录
      final targetFile = File(targetPath);
      
      // 如果目标文件已存在（可能是之前复制但映射丢失），直接使用
      if (await targetFile.exists()) {
        _hashToPath[hash] = targetPath;
        _incrementRefCount(targetPath);
        await _saveToPrefs();
        finalPath = targetPath;
        needDeleteOriginal = true; // 文件已存在，可以删除原始临时文件
      } else {
        // 复制文件到应用目录
        await originalFile.copy(targetPath);
        
        // 更新映射和引用计数
        _hashToPath[hash] = targetPath;
        _incrementRefCount(targetPath);
        await _saveToPrefs();
        finalPath = targetPath;
        needDeleteOriginal = true; // 文件已复制，可以删除原始临时文件
      }
    }
    
    // 删除原始临时文件（如果是 image_picker 创建的）
    if (needDeleteOriginal) {
      await _safeDeleteTempFile(originalPath);
    }
    
    return finalPath;
  }

  /// 增加文件引用计数
  void _incrementRefCount(String filePath) {
    _fileRefCount[filePath] = (_fileRefCount[filePath] ?? 0) + 1;
  }

  /// 减少文件引用计数（引用为0时删除文件）
  Future<void> decrementRefCount(String filePath) async {
    if (!_initialized) {
      await initialize();
    }
    
    final currentCount = _fileRefCount[filePath] ?? 0;
    if (currentCount <= 0) {
      // 引用计数已经是0或不存在，直接尝试删除
      await _deleteFile(filePath);
      return;
    }
    
    final newCount = currentCount - 1;
    if (newCount <= 0) {
      // 引用计数为0，删除文件
      _fileRefCount.remove(filePath);
      await _deleteFile(filePath);
      
      // 从哈希映射中移除
      _hashToPath.removeWhere((key, value) => value == filePath);
    } else {
      // 更新引用计数
      _fileRefCount[filePath] = newCount;
    }
    
    await _saveToPrefs();
  }

  /// 删除文件
  Future<void> _deleteFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      // 删除失败，记录错误但不抛出异常
      print('[MediaFileManager] Failed to delete file: $filePath, error: $e');
    }
  }

  /// 批量减少引用计数
  Future<void> decrementRefCounts(List<String> filePaths) async {
    for (final filePath in filePaths) {
      await decrementRefCount(filePath);
    }
  }

  /// 清理孤立文件（不在引用计数表中的文件）
  Future<void> cleanupOrphanedFiles() async {
    if (!_initialized) {
      await initialize();
    }
    
    if (!await _appFilesDir.exists()) {
      return;
    }
    
    // 获取目录中的所有文件
    final files = await _appFilesDir.list().toList();
    final orphanedFiles = <File>[];
    
    for (final entity in files) {
      if (entity is File) {
        final filePath = entity.path;
        // 如果文件不在引用计数表中，说明是孤立文件
        if (!_fileRefCount.containsKey(filePath)) {
          orphanedFiles.add(entity);
        }
      }
    }
    
    // 删除孤立文件
    for (final file in orphanedFiles) {
      try {
        await file.delete();
      } catch (e) {
        print('[MediaFileManager] Failed to delete orphaned file: ${file.path}, error: $e');
      }
    }
    
    // 清理无效的哈希映射（文件不存在的映射）
    final invalidHashes = <String>[];
    for (final entry in _hashToPath.entries) {
      final file = File(entry.value);
      if (!await file.exists()) {
        invalidHashes.add(entry.key);
        _fileRefCount.remove(entry.value);
      }
    }
    
    for (final hash in invalidHashes) {
      _hashToPath.remove(hash);
    }
    
    if (orphanedFiles.isNotEmpty || invalidHashes.isNotEmpty) {
      await _saveToPrefs();
    }
  }

  /// 获取存储统计信息（用于调试）
  Future<Map<String, dynamic>> getStorageStats() async {
    if (!_initialized) {
      await initialize();
    }
    
    int totalFiles = 0;
    int totalSize = 0;
    
    if (await _appFilesDir.exists()) {
      final files = await _appFilesDir.list().toList();
      for (final entity in files) {
        if (entity is File) {
          totalFiles++;
          totalSize += await entity.length();
        }
      }
    }
    
    return {
      'totalFiles': totalFiles,
      'totalSize': totalSize,
      'totalSizeMB': (totalSize / (1024 * 1024)).toStringAsFixed(2),
      'referencedFiles': _fileRefCount.length,
      'hashMappings': _hashToPath.length,
    };
  }
}

