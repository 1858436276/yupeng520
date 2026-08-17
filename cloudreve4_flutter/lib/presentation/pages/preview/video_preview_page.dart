import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../../data/models/file_model.dart';
import '../../../services/file_service.dart';
import '../../../services/mini_video_controller.dart';
import 'widgets/video_controls_overlay.dart';

/// 视频预览页面
class VideoPreviewPage extends StatefulWidget {
  final FileModel file;
  final String? entityId;

  /// 当前目录视频列表（用于全屏后选择/切换视频）
  final List<FileModel>? files;
  final int initialIndex;

  /// 从视频小窗恢复全屏时复用既有播放器/控制器
  final VideoController? existingController;

  const VideoPreviewPage({
    super.key,
    required this.file,
    this.entityId,
    this.files,
    this.initialIndex = 0,
    this.existingController,
  });

  @override
  State<VideoPreviewPage> createState() => _VideoPreviewPageState();
}

class _VideoPreviewPageState extends State<VideoPreviewPage> {
  late final Player player;
  late final VideoController controller;
  late final List<FileModel> _videos;
  late int _index;

  // 画面比例 / 解码方式
  String _aspectMode = 'original';
  String _hwdec = 'auto';

  bool _isLoading = true;
  String? _errorMessage;

  /// 播放器是否已转交小屏播放（转交后由小窗负责销毁）
  bool _transferredToMini = false;

  @override
  void initState() {
    super.initState();
    final useExisting = widget.existingController != null;
    if (useExisting) {
      controller = widget.existingController!;
      player = controller.player;
    } else {
      player = Player();
      controller = VideoController(player);
    }
    _videos = (widget.files != null && widget.files!.isNotEmpty)
        ? widget.files!
        : [widget.file];
    _index = widget.initialIndex.clamp(0, _videos.length - 1);
    if (useExisting) {
      // 从小窗恢复：复用当前播放状态，不重新加载媒体
      _isLoading = false;
    } else {
      // 横竖屏识别、方向锁定、默认全屏由 VideoControlsOverlay 统一管理
      _loadVideoUrl();
    }
  }

  /// 切换到小屏播放：接管播放器，退出当前预览页继续播放
  void _enterMiniPlayer() {
    _transferredToMini = true;
    final mini = MiniVideoController.instance;
    mini.enterMini(
      videoController: controller,
      player: player,
      files: _videos,
      index: _index,
      entityId: widget.entityId,
      title: _videos[_index].name,
    );
    Navigator.of(context).pop();
  }

  Future<void> _openFile(FileModel file) async {
    final response = await FileService().getDownloadUrls(
      uris: [file.relativePath],
      download: false,
      entity: widget.entityId,
    );

    final urls = response['urls'] as List<dynamic>? ?? [];
    if (urls.isEmpty) {
      throw Exception('无法获取视频URL');
    }
    final url = (urls[0] as Map<String, dynamic>)['url'] as String;
    await player.open(Media(url), play: true);
  }

  Future<void> _loadVideoUrl() async {
    try {
      setState(() => _isLoading = true);
      await _openFile(_videos[_index]);
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// 重开当前媒体（解码方式切换后生效，保留进度与倍速）
  Future<void> _reload(Player p) async {
    final position = p.state.position;
    final rate = p.state.rate;
    try {
      await _openFile(_videos[_index]);
      await p.seek(position);
      await p.setRate(rate);
    } catch (_) {}
  }

  void _setAspect(String mode) {
    setState(() => _aspectMode = mode);
    // 画面比例由 Video 组件的 aspectRatio + BoxFit 控制
  }

  Future<void> _setHwdec(String mode) async {
    setState(() => _hwdec = mode);
    // media_kit 1.2.6 未在 Player 上公开 setProperty，改由 VideoController
    // 的平台实现设置 mpv hwdec 属性（Native/Android 实现均提供该方法）。
    try {
      final vc = await controller.platform.future;
      await (vc as dynamic).setProperty('hwdec', mode);
    } catch (_) {}
    await _reload(player);
  }

  @override
  void dispose() {
    // 播放器转交小窗后由小窗负责销毁；未转交时本页负责销毁
    if (!_transferredToMini) {
      player.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fit = _aspectMode == 'fill' ? BoxFit.fill : BoxFit.contain;
    final aspectRatio = switch (_aspectMode) {
      '16:9' => 16 / 9,
      '4:3' => 4 / 3,
      '1:1' => 1.0,
      _ => null,
    };

    return Scaffold(
      backgroundColor: Colors.black,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 64, color: Colors.white),
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () {
                          setState(() {
                            _isLoading = true;
                            _errorMessage = null;
                          });
                          _loadVideoUrl();
                        },
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : ExcludeSemantics(
                  child: Video(
                    controller: controller,
                    fit: fit,
                    aspectRatio: aspectRatio,
                    controls: (state) => VideoControlsOverlay(
                      state: state,
                      title: _videos[_index].name,
                      playlist: _videos,
                      playlistIndex: _index,
                      onSwitchVideo: (file, p) => _openFile(file),
                      onReload: _reload,
                      aspectMode: _aspectMode,
                      onSetAspect: _setAspect,
                      hwdecMode: _hwdec,
                      onSetHwdec: _setHwdec,
                      onMiniPlayer: _enterMiniPlayer,
                    ),
                  ),
                ),
    );
  }
}
