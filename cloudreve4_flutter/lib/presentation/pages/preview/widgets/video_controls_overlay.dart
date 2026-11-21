import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import '../../../../core/utils/file_type_utils.dart';
import '../../../../core/utils/video_fullscreen.dart';
import '../../../../data/models/file_model.dart';
import '../../../../services/dlna_cast_service.dart';
import '../../../widgets/toast_helper.dart';

/// 自定义视频控制栏叠加层（Bilibili 风格）
class VideoControlsOverlay extends StatefulWidget {
  final VideoState state;
  final String title;

  /// 当前目录视频列表（用于全屏后选择/切换视频）
  final List<FileModel>? playlist;
  final int playlistIndex;

  /// 切换视频：由页面获取播放地址并 player.open
  final Future<void> Function(FileModel file, Player player)? onSwitchVideo;

  /// 重开当前媒体（解码方式切换后生效）
  final Future<void> Function(Player player)? onReload;

  /// 画面比例模式：16:9 / 4:3 / 1:1 / original / fill
  final String aspectMode;
  final ValueChanged<String>? onSetAspect;

  /// 解码方式：auto=硬解，no=软解
  final String hwdecMode;
  final ValueChanged<String>? onSetHwdec;

  /// 小屏播放（悬浮小窗）
  final VoidCallback? onMiniPlayer;

  const VideoControlsOverlay({
    super.key,
    required this.state,
    required this.title,
    this.playlist,
    this.playlistIndex = 0,
    this.onSwitchVideo,
    this.onReload,
    this.aspectMode = 'original',
    this.onSetAspect,
    this.hwdecMode = 'auto',
    this.onSetHwdec,
    this.onMiniPlayer,
  });

  @override
  State<VideoControlsOverlay> createState() => _VideoControlsOverlayState();
}

class _VideoControlsOverlayState extends State<VideoControlsOverlay>
    with WindowListener {
  Player get player => widget.state.widget.controller.player;

  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _isLongPressing = false;
  double _rateBeforeLongPress = 1.0;

  // 进度条拖拽状态
  bool _isSeeking = false;
  Duration _seekPosition = Duration.zero;

  // 音量控制
  bool _volumeSliderVisible = false;
  double _volumeBeforeMute = 100.0;

  // 自管全屏状态
  bool _isFullscreen = false;

  // 播放列表：当前目录视频切换
  late int _playlistIndex;
  late String _title;

  // 方向控制（移动端）：按视频宽高比自动锁定横/竖屏，旋转按钮可手动切换
  _VideoOrientation _orientation = _VideoOrientation.auto;
  bool _userOrientationOverride = false;
  StreamSubscription<VideoParams>? _videoParamsSub;

  // 锁屏：锁定时隐藏控制栏并禁用全部手势，单击解锁
  bool _locked = false;

  // 垂直滑动调亮度/音量（左1/3亮度、右1/3音量）
  bool _verticalAdjusting = false;
  _VerticalZone _verticalZone = _VerticalZone.none;
  double _verticalDragStartDy = 0.0;
  double _verticalDragStartHeight = 1.0;
  double _brightness = 1.0;
  double _brightnessStart = 1.0;
  double _volumeStart = 0.0;
  double _volumeValue = 0.0;
  bool _showVerticalIndicator = false;
  Timer? _verticalIndicatorTimer;

  // 拖动进度条
  bool _dragSeeking = false;
  double _dragStartFraction = 0.0;
  Duration _dragBubblePosition = Duration.zero;

  // 播放/暂停中央闪光提示
  int _playPauseFlashSerial = 0;
  bool _lastFlashIsPlaying = true;
  Timer? _playPauseFlashTimer;

  // 键盘焦点
  final FocusNode _focusNode = FocusNode();

  // 桌面端鼠标悬停
  Timer? _mouseHoverTimer;

  // ========== 投屏 ==========
  CastDevice? _castDevice;
  bool _casting = false;

  /// 投屏中电视是否处于播放态（用于同步 UI）
  bool _castPlaying = true;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _playlistIndex = widget.playlistIndex;
    _title = widget.title;
    _startHideTimer();
    if (_isDesktop) {
      windowManager.addListener(this);
    }
    _initAutoOrientation();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      // 播放视频默认全屏
      if (!_isFullscreen) {
        _toggleFullscreen();
      }
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _mouseHoverTimer?.cancel();
    _verticalIndicatorTimer?.cancel();
    _playPauseFlashTimer?.cancel();
    _videoParamsSub?.cancel();
    _focusNode.dispose();
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    if (_isFullscreen) {
      _doExitFullscreen();
    } else if (!_isDesktop) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
          overlays: SystemUiOverlay.values);
    }
    if (!_isDesktop) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    // 若正在投屏，异步通知电视停止（不等待、不依赖 context）
    final device = _castDevice;
    if (device != null) {
      DlnaCastService.instance.stop(device).catchError((_) {});
    }
    super.dispose();
  }

  // ========== 自动横竖屏识别（按视频宽高比） ==========

  void _initAutoOrientation() {
    if (_isDesktop) return;
    _videoParamsSub = player.stream.videoParams.listen((params) {
      if (_userOrientationOverride) return;
      final w = params.w;
      final h = params.h;
      if (w == null || h == null || w <= 0 || h <= 0) return;
      final next =
          w > h ? _VideoOrientation.landscape : _VideoOrientation.portrait;
      if (_orientation != next) {
        _orientation = next;
        _applyOrientation();
      }
    });
  }

  Future<void> _applyOrientation() async {
    if (_isDesktop) return;
    switch (_orientation) {
      case _VideoOrientation.portrait:
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        break;
      case _VideoOrientation.landscape:
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        break;
      case _VideoOrientation.auto:
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        break;
    }
  }

  void _toggleOrientation() {
    if (_isDesktop) return;
    _userOrientationOverride = true;
    final next = _orientation == _VideoOrientation.landscape
        ? _VideoOrientation.portrait
        : _VideoOrientation.landscape;
    setState(() => _orientation = next);
    _applyOrientation();
  }

  // ========== WindowListener（桌面端） ==========

  @override
  void onWindowEnterFullScreen() {
    if (!_isFullscreen && mounted) {
      setState(() => _isFullscreen = true);
    }
  }

  @override
  void onWindowLeaveFullScreen() {
    if (_isFullscreen && mounted) {
      setState(() => _isFullscreen = false);
      videoFullscreenNotifier.value = false;
    }
  }

  // ========== 全屏控制 ==========

  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      await _doExitFullscreen();
    } else {
      await _doEnterFullscreen();
    }
    if (mounted) setState(() {});
  }

  Future<void> _doEnterFullscreen() async {
    _isFullscreen = true;
    if (_isDesktop) {
      videoFullscreenNotifier.value = true;
      await windowManager.setFullScreen(true);
    } else {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: [],
      );
    }
  }

  Future<void> _doExitFullscreen() async {
    _isFullscreen = false;
    if (_isDesktop) {
      await windowManager.setFullScreen(false);
      videoFullscreenNotifier.value = false;
    } else {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  void _onBack() {
    // 若正在投屏，先停止（避免电视继续播放）
    if (_casting) {
      _stopCast();
    }
    if (_isFullscreen) {
      _doExitFullscreen().then((_) {
        if (mounted) setState(() {});
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  // ========== 控制栏显隐 ==========

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_isLongPressing) {
        _hideControls();
      }
    });
  }

  void _hideControls() {
    setState(() {
      _controlsVisible = false;
      _volumeSliderVisible = false;
    });
  }

  void _showControls() {
    setState(() {
      _controlsVisible = true;
    });
    _startHideTimer();
  }

  void _toggleControls() {
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  // ========== 锁屏 ==========

  void _onLockToggle() {
    if (_locked) {
      _unlock();
    } else {
      _hideTimer?.cancel();
      _mouseHoverTimer?.cancel();
      setState(() {
        _locked = true;
        _controlsVisible = false;
        _volumeSliderVisible = false;
      });
    }
  }

  void _unlock() {
    _hideTimer?.cancel();
    setState(() => _locked = false);
    _showControls();
  }

  // ========== 垂直滑动调亮度/音量 ==========

  void _onVerticalDragStart(DragStartDetails details) {
    final width = MediaQuery.of(context).size.width;
    final dx = details.localPosition.dx;
    final zone = dx < width / 3
        ? _VerticalZone.brightness
        : dx > width * 2 / 3
            ? _VerticalZone.volume
            : _VerticalZone.none;
    if (zone == _VerticalZone.none) return;
    _hideTimer?.cancel();
    _mouseHoverTimer?.cancel();
    _verticalIndicatorTimer?.cancel();
    _verticalZone = zone;
    _verticalAdjusting = true;
    _verticalDragStartDy = details.localPosition.dy;
    _verticalDragStartHeight = MediaQuery.of(context).size.height;
    if (zone == _VerticalZone.brightness) {
      _brightnessStart = _brightness;
    } else {
      _volumeStart = player.state.volume;
      _volumeValue = _volumeStart;
    }
    setState(() => _showVerticalIndicator = true);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_verticalAdjusting) return;
    final height = _verticalDragStartHeight;
    if (height <= 0) return;
    final delta = (_verticalDragStartDy - details.localPosition.dy) / height;
    if (_verticalZone == _VerticalZone.brightness) {
      _brightness = (_brightnessStart + delta).clamp(0.0, 1.0);
    } else {
      _volumeValue = (_volumeStart + delta * 100).clamp(0.0, 100.0);
      player.setVolume(_volumeValue);
    }
    setState(() {});
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (!_verticalAdjusting) return;
    _verticalAdjusting = false;
    _verticalIndicatorTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted && _showVerticalIndicator) {
        setState(() => _showVerticalIndicator = false);
      }
    });
    _startHideTimer();
    if (_isDesktop) _startMouseHoverTimer();
  }

  // ========== 拖动进度 ==========

  void _onDragSeekStart(DragStartDetails details) {
    final dur = player.state.duration;
    if (dur.inMilliseconds <= 0) return;
    _hideTimer?.cancel();
    _mouseHoverTimer?.cancel();
    setState(() {
      _dragSeeking = true;
      _dragStartFraction =
          player.state.position.inMilliseconds / dur.inMilliseconds;
      _dragBubblePosition = player.state.position;
      _isSeeking = true;
      _seekPosition = player.state.position;
    });
  }

  void _onDragSeekUpdate(DragUpdateDetails details) {
    if (!_dragSeeking) return;
    final dur = player.state.duration;
    final width = MediaQuery.of(context).size.width;
    if (dur.inMilliseconds <= 0 || width <= 0) return;
    final delta = details.primaryDelta ?? 0.0;
    final target = (_dragStartFraction + delta / width).clamp(0.0, 1.0);
    final targetPos =
        Duration(milliseconds: (dur.inMilliseconds * target).round());
    setState(() {
      _seekPosition = targetPos;
      _dragBubblePosition = targetPos;
    });
  }

  void _onDragSeekEnd(DragEndDetails details) {
    if (!_dragSeeking) return;
    // 本地同步 seek（更新 UI 显示）；投屏中额外向电视 seek
    player.seek(_seekPosition);
    if (_casting && _castDevice != null) {
      DlnaCastService.instance
          .seek(_castDevice!, _seekPosition)
          .catchError((_) {});
    }
    setState(() {
      _dragSeeking = false;
      _isSeeking = false;
    });
    _startHideTimer();
    if (_isDesktop) _startMouseHoverTimer();
  }

  // ========== 播放/暂停闪光 ==========

  void _togglePlayPause() {
    // 投屏中：只控制电视，本地保持暂停
    if (_casting) {
      _toggleCastPlayPause();
      return;
    }
    final willPlay = !player.state.playing;
    player.playOrPause();
    setState(() {
      _lastFlashIsPlaying = willPlay;
      _playPauseFlashSerial++;
    });
    _playPauseFlashTimer?.cancel();
    _playPauseFlashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted && _playPauseFlashSerial != 0) {
        setState(() => _playPauseFlashSerial = 0);
      }
    });
  }

  void _onLongPressStart() {
    if (_casting) return;
    _hideTimer?.cancel();
    _rateBeforeLongPress = player.state.rate;
    player.setRate(2.0);
    setState(() {
      _isLongPressing = true;
      _controlsVisible = false;
      _volumeSliderVisible = false;
    });
  }

  void _onLongPressEnd() {
    if (_casting) return;
    player.setRate(_rateBeforeLongPress);
    setState(() {
      _isLongPressing = false;
      _controlsVisible = true;
    });
    _startHideTimer();
  }

  // ========== 桌面端鼠标悬停 ==========

  void _onMouseHover(PointerHoverEvent event) {
    if (_locked) return;
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _hideTimer?.cancel();
    _mouseHoverTimer?.cancel();
    _mouseHoverTimer = Timer(const Duration(seconds: 1), () {
      if (mounted && !_isLongPressing && !_volumeSliderVisible && !_isSeeking) {
        _hideControls();
      }
    });
  }

  void _onMouseExit(PointerExitEvent event) {
    _mouseHoverTimer?.cancel();
    _startHideTimer();
  }

  // ========== 键盘快捷键 ==========

  void _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (_locked) return;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      _togglePlayPause();
    } else if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _toggleFullscreen();
    } else if (key == LogicalKeyboardKey.escape) {
      if (_isFullscreen) _onBack();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      final pos = player.state.position - const Duration(seconds: 5);
      _seekBoth(pos < Duration.zero ? Duration.zero : pos);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      final pos = player.state.position + const Duration(seconds: 5);
      final dur = player.state.duration;
      _seekBoth(pos > dur ? dur : pos);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      final vol = (player.state.volume + 5).clamp(0.0, 100.0);
      player.setVolume(vol);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      final vol = (player.state.volume - 5).clamp(0.0, 100.0);
      player.setVolume(vol);
    }
  }

  void _seekBoth(Duration position) {
    player.seek(position);
    if (_casting && _castDevice != null) {
      DlnaCastService.instance.seek(_castDevice!, position).catchError((_) {});
    }
  }

  void _toggleMute() {
    if (player.state.volume <= 0) {
      player.setVolume(_volumeBeforeMute);
    } else {
      _volumeBeforeMute = player.state.volume;
      player.setVolume(0);
    }
  }

  // ========== 音量图标点击 ==========

  void _onVolumeIconTap(double currentVolume) {
    if (_volumeSliderVisible) {
      if (currentVolume <= 0) {
        player.setVolume(_volumeBeforeMute);
      } else {
        _volumeBeforeMute = currentVolume;
        player.setVolume(0);
      }
    } else {
      _hideTimer?.cancel();
      setState(() => _volumeSliderVisible = true);
    }
  }

  // ========== 倍速菜单 ==========

  void _showSpeedMenu() {
    _hideTimer?.cancel();
    final rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0];
    final currentRate = player.state.rate;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '倍速播放',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Colors.white70,
                    ),
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            Wrap(
              children: rates.map((rate) {
                final selected = (rate - currentRate).abs() < 0.01;
                return SizedBox(
                  width: (MediaQuery.of(context).size.width - 32) / 4,
                  child: ListTile(
                    title: Text(
                      '${rate}x',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color:
                            selected ? const Color(0xFFE94560) : Colors.white,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.normal,
                        fontSize: 14,
                      ),
                    ),
                    onTap: () {
                      player.setRate(rate);
                      Navigator.of(ctx).pop();
                      _startHideTimer();
                    },
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ========== 播放列表 ==========

  Future<void> _showPlaylist() async {
    final playlist = widget.playlist;
    if (playlist == null || playlist.isEmpty) return;
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '播放列表（${playlist.length}）',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Colors.white70,
                    ),
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.55,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: playlist.length,
                itemBuilder: (context, i) {
                  final file = playlist[i];
                  final selected = i == _playlistIndex;
                  return ListTile(
                    leading: Icon(
                      FileTypeUtils.isVideo(file.name)
                          ? Icons.movie_outlined
                          : Icons.folder_outlined,
                      color:
                          selected ? const Color(0xFFE94560) : Colors.white54,
                    ),
                    title: Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? const Color(0xFFE94560) : Colors.white,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.normal,
                        fontSize: 14,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      if (i != _playlistIndex) {
                        _switchVideo(file, i);
                      }
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _switchVideo(FileModel file, int index) async {
    _hideTimer?.cancel();
    // 切换视频前先停投屏，避免电视继续播旧片
    if (_casting) await _stopCast();
    setState(() {
      _playlistIndex = index;
      _title = file.name;
      _controlsVisible = true;
    });
    try {
      await widget.onSwitchVideo?.call(file, player);
    } catch (e) {
      if (mounted) {
        ToastHelper.failure('切换失败：$e');
        setState(() => _controlsVisible = true);
      }
    }
    _startHideTimer();
  }

  // ========== 投屏（DLNA） ==========

  Future<void> _showCastDialog() async {
    _hideTimer?.cancel();
    _mouseHoverTimer?.cancel();
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _CastDeviceDialog(
        currentDevice: _castDevice,
        onCast: (device) async {
          Navigator.of(ctx).pop();
          await _startCast(device);
        },
        onStopCast: _castDevice != null ? _stopCast : null,
      ),
    );
    _startHideTimer();
  }

  Future<void> _startCast(CastDevice device) async {
    final uri = player.state.media.uri;
    if (uri.isEmpty) {
      ToastHelper.error('无法获取当前视频地址');
      return;
    }
    try {
      // 暂停本机播放，手机作为遥控器
      await player.pause();
      await DlnaCastService.instance.castUrl(device, uri.toString(),
          title: _title);
      if (!mounted) return;
      setState(() {
        _castDevice = device;
        _casting = true;
        _castPlaying = true;
        _controlsVisible = true;
      });
      ToastHelper.success('已投屏到 ${device.friendlyName}');
    } catch (e) {
      if (mounted) ToastHelper.error('投屏失败：$e');
    }
  }

  Future<void> _stopCast() async {
    final device = _castDevice;
    if (device == null) return;
    try {
      await DlnaCastService.instance.stop(device);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _castDevice = null;
      _casting = false;
      _castPlaying = true;
    });
    ToastHelper.success('已停止投屏');
  }

  /// 投屏中的播放/暂停切换
  Future<void> _toggleCastPlayPause() async {
    final device = _castDevice;
    if (device == null) return;
    final willPlay = !_castPlaying;
    try {
      if (willPlay) {
        await DlnaCastService.instance.play(device);
      } else {
        await DlnaCastService.instance.pause(device);
      }
      if (mounted) {
        setState(() {
          _castPlaying = willPlay;
          _lastFlashIsPlaying = willPlay;
          _playPauseFlashSerial++;
        });
        _playPauseFlashTimer?.cancel();
        _playPauseFlashTimer = Timer(const Duration(milliseconds: 700), () {
          if (mounted && _playPauseFlashSerial != 0) {
            setState(() => _playPauseFlashSerial = 0);
          }
        });
      }
    } catch (e) {
      if (mounted) ToastHelper.error('投屏控制失败：$e');
    }
  }

  // ========== 设置菜单 ==========

  void _showSettingsMenu() {
    _hideTimer?.cancel();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '设置',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Colors.white70,
                    ),
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            // 解码方式
            ListTile(
              leading:
                  const Icon(Icons.memory, color: Colors.white70, size: 20),
              title: const Text(
                '解码方式',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              trailing: Text(
                widget.hwdecMode == 'auto' ? '硬解码' : '软解码',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _showDecodeMenu();
              },
            ),
            // 画面比例
            ListTile(
              leading: const Icon(Icons.aspect_ratio,
                  color: Colors.white70, size: 20),
              title: const Text(
                '画面比例',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              trailing: Text(
                _aspectLabel(widget.aspectMode),
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _showAspectMenu();
              },
            ),
            // 投屏
            ListTile(
              leading: const Icon(Icons.cast, color: Colors.white70, size: 20),
              title: const Text(
                '投屏',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              trailing: _casting
                  ? const Text(
                      '投屏中',
                      style:
                          TextStyle(color: Color(0xFFE94560), fontSize: 13),
                    )
                  : const Icon(Icons.chevron_right,
                      color: Colors.white38, size: 20),
              onTap: () {
                Navigator.of(ctx).pop();
                _showCastDialog();
              },
            ),
            // 小屏播放
            if (widget.onMiniPlayer != null)
              ListTile(
                leading: const Icon(Icons.picture_in_picture_alt,
                    color: Colors.white70, size: 20),
                title: const Text(
                  '小屏播放',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                trailing: const Icon(Icons.chevron_right,
                    color: Colors.white38, size: 20),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  // 投屏与小屏互斥
                  if (_casting) await _stopCast();
                  widget.onMiniPlayer!();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showDecodeMenu() {
    final options = <(String, String)>[
      ('auto', '硬解码'),
      ('no', '软解码'),
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...options.map((opt) {
              final selected = widget.hwdecMode == opt.$1;
              return ListTile(
                title: Text(
                  opt.$2,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color:
                        selected ? const Color(0xFFE94560) : Colors.white,
                    fontWeight:
                        selected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  if (!selected) widget.onSetHwdec?.call(opt.$1);
                },
              );
            }).toList(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showAspectMenu() {
    final options = <(String, String)>[
      ('original', '原始比例'),
      ('16:9', '16:9'),
      ('4:3', '4:3'),
      ('1:1', '1:1'),
      ('fill', '拉伸全屏'),
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...options.map((opt) {
              final selected = widget.aspectMode == opt.$1;
              return ListTile(
                title: Text(
                  opt.$2,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color:
                        selected ? const Color(0xFFE94560) : Colors.white,
                    fontWeight:
                        selected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  if (!selected) widget.onSetAspect?.call(opt.$1);
                },
              );
            }).toList(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _aspectLabel(String mode) {
    switch (mode) {
      case '16:9':
        return '16:9';
      case '4:3':
        return '4:3';
      case '1:1':
        return '1:1';
      case 'fill':
        return '拉伸全屏';
      default:
        return '原始比例';
    }
  }

  // ========== 工具方法 ==========

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ========== 构建 UI ==========

  @override
  Widget build(BuildContext context) {
    Widget overlay = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _locked ? _unlock : _toggleControls,
      onDoubleTap: _locked ? null : _toggleFullscreen,
      onVerticalDragStart: _locked ? null : _onVerticalDragStart,
      onVerticalDragUpdate: _locked ? null : _onVerticalDragUpdate,
      onVerticalDragEnd: _locked ? null : _onVerticalDragEnd,
      onHorizontalDragStart: _locked ? null : _onDragSeekStart,
      onHorizontalDragUpdate: _locked ? null : _onDragSeekUpdate,
      onHorizontalDragEnd: _locked ? null : _onDragSeekEnd,
      onLongPressStart: _locked ? null : (_) => _onLongPressStart(),
      onLongPressEnd: _locked ? null : (_) => _onLongPressEnd(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 拖动进度气泡
          if (_dragSeeking)
            Center(
              child: _DragSeekBubble(
                text: _formatDuration(_dragBubblePosition),
              ),
            ),

          // 播放/暂停闪光
          if (_playPauseFlashSerial != 0)
            Center(
              child: _PlayPauseFlash(
                key: ValueKey(_playPauseFlashSerial),
                isPlaying: _lastFlashIsPlaying,
              ),
            ),

          // 长按2倍速提示
          if (_isLongPressing)
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.fast_forward,
                        color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '2.0x 快进中',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        shadows: [
                          Shadow(
                              color: Colors.black.withValues(alpha: 0.5),
                              blurRadius: 4),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Buffering 指示器（投屏中不展示，避免误以为本机在加载）
          if (!_casting)
            StreamBuilder<bool>(
              stream: player.stream.buffering,
              initialData: player.state.buffering,
              builder: (context, snapshot) {
                final buffering = snapshot.data ?? player.state.buffering;
                if (!buffering) return const SizedBox.shrink();
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: Colors.white70),
                      const SizedBox(height: 10),
                      Text(
                        '网络不佳，正在缓冲…',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 14,
                          shadows: [
                            Shadow(
                              color: Colors.black.withValues(alpha: 0.6),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),

          // 播放结束：重播提示（投屏中不展示）
          if (!_casting)
            StreamBuilder<bool>(
              stream: player.stream.completed,
              builder: (context, snapshot) {
                final completed = snapshot.data ?? false;
                if (!completed) return const SizedBox.shrink();
                return StreamBuilder<Duration>(
                  stream: player.stream.position,
                  initialData: player.state.position,
                  builder: (context, posSnapshot) {
                    final pos = posSnapshot.data ?? Duration.zero;
                    final dur = player.state.duration;
                    if (dur.inMilliseconds <= 0 || pos < dur) {
                      return const SizedBox.shrink();
                    }
                    return Center(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          player.seek(Duration.zero);
                          player.play();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.replay_circle_filled_outlined,
                                color: Colors.white,
                                size: 58,
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                '重播',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),

          // 控制栏
          AnimatedOpacity(
            opacity: _controlsVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 250),
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: Column(
                children: [
                  _buildTopBar(),
                  const Spacer(),
                  _buildBottomBar(),
                ],
              ),
            ),
          ),

          // 桌面端快捷键提示
          if (_isDesktop)
            AnimatedOpacity(
              opacity: _controlsVisible ? 0.4 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _buildShortcutsHint(),
              ),
            ),

          // 锁屏按钮（常驻视频左中间）
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onLockToggle,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white38, width: 1),
                  ),
                  child: Icon(
                    _locked ? Icons.lock : Icons.lock_open,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),

          // 锁屏提示
          if (_locked)
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock, color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Text(
                      '已锁定 · 轻点屏幕解锁',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),

          // 垂直滑动调亮度/音量指示气泡
          if (_showVerticalIndicator && !_locked)
            Center(
              child: _AdjustIndicator(
                icon: _verticalZone == _VerticalZone.brightness
                    ? Icons.brightness_6
                    : Icons.volume_up,
                label: _verticalZone == _VerticalZone.brightness
                    ? '${(_brightness * 100).round()}%'
                    : '${_volumeValue.round()}%',
                fraction: _verticalZone == _VerticalZone.brightness
                    ? _brightness
                    : _volumeValue / 100,
              ),
            ),

          // 亮度蒙层
          if (_brightness < 0.999)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(
                    alpha: ((1 - _brightness) * 0.9).clamp(0.0, 1.0),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (_isDesktop) {
      overlay = MouseRegion(
        onHover: _onMouseHover,
        onExit: _onMouseExit,
        child: KeyboardListener(
          focusNode: _focusNode,
          onKeyEvent: _onKeyEvent,
          child: overlay,
        ),
      );
    }

    return PopScope(
      canPop: !_isFullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: overlay,
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
        right: 4,
        bottom: 8,
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _onBack,
          ),
          Expanded(
            child: Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // 投屏徽标
          if (_casting)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFE94560).withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cast_connected,
                      color: Colors.white, size: 12),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      _castDevice?.friendlyName ?? '投屏中',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (widget.playlist != null && widget.playlist!.length > 1)
            IconButton(
              icon: const Icon(Icons.playlist_play,
                  color: Colors.white, size: 20),
              tooltip: '播放列表',
              onPressed: _showPlaylist,
            ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 投屏状态提示
          if (_casting)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.tv,
                      color: Colors.white.withValues(alpha: 0.85), size: 14),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '正在电视上播放 · ${_castDevice?.friendlyName ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          _buildSeekBar(),
          Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom,
            ),
            child: _buildControlsRow(),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsRow() {
    return Row(
      children: [
        // 播放/暂停（投屏中反映电视状态）
        StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (context, snapshot) {
            final playing =
                _casting ? _castPlaying : (snapshot.data ?? player.state.playing);
            return IconButton(
              icon: Icon(playing ? Icons.pause : Icons.play_arrow,
                  color: Colors.white),
              onPressed: _togglePlayPause,
            );
          },
        ),
        // 音量控制（投屏时对电视无效，但保留 UI 一致）
        _buildVolumeControl(),
        // 时间
        StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (context, posSnapshot) {
            return StreamBuilder<Duration>(
              stream: player.stream.duration,
              initialData: player.state.duration,
              builder: (context, durSnapshot) {
                final pos = posSnapshot.data ?? Duration.zero;
                final dur = durSnapshot.data ?? Duration.zero;
                return Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    '${_formatDuration(pos)} / ${_formatDuration(dur)}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                  ),
                );
              },
            );
          },
        ),
        const Spacer(),
        // 倍速
        StreamBuilder<double>(
          stream: player.stream.rate,
          builder: (context, snapshot) {
            final rate = snapshot.data ?? 1.0;
            return GestureDetector(
              onTap: _casting ? null : _showSpeedMenu,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  '${rate}x',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
          },
        ),
        // 横/竖屏切换（仅移动端）
        if (!_isDesktop)
          IconButton(
            icon: Icon(
              _orientation == _VideoOrientation.landscape
                  ? Icons.screen_lock_landscape
                  : Icons.screen_lock_portrait,
              color: Colors.white,
              size: 20,
            ),
            tooltip: '横/竖屏切换',
            onPressed: _toggleOrientation,
          ),
        // 投屏
        IconButton(
          icon: Icon(
            _casting ? Icons.cast_connected : Icons.cast,
            color: _casting ? const Color(0xFFE94560) : Colors.white,
            size: 20,
          ),
          tooltip: _casting ? '投屏中' : '投屏',
          onPressed: _showCastDialog,
        ),
        // 设置
        IconButton(
          icon: const Icon(Icons.settings, color: Colors.white, size: 20),
          tooltip: '设置',
          onPressed: _showSettingsMenu,
        ),
        // 全屏
        IconButton(
          icon: Icon(
            _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            color: Colors.white,
          ),
          onPressed: _toggleFullscreen,
        ),
      ],
    );
  }

  Widget _buildVolumeControl() {
    return StreamBuilder<double>(
      stream: player.stream.volume,
      builder: (context, snapshot) {
        final volume = snapshot.data ?? 100.0;
        final isMuted = volume <= 0;

        IconData volumeIcon;
        if (isMuted) {
          volumeIcon = Icons.volume_off;
        } else if (volume < 50) {
          volumeIcon = Icons.volume_down;
        } else {
          volumeIcon = Icons.volume_up;
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => _onVolumeIconTap(volume),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(volumeIcon, color: Colors.white, size: 22),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              alignment: Alignment.centerLeft,
              child: _volumeSliderVisible
                  ? SizedBox(
                      width: 100,
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 5),
                          overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 10),
                          activeTrackColor: const Color(0xFFE94560),
                          inactiveTrackColor: Colors.white24,
                          thumbColor: const Color(0xFFE94560),
                        ),
                        child: Slider(
                          value: volume.clamp(0.0, 100.0),
                          min: 0,
                          max: 100,
                          onChanged: (v) {
                            _hideTimer?.cancel();
                            _mouseHoverTimer?.cancel();
                            player.setVolume(v);
                          },
                          onChangeEnd: (_) {
                            _startHideTimer();
                            if (_isDesktop) _startMouseHoverTimer();
                          },
                        ),
                      ),
                    )
                  : const SizedBox(width: 0),
            ),
          ],
        );
      },
    );
  }

  void _startMouseHoverTimer() {
    _mouseHoverTimer?.cancel();
    _mouseHoverTimer = Timer(const Duration(seconds: 1), () {
      if (mounted && !_isLongPressing && !_volumeSliderVisible && !_isSeeking) {
        _hideControls();
      }
    });
  }

  Widget _buildSeekBar() {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, posSnapshot) {
        return StreamBuilder<Duration>(
          stream: player.stream.duration,
          initialData: player.state.duration,
          builder: (context, durSnapshot) {
            return StreamBuilder<Duration>(
              stream: player.stream.buffer,
              builder: (context, bufSnapshot) {
                final position = posSnapshot.data ?? Duration.zero;
                final duration = durSnapshot.data ?? Duration.zero;
                final buffer = bufSnapshot.data ?? Duration.zero;

                final displayPos = _isSeeking ? _seekPosition : position;
                final value = duration.inMilliseconds > 0
                    ? displayPos.inMilliseconds / duration.inMilliseconds
                    : 0.0;
                final bufferValue = duration.inMilliseconds > 0
                    ? (buffer.inMilliseconds / duration.inMilliseconds)
                        .clamp(0.0, 1.0)
                    : 0.0;

                return SizedBox(
                  height: 20,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const inset = 24.0;
                      final trackWidth = constraints.maxWidth - inset * 2;
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned(
                            left: inset,
                            width: trackWidth * bufferValue,
                            top: (constraints.maxHeight - 2) / 2,
                            height: 2,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white30,
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                          ),
                          SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 2,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12,
                              ),
                              activeTrackColor: const Color(0xFFE94560),
                              inactiveTrackColor: Colors.white24,
                              thumbColor: const Color(0xFFE94560),
                            ),
                            child: Slider(
                              value: value.clamp(0.0, 1.0),
                              onChanged: (v) {
                                _hideTimer?.cancel();
                                _mouseHoverTimer?.cancel();
                                setState(() {
                                  _isSeeking = true;
                                  _seekPosition = Duration(
                                    milliseconds:
                                        (duration.inMilliseconds * v).round(),
                                  );
                                });
                              },
                              onChangeEnd: (v) {
                                final seekTo = Duration(
                                  milliseconds:
                                      (duration.inMilliseconds * v).round(),
                                );
                                // 本地同步 + 投屏同步
                                player.seek(seekTo);
                                if (_casting && _castDevice != null) {
                                  DlnaCastService.instance
                                      .seek(_castDevice!, seekTo)
                                      .catchError((_) {});
                                }
                                setState(() => _isSeeking = false);
                                _startHideTimer();
                                if (_isDesktop) _startMouseHoverTimer();
                              },
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildShortcutsHint() {
    const shortcuts = [
      ('Space', '暂停/播放'),
      ('M', '静音'),
      ('Enter', '全屏'),
      ('Esc', '退出全屏'),
      ('←→', '快退/快进 5s'),
      ('↑↓', '音量 ±5'),
    ];
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: EdgeInsets.only(
          right: 12,
          top: MediaQuery.of(context).padding.top + 48,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black38,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: shortcuts.map((s) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 42,
                      child: Text(
                        s.$1,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    Text(
                      s.$2,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 10),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

/// 垂直滑动调节（亮度/音量）指示气泡
class _AdjustIndicator extends StatelessWidget {
  final IconData icon;
  final String label;
  final double fraction;

  const _AdjustIndicator({
    required this.icon,
    required this.label,
    required this.fraction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 148,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 26),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 64,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Container(
                  width: 5,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                FractionallySizedBox(
                  heightFactor: fraction.clamp(0.0, 1.0),
                  child: Container(
                    width: 5,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE94560),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 垂直滑动分区：左侧亮度、右侧音量、中间不响应
enum _VerticalZone { none, brightness, volume }

/// 移动端方向锁定状态
enum _VideoOrientation { auto, portrait, landscape }

/// 拖拽进度时的当前时间气泡
class _DragSeekBubble extends StatelessWidget {
  final String text;
  const _DragSeekBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.schedule, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 播放/暂停中央闪光提示
class _PlayPauseFlash extends StatefulWidget {
  final bool isPlaying;
  const _PlayPauseFlash({super.key, required this.isPlaying});

  @override
  State<_PlayPauseFlash> createState() => _PlayPauseFlashState();
}

class _PlayPauseFlashState extends State<_PlayPauseFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0).animate(progress),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.72, end: 1.15).animate(progress),
        child: Container(
          width: 78,
          height: 78,
          decoration: const BoxDecoration(
            color: Colors.black45,
            shape: BoxShape.circle,
          ),
          child: Icon(
            widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: Colors.white,
            size: 46,
          ),
        ),
      ),
    );
  }
}

/// 投屏设备选择对话框
class _CastDeviceDialog extends StatefulWidget {
  final CastDevice? currentDevice;
  final void Function(CastDevice device) onCast;
  final Future<void> Function()? onStopCast;

  const _CastDeviceDialog({
    required this.onCast,
    this.currentDevice,
    this.onStopCast,
  });

  @override
  State<_CastDeviceDialog> createState() => _CastDeviceDialogState();
}

class _CastDeviceDialogState extends State<_CastDeviceDialog> {
  List<CastDevice> _devices = [];
  bool _searching = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _error = null;
      _devices = [];
    });
    try {
      final devices = await DlnaCastService.instance.discover();
      if (mounted) {
        setState(() {
          _devices = devices;
          _searching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _searching = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black87,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.cast, color: Colors.white),
                const SizedBox(width: 8),
                const Text('投屏',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
                const Spacer(),
                if (widget.currentDevice != null && widget.onStopCast != null)
                  TextButton(
                    onPressed: () async {
                      await widget.onStopCast?.call();
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    child: const Text('停止投屏',
                        style: TextStyle(color: Color(0xFFE94560))),
                  ),
              ],
            ),
            const Divider(color: Colors.white24),
            if (_searching)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Column(children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 12),
                  Text('正在搜索投屏设备...',
                      style: TextStyle(color: Colors.white70)),
                ]),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Text('搜索失败：$_error',
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  TextButton(onPressed: _search, child: const Text('重试')),
                ]),
              )
            else if (_devices.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  const Text('未找到投屏设备',
                      style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 8),
                  TextButton(onPressed: _search, child: const Text('重新搜索')),
                ]),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _devices.length,
                  itemBuilder: (context, i) {
                    final device = _devices[i];
                    final isCurrent =
                        widget.currentDevice?.location == device.location;
                    return ListTile(
                      leading: Icon(
                        Icons.tv,
                        color: isCurrent
                            ? const Color(0xFFE94560)
                            : Colors.white70,
                      ),
                      title: Text(
                        device.friendlyName,
                        style: TextStyle(
                          color: isCurrent
                              ? const Color(0xFFE94560)
                              : Colors.white,
                        ),
                      ),
                      trailing: isCurrent
                          ? const Icon(Icons.check,
                              color: Color(0xFFE94560))
                          : null,
                      onTap: () => widget.onCast(device),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}