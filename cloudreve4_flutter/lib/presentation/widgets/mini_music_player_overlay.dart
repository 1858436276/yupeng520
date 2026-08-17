import 'package:flutter/material.dart';
import '../../../data/models/file_model.dart';
import '../../../services/app_update_service.dart';
import '../../../services/music_player_controller.dart';
import '../pages/preview/audio_preview_page.dart';
import 'thumbnail_image.dart';

/// 全局音乐悬浮播放球：播放器退出界面后仍可继续播放。
/// 可拖动；点击进入音频预览页；点 ✕ 真正退出（销毁播放器）。
class MiniMusicPlayerOverlay extends StatefulWidget {
  const MiniMusicPlayerOverlay({super.key});

  @override
  State<MiniMusicPlayerOverlay> createState() => _MiniMusicPlayerOverlayState();
}

class _MiniMusicPlayerOverlayState extends State<MiniMusicPlayerOverlay> {
  static const double _size = 58;

  Offset _dragOffset = Offset.zero;

  MusicPlayerController get _controller => MusicPlayerController.instance;

  void _openAudioPage() {
    final controller = _controller;
    if (controller.audioPageVisible) return;
    final file = controller.current;
    if (file == null) return;
    final navigator = AppUpdateService.navigatorKey.currentState;
    if (navigator == null) return;
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => AudioPreviewPage(
          file: file,
          files: controller.playlist,
          initialIndex: controller.index,
          contextHint: controller.contextHint,
          resume: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final controller = _controller;
        if (!controller.active || controller.current == null) {
          return const SizedBox.shrink();
        }
        final file = controller.current!;
        final screen = MediaQuery.of(context).size;
        final bottomInset = MediaQuery.of(context).padding.bottom;

        final maxRight = screen.width - _size - 8.0;
        final maxBottom = screen.height - bottomInset - _size - 8.0;
        final right = (12 - _dragOffset.dx).clamp(0.0, maxRight);
        final bottom = (bottomInset + 14 - _dragOffset.dy).clamp(0.0, maxBottom);

        return Positioned(
          right: right,
          bottom: bottom,
          child: GestureDetector(
            onTap: _openAudioPage,
            onPanUpdate: (details) {
              setState(() {
                _dragOffset += details.delta;
              });
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: _size,
                  height: _size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFE94560), Color(0xFF533483)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ClipOval(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const Icon(
                          Icons.music_note,
                          color: Colors.white70,
                          size: 30,
                        ),
                        ThumbnailImage(
                          file: file,
                          contextHint: _controller.contextHint,
                          borderRadius: 99,
                          fit: BoxFit.cover,
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: -6,
                  right: -6,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (_controller.audioPageVisible) {
                        final navigator = AppUpdateService.navigatorKey.currentState;
                        if (navigator != null && navigator.canPop()) {
                          navigator.pop();
                        }
                      }
                      _controller.stop();
                    },
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24, width: 1),
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
        );
      },
    );
  }
}
