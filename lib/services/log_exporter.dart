import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'logger.dart';

/// 日志导出器：负责打包和导出日志文件
class LogExporter {
  final Logger _logger = Logger();

  /// 导出日志（打包成zip并保存到本地）
  /// 返回保存的文件路径
  Future<String> exportLogs() async {
    try {
      _logger.info('LogExporter', '开始导出日志');
      
      // 获取所有日志文件
      final logFiles = await _logger.getAllLogFiles();
      if (logFiles.isEmpty) {
        _logger.warning('LogExporter', '没有日志文件可导出');
        throw Exception('没有日志文件可导出');
      }
      
      _logger.info('LogExporter', '找到 ${logFiles.length} 个日志文件');
      
      // 创建临时目录
      final tempDir = await getTemporaryDirectory();
      final exportDir = Directory(path.join(tempDir.path, 'log_export'));
      if (await exportDir.exists()) {
        await exportDir.delete(recursive: true);
      }
      await exportDir.create(recursive: true);
      
      // 创建zip归档
      final archive = Archive();
      
      // 检查文件是否有 UTF-8 BOM
      bool _hasBOM(List<int> bytes) {
        return bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF;
      }

      // 添加所有日志文件到归档
      for (final logFile in logFiles) {
        try {
          final fileName = path.basename(logFile.path);
          var fileData = await logFile.readAsBytes();
          
          // 如果文件没有 BOM，添加 BOM（不修改原始文件，只修改导出的数据）
          if (!_hasBOM(fileData)) {
            final bom = [0xEF, 0xBB, 0xBF];
            fileData = Uint8List.fromList([...bom, ...fileData]);
            _logger.info('LogExporter', '为文件添加 UTF-8 BOM: $fileName');
          }
          
          archive.addFile(ArchiveFile(fileName, fileData.length, fileData));
          _logger.info('LogExporter', '已添加日志文件到归档: $fileName');
        } catch (e) {
          _logger.error('LogExporter', '添加日志文件失败: ${logFile.path}', e);
        }
      }
      
      // 压缩归档
      final zipEncoder = ZipEncoder();
      final zipData = zipEncoder.encode(archive);
      
      // 保存zip文件到下载目录
      Directory? downloadDir;
      try {
        // 尝试获取下载目录（Android 10+）
        if (Platform.isAndroid) {
          // Android 上使用外部存储的下载目录
          final externalDir = await getExternalStorageDirectory();
          if (externalDir != null) {
            // 获取外部存储的父目录，然后进入 Download 文件夹
            final parentDir = externalDir.parent;
            downloadDir = Directory(path.join(parentDir.path, 'Download'));
            if (!await downloadDir.exists()) {
              await downloadDir.create(recursive: true);
            }
          }
        }
        
        // 如果获取下载目录失败，使用应用文档目录
        if (downloadDir == null || !await downloadDir.exists()) {
          downloadDir = await getApplicationDocumentsDirectory();
        }
      } catch (e) {
        _logger.warning('LogExporter', '获取下载目录失败，使用应用文档目录', e);
        downloadDir = await getApplicationDocumentsDirectory();
      }
      
      final timestamp = DateTime.now();
      final zipFileName = 'vision_loop_logs_${timestamp.year}${timestamp.month.toString().padLeft(2, '0')}${timestamp.day.toString().padLeft(2, '0')}_${timestamp.hour.toString().padLeft(2, '0')}${timestamp.minute.toString().padLeft(2, '0')}${timestamp.second.toString().padLeft(2, '0')}.zip';
      final zipFile = File(path.join(downloadDir.path, zipFileName));
      await zipFile.writeAsBytes(zipData);
      
      _logger.info('LogExporter', '日志已保存: $zipFileName, 路径: ${zipFile.path}, 大小: ${zipData.length} bytes');
      
      // 清理临时文件
      try {
        if (await exportDir.exists()) {
          await exportDir.delete(recursive: true);
        }
      } catch (e) {
        _logger.warning('LogExporter', '清理临时文件失败', e);
      }
      
      // 返回保存的文件路径
      return zipFile.path;
    } catch (e, stackTrace) {
      _logger.error('LogExporter', '导出日志失败', e, stackTrace);
      rethrow;
    }
  }
}

