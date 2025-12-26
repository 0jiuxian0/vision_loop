import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';

/// 日志级别
enum LogLevel {
  info,
  warning,
  error,
}

/// 日志管理器：负责日志的写入、切分和管理
class Logger {
  static final Logger _instance = Logger._internal();
  factory Logger() => _instance;
  Logger._internal();

  static const int _maxFileSize = 1024 * 1024; // 1MB
  static const String _logDirName = 'logs';
  static const String _logFileNamePrefix = 'app';
  
  Directory? _logDir;
  File? _currentLogFile;
  int _currentFileIndex = 0;
  String _currentDate = '';
  bool _initialized = false;

  /// 初始化日志系统
  Future<void> initialize() async {
    if (_initialized) return;
    
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      _logDir = Directory(path.join(appDocDir.path, _logDirName));
      
      if (!await _logDir!.exists()) {
        await _logDir!.create(recursive: true);
      }
      
      _currentDate = _getCurrentDate();
      await _openLogFile();
      _initialized = true;
      
      info('Logger', '日志系统初始化完成');
    } catch (e) {
      debugPrint('[Logger] 初始化失败: $e');
    }
  }

  /// 获取当前日期字符串 (yyyy-MM-dd)
  String _getCurrentDate() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// 检查文件是否有 UTF-8 BOM
  Future<bool> _hasBOM(File file) async {
    try {
      if (!await file.exists()) return false;
      final size = await file.length();
      if (size < 3) return false;
      
      final bytes = await file.openRead(0, 3).toList();
      if (bytes.isEmpty || bytes[0].isEmpty) return false;
      
      final firstBytes = bytes[0];
      return firstBytes.length >= 3 &&
          firstBytes[0] == 0xEF &&
          firstBytes[1] == 0xBB &&
          firstBytes[2] == 0xBF;
    } catch (e) {
      return false;
    }
  }

  /// 打开日志文件
  Future<void> _openLogFile() async {
    if (_logDir == null) return;
    
    try {
      // 检查日期是否变化，如果变化则重置文件索引
      final today = _getCurrentDate();
      if (today != _currentDate) {
        _currentDate = today;
        _currentFileIndex = 0;
      }
      
      // 查找下一个可用的文件索引
      bool isNewFile = false;
      while (true) {
        final fileName = '${_logFileNamePrefix}_$_currentDate${_currentFileIndex > 0 ? '_$_currentFileIndex' : ''}.log';
        final file = File(path.join(_logDir!.path, fileName));
        
        if (!await file.exists()) {
          _currentLogFile = file;
          isNewFile = true;
          break;
        }
        
        // 检查文件大小
        final size = await file.length();
        if (size < _maxFileSize) {
          _currentLogFile = file;
          isNewFile = false;
          break;
        }
        
        // 文件已满，使用下一个索引
        _currentFileIndex++;
      }
      
      // 如果是新文件，写入 UTF-8 BOM
      // 如果是已存在的文件但没有 BOM，也需要添加 BOM（但需要重写文件，这里只处理新文件）
      if (isNewFile && _currentLogFile != null) {
        final bom = [0xEF, 0xBB, 0xBF]; // UTF-8 BOM
        await _currentLogFile!.writeAsBytes(bom);
      } else if (_currentLogFile != null && !isNewFile) {
        // 检查已存在的文件是否有 BOM
        final hasBom = await _hasBOM(_currentLogFile!);
        if (!hasBom) {
          // 文件已存在但没有 BOM，需要添加 BOM
          // 读取现有内容
          final existingContent = await _currentLogFile!.readAsBytes();
          // 写入 BOM + 现有内容
          final bom = [0xEF, 0xBB, 0xBF];
          await _currentLogFile!.writeAsBytes([...bom, ...existingContent]);
        }
      }
    } catch (e) {
      debugPrint('[Logger] 打开日志文件失败: $e');
    }
  }

  /// 检查并切分日志文件
  Future<void> _checkAndRotate() async {
    if (_currentLogFile == null) return;
    
    try {
      final size = await _currentLogFile!.length();
      if (size >= _maxFileSize) {
        _currentFileIndex++;
        await _openLogFile();
      }
    } catch (e) {
      debugPrint('[Logger] 检查日志文件大小失败: $e');
    }
  }

  /// 写入日志
  Future<void> _writeLog(LogLevel level, String module, String message, [Object? error, StackTrace? stackTrace]) async {
    if (!_initialized) {
      await initialize();
    }
    
    if (_currentLogFile == null) {
      await _openLogFile();
    }
    
    if (_currentLogFile == null) return;
    
    try {
      final timestamp = DateTime.now();
      final timeStr = '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')} '
          '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:'
          '${timestamp.second.toString().padLeft(2, '0')}.${timestamp.millisecond.toString().padLeft(3, '0')}';
      
      final levelStr = level.name.toUpperCase().padRight(7);
      final logLine = '[$timeStr] [$levelStr] [$module] $message';
      
      // 同时输出到控制台
      debugPrint(logLine);
      
      // 写入文件
      await _currentLogFile!.writeAsString('$logLine\n', mode: FileMode.append);
      
      // 如果有错误和堆栈，也写入
      if (error != null) {
        await _currentLogFile!.writeAsString('  Error: $error\n', mode: FileMode.append);
      }
      if (stackTrace != null) {
        await _currentLogFile!.writeAsString('  StackTrace: $stackTrace\n', mode: FileMode.append);
      }
      
      // 检查是否需要切分
      await _checkAndRotate();
    } catch (e) {
      debugPrint('[Logger] 写入日志失败: $e');
    }
  }

  /// 记录 INFO 级别日志
  void info(String module, String message) {
    _writeLog(LogLevel.info, module, message);
  }

  /// 记录 WARNING 级别日志
  void warning(String module, String message, [Object? error]) {
    _writeLog(LogLevel.warning, module, message, error);
  }

  /// 记录 ERROR 级别日志
  void error(String module, String message, [Object? error, StackTrace? stackTrace]) {
    _writeLog(LogLevel.error, module, message, error, stackTrace);
  }

  /// 获取所有日志文件
  Future<List<File>> getAllLogFiles() async {
    if (_logDir == null || !await _logDir!.exists()) {
      return [];
    }
    
    try {
      final files = await _logDir!.list().toList();
      return files
          .whereType<File>()
          .where((file) => path.basename(file.path).startsWith(_logFileNamePrefix))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path)); // 按路径倒序（最新的在前）
    } catch (e) {
      debugPrint('[Logger] 获取日志文件列表失败: $e');
      return [];
    }
  }

  /// 清除所有日志
  Future<void> clearAllLogs() async {
    if (_logDir == null || !await _logDir!.exists()) {
      return;
    }
    
    try {
      final files = await getAllLogFiles();
      for (final file in files) {
        await file.delete();
      }
      
      _currentFileIndex = 0;
      await _openLogFile();
      
      info('Logger', '所有日志已清除');
    } catch (e) {
      debugPrint('[Logger] 清除日志失败: $e');
    }
  }

  /// 获取日志目录
  Directory? get logDirectory => _logDir;
}

