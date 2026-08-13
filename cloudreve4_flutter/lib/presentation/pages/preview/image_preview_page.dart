import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_view/photo_view.dart';
import 'package:share_plus/share_plus.dart';
import '../../../data/models/file_model.dart';
import '../../../services/cache_manager_service.dart';
import '../../../services/file_service.dart';
import '../../widgets/toast_helper.dart';

/// 图片预览页面（大厂风格：全屏黑底、单击显隐控制栏、双指缩放、下滑关闭、旋转/保存/分享、左右切换）
class ImagePreviewPage extends StatefulWidget {
  final FileModel file;
  final String? entityId;
  final List<FileModel>? files;
  final int initialIndex;

  const ImagePreviewPage({
    super.key,
    required this.file,
    this.entityId,
    this.files,
    this.initialIndex = 0,
  });

  @override
  State<ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends State<ImagePreviewPage>
    with SingleTickerProviderStateMixin {
  String? _imageUrl;
  bool _isLoading = true;
  String? _errorMessage;

  // 控制器提到 State 层级，避免每次 setState 重建丢失缩放状态
  final PhotoViewController _photoController = PhotoViewController();
  late final AnimationController _zoomController;
  late Animation<double> _zoomAnimation;
  bool _showOverlay = true;

  // 旋转（90° 步进）
  int _quarterTurns = 0;

  // 图片列表与当前索引（支持上一张/下一张切换）
  late final List<FileModel> _images;
  late int _index;

  // 保存/分享加载态
  bool _saving = false;
  bool _sharing = false;

  bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  FileModel get _currentFile => _images[_index];
  bool get _canPrev => _images.length > 1 && _index > 0;
  bool get _canNext => _images.length > 1 && _index < _images.length - 1;

  @override
  void initState() {
    super.initState();
    _images = (widget.files != null && widget.files!.isNotEmpty)
        ? widget.files!
        : [_currentFile];
    _index = widget.initialIndex.clamp(0, _images.length - 1);
    _zoomController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _zoomAnimation = Tween<double>(begin: 1, end: 1).animate(_zoomController);
    _zoomController.addListener(_onZoomTick);
    _loadImageUrl();
  }

  @override
  void dispose() {
    _zoomController.removeListener(_onZoomTick);
    _zoomController.dispose();
    _photoController.dispose();
    if (!_isDesktop) {
      // 恢复系统状态栏/导航栏
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Future<void> _loadImageUrl() async {
    try {
      final response = await FileService().getDownloadUrls(
        uris: [_currentFile.relativePath],
        download: false,
        entity: widget.entityId,
      );

      final urls = response['urls'] as List<dynamic>? ?? [];
      if (urls.isNotEmpty) {
        final urlData = urls[0] as Map<String, dynamic>;
        final url = urlData['url'] as String;

        if (mounted) {
          setState(() {
            _imageUrl = url;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _errorMessage = '无法获取图片URL';
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _onZoomTick() {
    _photoController.scale = _zoomAnimation.value;
  }

  void _animateScaleTo(double target) {
    final from = _photoController.scale ?? 1.0;
    _zoomController.stop();
    _zoomAnimation = Tween<double>(begin: from, end: target).animate(
      CurvedAnimation(parent: _zoomController, curve: Curves.easeOut),
    );
    _zoomController.forward(from: 0);
  }

  void _toggleOverlay() {
    setState(() => _showOverlay = !_showOverlay);
    if (!_isDesktop) {
      SystemChrome.setEnabledSystemUIMode(
        _showOverlay ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      );
    }
  }

  // 切换图片：重置缩放/旋转并重新加载
  void _jumpTo(int index) {
    _zoomController.stop();
    _photoController.scale = 1.0;
    setState(() {
      _index = index;
      _quarterTurns = 0;
      _isLoading = true;
      _errorMessage = null;
      _imageUrl = null;
    });
    _loadImageUrl();
  }

  void _goPrev() {
    if (_canPrev) _jumpTo(_index - 1);
  }

  void _goNext() {
    if (_canNext) _jumpTo(_index + 1);
  }

  // Ctrl + 滚轮缩放（Linux/Windows 桌面端）
  void _onPointerSignal(PointerScrollEvent e) {
    final isControlPressed =
        HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.controlLeft,
        ) ||
        HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.controlRight,
        );
    if (!isControlPressed) return;
    final current = _photoController.scale ?? 1.0;
    final target = (current - e.scrollDelta.dy * 0.001).clamp(0.1, 5.0);
    _animateScaleTo(target);
  }

  // 双击缩放：放大到 2.6x / 还原到适配屏幕
  void _onDoubleTap() {
    final current = _photoController.scale ?? 1.0;
    final target = current > 1.4 ? 1.0 : 2.6;
    _animateScaleTo(target);
  }

  // 下滑关闭（仅未缩放时响应）
  void _onPullDown(DragEndDetails details) {
    final scale = _photoController.scale ?? 1.0;
    if (scale > 1.05) return;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 700) {
      Navigator.of(context).pop();
    }
  }

  void _rotate() {
    setState(() => _quarterTurns = (_quarterTurns + 1) % 4);
  }

  Future<Uint8List> _downloadBytes() async {
    final resp = await Dio().get<List<int>>(
      _imageUrl!,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = resp.data;
    if (data == null || data.isEmpty) {
      throw Exception('下载内容为空');
    }
    return Uint8List.fromList(data);
  }

  String _mimeType() {
    final name = _currentFile.name.toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.gif')) return 'image/gif';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.bmp')) return 'image/bmp';
    return 'image/jpeg';
  }

  Future<void> _saveImage() async {
    if (_saving || _imageUrl == null) return;
    setState(() => _saving = true);
    try {
      final bytes = await _downloadBytes();
      final dir = await getDownloadsDirectory();
      if (dir == null) {
        ToastHelper.failure('无法获取下载目录');
        return;
      }
      var dest = File('${dir.path}${Platform.pathSeparator}${_currentFile.name}');
      var index = 1;
      while (dest.existsSync()) {
        final dot = _currentFile.name.lastIndexOf('.');
        final stem =
            dot > 0 ? _currentFile.name.substring(0, dot) : _currentFile.name;
        final ext = dot > 0 ? _currentFile.name.substring(dot) : '';
        dest = File('${dir.path}${Platform.pathSeparator}$stem($index)$ext');
        index++;
      }
      await dest.writeAsBytes(bytes);
      if (mounted) ToastHelper.success('已保存到下载目录');
    } catch (e) {
      if (mounted) ToastHelper.failure('保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _shareImage() async {
    if (_sharing || _imageUrl == null) return;
    setState(() => _sharing = true);
    try {
      final bytes = await _downloadBytes();
      final tempDir = await getTemporaryDirectory();
      final file =
          File('${tempDir.path}${Platform.pathSeparator}${_currentFile.name}');
      await file.writeAsBytes(bytes);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: _mimeType())],
        subject: _currentFile.name,
      );
    } catch (e) {
      if (mounted) ToastHelper.failure('分享失败：$e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildBody(),
          // 上一张/下一张：跟随控制栏显隐，垂直居中于左右两侧
          if (_images.length > 1)
            IgnorePointer(
              ignoring: !_showOverlay,
              child: AnimatedOpacity(
                opacity: _showOverlay ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 220),
                child: Row(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: _buildNavButton(
                          Icons.chevron_left,
                          _canPrev,
                          _goPrev,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _buildNavButton(
                          Icons.chevron_right,
                          _canNext,
                          _goNext,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          AnimatedOpacity(
            opacity: _showOverlay ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 220),
            child: IgnorePointer(
              ignoring: !_showOverlay,
              child: Column(
                children: [
                  _buildTopBar(),
                  const Spacer(),
                  _buildBottomBar(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavButton(IconData icon, bool enabled, VoidCallback onTap) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: 32),
      onPressed: enabled ? onTap : null,
      style: IconButton.styleFrom(
        backgroundColor: enabled ? Colors.black38 : Colors.transparent,
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 4,
        left: 4,
        right: 16,
        bottom: 12,
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(
              _currentFile.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    final size = _currentFile.size;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 10,
        left: 16,
        right: 8,
        top: 16,
      ),
      child: Row(
        children: [
          if (_images.length > 1) ...[
            Text(
              '${_index + 1}/${_images.length}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(width: 10),
          ],
          const Text(
            '下滑关闭 · 双击缩放',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
          const Spacer(),
          if (size != null && size > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                _formatSize(size),
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
          // 旋转
          IconButton(
            icon: const Icon(Icons.rotate_right, color: Colors.white),
            tooltip: '旋转',
            onPressed: _rotate,
          ),
          // 保存
          IconButton(
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.download, color: Colors.white),
            tooltip: '保存',
            onPressed: _saving ? null : _saveImage,
          ),
          // 分享
          IconButton(
            icon: _sharing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.share, color: Colors.white),
            tooltip: '分享',
            onPressed: _sharing ? null : _shareImage,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.white54),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _errorMessage = null;
                });
                _loadImageUrl();
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_imageUrl == null) {
      return const Center(
        child: Text('无法加载图片', style: TextStyle(color: Colors.white70)),
      );
    }

    return Listener(
      onPointerSignal: (signal) {
        if (signal is PointerScrollEvent) _onPointerSignal(signal);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleOverlay,
        onDoubleTap: _onDoubleTap,
        onVerticalDragEnd: _onPullDown,
        child: RotatedBox(
          quarterTurns: _quarterTurns,
          child: PhotoView(
            controller: _photoController,
            imageProvider: CachedNetworkImageProvider(
              _imageUrl!,
              cacheManager: CacheManagerService.instance.manager,
            ),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3,
            initialScale: PhotoViewComputedScale.contained,
            backgroundDecoration: const BoxDecoration(color: Colors.black),
            loadingBuilder: (context, event) => const Center(
              child: CircularProgressIndicator(color: Colors.white70),
            ),
            errorBuilder: (context, error, stackTrace) => const Center(
              child: Icon(Icons.error_outline, size: 48, color: Colors.white54),
            ),
          ),
        ),
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    final text = unitIndex == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
    return '$text ${units[unitIndex]}';
  }
}
