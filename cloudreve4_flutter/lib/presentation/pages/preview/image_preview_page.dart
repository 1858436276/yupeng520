import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import '../../../data/models/file_model.dart';
import '../../../services/file_service.dart';
import '../../../services/cache_manager_service.dart';

/// 图片预览页面（大厂风格：全屏黑底、点击显隐控制栏、双击/滚轮缩放）
class ImagePreviewPage extends StatefulWidget {
  final FileModel file;
  final String? entityId;

  const ImagePreviewPage({super.key, required this.file, this.entityId});

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

  bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
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
        uris: [widget.file.relativePath],
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildBody(),
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
              widget.file.name,
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
    final size = widget.file.size;
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
        right: 16,
        top: 16,
      ),
      child: Row(
        children: [
          Icon(Icons.zoom_in, size: 14, color: Colors.white60),
          const SizedBox(width: 6),
          const Text(
            '双击或 Ctrl+滚轮缩放 · 双指捏合缩放',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
          const Spacer(),
          if (size != null && size > 0)
            Text(
              _formatSize(size),
              style: const TextStyle(color: Colors.white60, fontSize: 12),
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
      return const Center(child: Text('无法加载图片', style: TextStyle(color: Colors.white70)));
    }

    return Listener(
      onPointerSignal: (signal) {
        if (signal is PointerScrollEvent) _onPointerSignal(signal);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleOverlay,
        onDoubleTap: _onDoubleTap,
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
          loadingBuilder: (context, event) =>
              const Center(child: CircularProgressIndicator(color: Colors.white70)),
          errorBuilder: (context, error, stackTrace) => const Center(
            child: Icon(Icons.error_outline, size: 48, color: Colors.white54),
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
