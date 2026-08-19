import 'package:cloudreve4_flutter/core/utils/date_utils.dart' as date_utils;
import 'package:cloudreve4_flutter/core/utils/file_utils.dart';
import 'package:cloudreve4_flutter/data/models/file_model.dart';
import 'package:cloudreve4_flutter/presentation/widgets/file_operation_dialogs.dart';
import 'package:cloudreve4_flutter/presentation/widgets/folder_picker.dart';
import 'package:cloudreve4_flutter/presentation/widgets/toast_helper.dart';
import 'package:cloudreve4_flutter/services/file_service.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:provider/provider.dart';
import '../../providers/file_manager_provider.dart';

/// 压缩包内容预览 + 在线解压页面。
///
/// 展示 zip/7z 压缩包内的文件列表，支持勾选部分文件，
/// 选择云盘目标目录后由服务端在线解压（不占本地空间）。
class ArchiveExtractPage extends StatefulWidget {
  final FileModel file;

  const ArchiveExtractPage({super.key, required this.file});

  @override
  State<ArchiveExtractPage> createState() => _ArchiveExtractPageState();
}

class _ArchiveFileEntry {
  final String name;
  final int size;
  final DateTime updatedAt;
  final bool isDirectory;

  const _ArchiveFileEntry({
    required this.name,
    required this.size,
    required this.updatedAt,
    required this.isDirectory,
  });
}

class _ArchiveExtractPageState extends State<ArchiveExtractPage> {
  final _fileService = FileService();

  List<_ArchiveFileEntry> _entries = [];
  bool _isLoading = true;
  String? _errorMessage;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await _fileService.getArchiveFileList(
        uri: widget.file.path,
      );
      final filesData = response['files'] as List<dynamic>? ?? const [];
      if (!mounted) return;
      setState(() {
        _entries = filesData
            .map((item) => _ArchiveFileEntry(
                  name: (item as Map<String, dynamic>)['name']?.toString() ?? '',
                  size: _parseSize(item['size']),
                  updatedAt:
                      DateTime.tryParse(item['updated_at']?.toString() ?? '') ??
                          DateTime.fromMillisecondsSinceEpoch(0),
                  isDirectory: item['is_directory'] == true,
                ))
            .toList();
        _selected.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '加载压缩包内容失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  int _parseSize(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  void _toggleSelect(String name) {
    setState(() {
      if (!_selected.remove(name)) {
        _selected.add(name);
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == _entries.length) {
        _selected.clear();
      } else {
        _selected.addAll(_entries.map((e) => e.name));
      }
    });
  }

  Future<void> _extractSelected() async {
    if (_entries.isEmpty) return;

    final fileManager = context.read<FileManagerProvider>();
    final selectedNames = _selected.toList();

    final result = await showDialog<_ExtractDstResult>(
      context: context,
      builder: (ctx) => _ExtractDialog(
        currentPath: fileManager.currentPath,
        selectedCount: selectedNames.isEmpty ? _entries.length : selectedNames.length,
        selectedFiles: selectedNames,
      ),
    );

    if (result == null || !mounted) return;

    try {
      final dstUri = result.dstUri;
      await _fileService.extractArchive(
        srcUri: widget.file.path,
        dstUri: dstUri,
        password: result.password.isEmpty ? null : result.password,
        fileMask: selectedNames.isEmpty ? null : selectedNames,
      );
      if (mounted) {
        ToastHelper.success('已创建解压任务，可在任务页查看进度');
      }
    } catch (e) {
      if (mounted) {
        ToastHelper.failure('创建解压任务失败: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.file.name),
        actions: [
          if (!_isLoading && _entries.isNotEmpty)
            TextButton(
              onPressed: _toggleSelectAll,
              child: Text(
                _selected.length == _entries.length ? '取消全选' : '全选',
              ),
            ),
        ],
      ),
      body: _buildBody(context),
      bottomNavigationBar: _isLoading || _entries.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: _extractSelected,
                  icon: const Icon(Icons.unarchive, size: 18),
                  label: Text(
                    _selected.isEmpty
                        ? '全部解压到云盘'
                        : '解压选中的 ${_selected.length} 项到云盘',
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.archive_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _loadEntries,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.archive_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text('压缩包内没有文件', style: TextStyle(color: Theme.of(context).hintColor)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final isSelected = _selected.contains(entry.name);
        final depth = entry.name.split('/').length - 1;
        final displayName = entry.name.split('/').last;

        return ListTile(
          dense: true,
          onTap: () => _toggleSelect(entry.name),
          leading: Checkbox(
            value: isSelected,
            onChanged: (_) => _toggleSelect(entry.name),
          ),
          title: Row(
            children: [
              Icon(
                entry.isDirectory ? Icons.folder_outlined : _fileIcon(entry.name),
                size: 20,
                color: entry.isDirectory
                    ? const Color(0xFFFFB923)
                    : Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.isDirectory ? displayName : displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: entry.isDirectory ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Padding(
            padding: EdgeInsets.only(left: 30.0 + depth * 0),
            child: Text(
              entry.isDirectory
                  ? '文件夹'
                  : '${date_utils.DateUtils.formatFileSize(entry.size)}  ·  ${date_utils.DateUtils.formatDateTime(entry.updatedAt)}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
      },
    );
  }

  IconData _fileIcon(String name) {
    if (FileUtils.isArchiveFile(name)) return Icons.archive_outlined;
    if (FileUtils.isImageFile(name)) return Icons.image_outlined;
    if (FileUtils.isDocumentFile(name)) return Icons.description_outlined;
    if (FileUtils.isTextFile(name)) return Icons.article_outlined;
    if (FileUtils.isVideoFile(name)) return Icons.videocam_outlined;
    if (FileUtils.isAudioFile(name)) return Icons.audiotrack_outlined;
    return Icons.insert_drive_file_outlined;
  }
}

class _ExtractDstResult {
  final String dstUri;
  final String password;

  const _ExtractDstResult({required this.dstUri, required this.password});
}

class _ExtractDialog extends StatefulWidget {
  final String currentPath;
  final int selectedCount;
  final List<String> selectedFiles;

  const _ExtractDialog({
    required this.currentPath,
    required this.selectedCount,
    required this.selectedFiles,
  });

  @override
  State<_ExtractDialog> createState() => _ExtractDialogState();
}

class _ExtractDialogState extends State<_ExtractDialog> {
  String selectedDst = '';
  bool folderSelected = false;
  final passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    selectedDst = widget.currentPath;
  }

  @override
  void dispose() {
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width > 600;

    return AlertDialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 40 : MediaQuery.of(context).size.width * 0.05,
      ),
      title: Row(
        children: [
          Icon(LucideIcons.unarchive, color: theme.colorScheme.primary, size: 22),
          const SizedBox(width: 8),
          const Text('解压到云盘'),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isDesktop ? 500 : MediaQuery.of(context).size.width * 0.9,
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.selectedFiles.isEmpty
                  ? '将解压压缩包内的全部 ${widget.selectedCount} 个文件'
                  : '将解压选中的 ${widget.selectedFiles.length} 个文件/文件夹',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '解压位置',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            if (folderSelected)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.folder, size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        selectedDst == '/' ? '/ (根目录)' : selectedDst,
                        style: const TextStyle(fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => folderSelected = false),
                      child: const Text('修改'),
                    ),
                  ],
                ),
              )
            else
              Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: FolderPicker(
                  currentPath: widget.currentPath,
                  maxVisibleItems: isDesktop ? null : 3,
                  onFolderSelected: (path) {
                    setState(() {
                      selectedDst = path;
                      folderSelected = true;
                    });
                  },
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '压缩包密码（可选）',
                hintText: '加密压缩包需输入密码',
                prefixIcon: Icon(LucideIcons.lock),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final dstUri = _buildDirDst(selectedDst);
            Navigator.of(context).pop(
              _ExtractDstResult(
                dstUri: dstUri,
                password: passwordController.text.trim(),
              ),
            );
          },
          child: const Text('开始解压'),
        ),
      ],
    );
  }

  String _buildDirDst(String dstPath) {
    return FileUtils.toCloudreveUri(dstPath);
  }
}
