import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../data/models/file_model.dart';

/// 视频小屏播放管理：播放器/控制器生命周期独立于预览页面，
/// 切换小窗后仍可继续渲染，点击小窗恢复全屏，点击 ✕ 真正退出。
class MiniVideoController extends ChangeNotifier {
  MiniVideoController._();
  static final MiniVideoController instance = MiniVideoController._();

  VideoController? _videoController;
  Player? _player;
  List<FileModel>? _files;
  int _index = 0;
  String? _entityId;
  String? _title;

  VideoController? get videoController => _videoController;
  Player? get player => _player;
  List<FileModel>? get files => _files;
  int get index => _index;
  String? get entityId => _entityId;
  String? get title => _title;

  bool get active => _videoController != null && _player != null;

  /// 进入小窗：接管播放器引用，预览页可安全退出。
  void enterMini({
    required VideoController videoController,
    required Player player,
    required List<FileModel>? files,
    required int index,
    String? entityId,
    String? title,
  }) {
    _videoController = videoController;
    _player = player;
    _files = files;
    _index = index;
    _entityId = entityId;
    _title = title;
    notifyListeners();
  }

  /// 从小窗恢复全屏：释放引用（不销毁播放器），由预览页继续使用。
  void clear() {
    _videoController = null;
    _player = null;
    notifyListeners();
  }

  /// 真正退出：销毁播放器。
  void stop() {
    _player?.dispose();
    _videoController = null;
    _player = null;
    _files = null;
    _index = 0;
    _title = null;
    notifyListeners();
  }
}
