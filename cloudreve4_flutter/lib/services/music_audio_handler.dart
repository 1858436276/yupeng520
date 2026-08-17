import 'package:audio_service/audio_service.dart';
import '../../data/models/file_model.dart';
import 'music_player_controller.dart';
import 'thumbnail_service.dart';

/// 音频播放媒体会话（Android 通知栏播放器）：
/// 播放时通知栏显示封面/歌名，并提供上一首/下一首/播放暂停按钮。
class MusicPlayerAudioHandler extends BaseAudioHandler with SeekHandler {
  MusicPlayerAudioHandler(MusicPlayerController controller)
      : _controller = controller {
    _controller.addListener(_sync);
    _sync();
  }

  final MusicPlayerController _controller;

  void _sync() {
    final current = _controller.current;
    if (current == null) {
      mediaItem.add(null);
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
      ));
      return;
    }
    mediaItem.add(MediaItem(
      id: current.id,
      title: current.name,
      artist: 'Cloudreve',
    ));
    _updateArtwork(current);
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        _controller.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      processingState: _controller.loading
          ? AudioProcessingState.loading
          : AudioProcessingState.ready,
      playing: _controller.playing,
      updatePosition: _controller.player?.state.position ?? Duration.zero,
    ));
  }

  Future<void> _updateArtwork(FileModel file) async {
    try {
      final url = await ThumbnailService.instance.getThumbnailUrl(
        fileUri: file.relativePath,
        contextHint: _controller.contextHint,
      );
      if (url == null || url.isEmpty) return;
      // 封面请求返回前若已切歌则忽略
      if (_controller.current?.id != file.id) return;
      mediaItem.add(
        mediaItem.value?.copyWith(artUri: Uri.tryParse(url)),
      );
    } catch (_) {
      // 封面获取失败不影响播放
    }
  }

  @override
  Future<void> play() async {
    _controller.resumePlay();
    _sync();
  }

  @override
  Future<void> pause() async {
    _controller.pause();
    _sync();
  }

  @override
  Future<void> skipToNext() async {
    await _controller.next();
    _sync();
  }

  @override
  Future<void> skipToPrevious() async {
    await _controller.prev();
    _sync();
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller.seek(position);
    _sync();
  }

  @override
  Future<void> stop() async {
    _controller.stop();
    await AudioService.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    _controller.stop();
    await super.onTaskRemoved();
  }
}
