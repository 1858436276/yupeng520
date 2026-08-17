import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import '../../data/models/file_model.dart';
import 'file_service.dart';

/// 全局音乐播放控制器：播放器生命周期独立于页面，
/// 退出音乐播放器界面后仍可继续播放，并驱动全局悬浮播放球。
class MusicPlayerController extends ChangeNotifier {
  MusicPlayerController._();
  static final MusicPlayerController instance = MusicPlayerController._();

  Player? _player;
  FileModel? _current;
  List<FileModel> _playlist = const [];
  int _index = 0;
  String? _entityId;
  String? _contextHint;
  bool _loading = false;
  String? _error;
  bool _audioPageVisible = false;

  /// 播放会话版本号：每次 play()/stop() 递增，用于丢弃过期的 completed 跳歌
  int _playVersion = 0;
  /// 加载序号：避免并发 _load 互相覆盖
  int _loadSeq = 0;

  StreamSubscription<void>? _completedSub;

  Player? get player => _player;
  FileModel? get current => _current;
  List<FileModel> get playlist => _playlist;
  int get index => _index;
  String? get contextHint => _contextHint;
  String? get error => _error;

  bool get active => _player != null;
  bool get loading => _loading;
  bool get playing => _player?.state.playing ?? false;
  bool get hasPrev => _playlist.length > 1 && _index > 0;
  bool get hasNext => _playlist.length > 1 && _index < _playlist.length - 1;

  /// 音频预览页是否在导航栈中（用于避免悬浮球重复压栈）。
  bool get audioPageVisible => _audioPageVisible;

  void setAudioPageVisible(bool visible) {
    if (_audioPageVisible == visible) return;
    _audioPageVisible = visible;
    notifyListeners();
  }

  /// 播放列表，从 [index] 处开始。播放器已存在时切换当前歌曲。
  void play(
    List<FileModel> files,
    int index, {
    String? entityId,
    String? contextHint,
  }) {
    if (files.isEmpty) return;
    _entityId = entityId;
    _contextHint = contextHint;
    _playlist = files;
    _index = index.clamp(0, files.length - 1);
    _current = _playlist[_index];
    _player ??= Player();
    _playVersion++;
    _load();
    notifyListeners();
  }

  Future<void> _load() async {
    final file = _current;
    final player = _player;
    if (file == null || player == null) return;
    final seq = ++_loadSeq;
    _loading = true;
    _error = null;
    // open 新媒体前先取消 completed 订阅，避免替换旧媒体时触发跳歌
    _completedSub?.cancel();
    notifyListeners();
    try {
      final response = await FileService().getDownloadUrls(
        uris: [file.relativePath],
        download: false,
        entity: _entityId,
      );
      if (seq != _loadSeq) return;
      final urls = response['urls'] as List<dynamic>? ?? [];
      if (urls.isEmpty) throw Exception('无法获取音频URL');
      final url = (urls[0] as Map<String, dynamic>)['url'] as String;
      await player.open(Media(url), play: true);
    } catch (e) {
      if (seq == _loadSeq) _error = e.toString();
    } finally {
      _subscribeCompleted();
      if (seq == _loadSeq) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  void _subscribeCompleted() {
    _completedSub?.cancel();
    _completedSub = _player?.stream.completed.listen((_) {
      final p = _player;
      if (p == null || !p.state.completed) return;
      final v = _playVersion;
      // 延迟执行并校验版本：期间若用户切换了新的播放会话则忽略，避免跳错歌
      Future.microtask(() {
        if (v != _playVersion) return;
        if (_playlist.length > 1) next();
      });
    });
  }

  Future<void> next() async {
    if (_playlist.isEmpty) return;
    _index = _index < _playlist.length - 1 ? _index + 1 : 0;
    _current = _playlist[_index];
    await _load();
  }

  Future<void> prev() async {
    if (_playlist.isEmpty) return;
    _index = _index > 0 ? _index - 1 : _playlist.length - 1;
    _current = _playlist[_index];
    await _load();
  }

  void toggle() {
    final player = _player;
    if (player == null) return;
    if (player.state.playing) {
      player.pause();
    } else {
      player.play();
    }
    notifyListeners();
  }

  void play() {
    final player = _player;
    if (player == null || player.state.playing) return;
    player.play();
    notifyListeners();
  }

  void pause() {
    final player = _player;
    if (player == null || !player.state.playing) return;
    player.pause();
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    await _player?.seek(position);
    notifyListeners();
  }

  /// 真正退出：销毁播放器并清空状态。
  void stop() {
    _playVersion++;
    _completedSub?.cancel();
    _completedSub = null;
    _player?.dispose();
    _player = null;
    _current = null;
    _playlist = const [];
    _index = 0;
    _loading = false;
    _error = null;
    notifyListeners();
  }
}
