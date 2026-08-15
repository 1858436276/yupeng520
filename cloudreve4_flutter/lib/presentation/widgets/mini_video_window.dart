import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../services/mini_video_controller.dart';
import '../pages/preview/video_preview_page.dart';

/// 全局视频小屏播放窗：可拖动，点击恢复全屏预览，点 ✕ 真正退出。
class MiniVideoWindow extends StatefulWidget {
  const MiniVideoWindow({super.key});

  @override
  State<MiniVideoWindow> createState() => _MiniVideoWindowState();
}

class _MiniVideoWindowState extends State<MiniVideoWindow> {
  Offset _dragOffset = Offset.zero;

  static const double _width = 176;
  static const double _height = 100;

  void _restoreFullscreen() {
    final mini = MiniVideoController.instance;
    final files = mini.files;
    final index = mini.index;
    if (files == null || files.isEmpty) return;
    final file = files[index.clamp(0, files.length - 1)];
    final vc = mini.videoController;
    if (vc == null) return;
    mini.clear();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoPreviewPage(
          file: file,
          files: files,
          initialIndex: index,
          entityId: mini.entityId,
          existingController: vc,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MiniVideoController.instance,
      builder: (context, _) {
        final mini = MiniVideoController.instance;
        final vc = mini.videoController;
        if (!mini.active || vc == null) return const SizedBox.shrink();
        final screen = MediaQuery.of(context).size;
        final bottomInset = MediaQuery.of(context).padding.bottom;

        // 默认贴右下角，拖动时累加偏移（限制在小屏幕范围内）
        final maxRight = screen.width - _width - 8.0;
        final maxBottom = screen.height - bottomInset - _height - 8.0;
        final right = (12 - _dragOffset.dx).clamp(0.0, maxRight);
        final bottom = (bottomInset + 86 - _dragOffset.dy).clamp(0.0, maxBottom);

        return Positioned(
          right: right,
          bottom: bottom,
          child: GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                _dragOffset += details.delta;
              });
            },
            child: Container(
              width: _width,
              height: _height,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _restoreFullscreen,
                    child: Video(
                      controller: vc,
                      fit: BoxFit.contain,
                      controls: (_) => const SizedBox.shrink(),
                    ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: MiniVideoController.instance.stop,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
