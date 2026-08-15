import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../../data/models/file_model.dart';
import '../../../services/file_service.dart';
import 'widgets/video_controls_overlay.dart';

/// 视频预览页面
class VideoPreviewPage extends StatefulWidget {
  final FileModel file;
  final String? entityId;

  /// 当前目录视频列表（用于全屏后选择/切换视频）
  final List<FileModel>? files;
  final int initialIndex;

  const VideoPreviewPage({
    super.key,
    required this.file,
    this.entityId,
    this.files,
    this.initialIndex = 0,
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

  @override
  void initState() {
    super.initState();
    player = Player();
    controller = VideoController(player);
    _videos = (widget.files != null && widget.files!.isNotEmpty)
        ? widget.files!
        : [widget.file];
    _index = widget.initialIndex.clamp(0, _videos.length - 1);
    // 横竖屏识别、方向锁定、默认全屏由 VideoControlsOverlay 统一管理
    _loadVideoUrl();
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
    // fill/original 交给 Video 组件 BoxFit 处理；固定比例用 mpv 属性
    player.setProperty(
      'video-aspect-override',
      (mode == 'fill' || mode == 'original') ? '-1' : mode,
    );
  }

  void _setHwdec(String mode) {
    setState(() => _hwdec = mode);
    player.setProperty('hwdec', mode);
    _reload(player);
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fit = _aspectMode == 'fill' ? BoxFit.fill : BoxFit.contain;

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
                    ),
                  ),
                ),
    );
  }
}
