import 'package:flutter/material.dart';
import '../../../data/models/file_model.dart';
import '../../../services/music_player_controller.dart';
import 'thumbnail_image.dart';

/// 全局音乐悬浮播放球：播放器退出界面后仍可继续播放。
/// 折叠态为右下角悬浮球；点击展开封面/歌名/上一首/下一首；
/// 展开面板点击 ✕ 真正退出（销毁播放器）。
class MiniMusicPlayerOverlay extends StatefulWidget {
  const MiniMusicPlayerOverlay({super.key});

  @override
  State<MiniMusicPlayerOverlay> createState() => _MiniMusicPlayerOverlayState();
}

class _MiniMusicPlayerOverlayState extends State<MiniMusicPlayerOverlay> {
  bool _expanded = false;

  MusicPlayerController get _controller => MusicPlayerController.instance;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        if (!_controller.active || _controller.current == null) {
          return const SizedBox.shrink();
        }
        final file = _controller.current!;
        return Stack(
          children: [
            if (_expanded) _buildExpandedPanel(context, file),
            Positioned(
              right: 12,
              bottom: MediaQuery.of(context).padding.bottom + 14,
              child: _buildFloatingBall(file),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFloatingBall(FileModel file) {
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        width: 58,
        height: 58,
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
              const Icon(Icons.music_note, color: Colors.white70, size: 30),
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
    );
  }

  Widget _buildExpandedPanel(BuildContext context, FileModel file) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF16213E), Color(0xFF1A1A2E)],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 24,
                offset: Offset(0, -4),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 收起把手 + 标题 + 退出
              Row(
                children: [
                  GestureDetector(
                    onTap: () => setState(() => _expanded = false),
                    child: Container(
                      width: 28,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white30,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Spacer(),
                  const Text(
                    '正在播放',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '退出播放',
                    onPressed: _controller.stop,
                    icon: const Icon(Icons.close, color: Colors.white70, size: 22),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 封面 + 歌曲信息
              Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: const LinearGradient(
                        colors: [Color(0xFFE94560), Color(0xFF533483)],
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const Icon(Icons.music_note, color: Colors.white70, size: 28),
                        ThumbnailImage(
                          file: file,
                          contextHint: _controller.contextHint,
                          borderRadius: 14,
                          fit: BoxFit.cover,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_controller.index + 1}/${_controller.playlist.length}',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _buildProgress(),
              // 播放控制
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.skip_previous, color: Colors.white),
                    iconSize: 34,
                    onPressed: _controller.hasPrev ? _controller.prev : null,
                  ),
                  const SizedBox(width: 24),
                  StreamBuilder<bool>(
                    stream: _controller.player?.stream.playing,
                    builder: (context, snapshot) {
                      final playing = snapshot.data ?? false;
                      return Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFFE94560),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFE94560).withValues(alpha: 0.4),
                              blurRadius: 18,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: IconButton(
                          icon: Icon(
                            playing ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                            size: 30,
                          ),
                          onPressed: _controller.toggle,
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 24),
                  IconButton(
                    icon: const Icon(Icons.skip_next, color: Colors.white),
                    iconSize: 34,
                    onPressed: _controller.hasNext ? _controller.next : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgress() {
    final player = _controller.player;
    if (player == null) return const SizedBox.shrink();
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      builder: (context, posSnapshot) {
        final position = posSnapshot.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.stream.duration,
          builder: (context, durSnapshot) {
            final duration = durSnapshot.data ?? Duration.zero;
            return SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: const Color(0xFFE94560),
                inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
                thumbColor: const Color(0xFFE94560),
                overlayColor: const Color(0xFFE94560).withValues(alpha: 0.3),
              ),
              child: Slider(
                value: position.inMilliseconds.toDouble(),
                max: duration.inMilliseconds > 0
                    ? duration.inMilliseconds.toDouble()
                    : 1.0,
                onChanged: (value) {
                  player.seek(Duration(milliseconds: value.toInt()));
                },
              ),
            );
          },
        );
      },
    );
  }
}
