import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../mkw_packager/generated/mobile_splash_config.dart';
import '../../../router/app_router.dart';
import '../../../services/api_service.dart';
import '../../../services/mobile_startup_preload_service.dart';
import '../../../services/server_service.dart';
import '../../../services/storage_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/sync_provider.dart';

/// Startup page.
///
/// Mobile behavior:
/// - If the packager selected a custom splash image, that image is shown as the
///   full-screen opening picture. The code only adds a light UI layer on top.
/// - If no custom picture exists, a simple branded fallback is shown.
///
/// Desktop behavior stays compact and does not show the mobile splash artwork.
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  double _progress = 0.04;
  String _status = mkwMobileSplashLoadingText;
  String? _errorText;
  bool _initializing = false;

  bool get _useMobileSplash {
    if (kIsWeb || !mkwMobileSplashEnabled) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  bool get _hasCustomSplashImage {
    return mkwMobileSplashUseCustomImage &&
        mkwMobileSplashImageAsset.trim().isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _initApp();
      }
    });
  }

  Future<void> _initApp() async {
    if (_initializing) {
      return;
    }
    _initializing = true;

    final startedAt = DateTime.now();
    final navigator = Navigator.of(context);
    final authProvider = context.read<AuthProvider>();
    final syncProvider = context.read<SyncProvider>();

    if (mounted) {
      setState(() {
        _progress = 0.04;
        _status = mkwMobileSplashLoadingText;
        _errorText = null;
      });
    }

    try {
      await _prepareMobileResources();

      await _setProgress(0.34, '正在初始化服务器');
      await ServerService.instance.init();

      final currentServer = ServerService.instance.currentServer;
      if (currentServer != null) {
        await _setApiBaseUrl(currentServer.baseUrl);
      }

      await _setProgress(0.52, '正在初始化网络服务');
      await ApiService.instance.init();

      if (!mounted) {
        return;
      }

      await _setProgress(0.70, '正在检查登录状态');
      await authProvider.init();

      if (!mounted) {
        return;
      }

      if (authProvider.isAuthenticated) {
        await _setProgress(0.86, '正在恢复同步状态');
        final token = authProvider.token;
        await syncProvider.autoResumeIfNeeded(
          currentAccessToken: token?.accessToken,
          currentRefreshToken: token?.refreshToken,
        );
      }

      await _setProgress(1.0, '加载完成，正在进入');
      await _waitForMinimumMobileDuration(startedAt);

      if (!mounted) {
        return;
      }
      navigator.pushReplacementNamed(
        authProvider.isAuthenticated ? RouteNames.home : RouteNames.login,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _progress = 1.0;
        _status = '启动遇到问题';
        _errorText = _friendlyStartupError(error);
      });
    } finally {
      _initializing = false;
    }
  }

  Future<void> _prepareMobileResources() async {
    if (!_useMobileSplash) {
      return;
    }

    await _setProgress(0.12, _hasCustomSplashImage ? '正在加载开屏图' : '正在加载图标资源');
    if (!mounted) {
      return;
    }

    await MobileStartupPreloadService.preloadForMobile(
      context,
      preloadAllAssets: mkwMobileSplashPreloadAllAssets,
      precacheImages: mkwMobileSplashPrecacheImages,
      onProgress: (progress) {
        if (!mounted) {
          return;
        }
        final value = 0.12 + (progress.value * 0.16);
        setState(() {
          _progress = value.clamp(0.12, 0.28);
          _status = _hasCustomSplashImage ? '正在加载开屏图' : '正在加载应用资源';
        });
      },
    );

    await _setProgress(0.28, '资源加载完成');
  }

  Future<void> _setProgress(double progress, String status) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _progress = progress.clamp(0.0, 1.0);
      _status = status;
    });
    await Future<void>.delayed(const Duration(milliseconds: 45));
  }

  Future<void> _waitForMinimumMobileDuration(DateTime startedAt) async {
    if (!_useMobileSplash || mkwMobileSplashMinMillis <= 0) {
      return;
    }

    final minimum = Duration(milliseconds: mkwMobileSplashMinMillis);
    final elapsed = DateTime.now().difference(startedAt);
    final remaining = minimum - elapsed;
    if (!remaining.isNegative) {
      await Future<void>.delayed(remaining);
    }
  }

  Future<void> _setApiBaseUrl(String baseUrl) async {
    final storageService = StorageService.instance;
    await storageService.setCustomBaseUrl(baseUrl);
  }

  String _friendlyStartupError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('socket') ||
        text.contains('timeout') ||
        text.contains('network')) {
      return '网络连接异常，请检查网络后重试';
    }
    if (text.contains('server') ||
        text.contains('baseurl') ||
        text.contains('host')) {
      return '服务器配置异常，请检查服务器地址后重试';
    }
    return '应用启动失败，请重试';
  }

  @override
  Widget build(BuildContext context) {
    if (!_useMobileSplash) {
      return _DesktopStartupBody(
        status: _status,
        errorText: _errorText,
        onRetry: _initApp,
      );
    }

    return _MobileSplashBody(
      progress: _progress,
      status: _status,
      errorText: _errorText,
      hasCustomSplashImage: _hasCustomSplashImage,
      onRetry: _initApp,
    );
  }
}

class _MobileSplashBody extends StatefulWidget {
  const _MobileSplashBody({
    required this.progress,
    required this.status,
    required this.errorText,
    required this.hasCustomSplashImage,
    required this.onRetry,
  });

  final double progress;
  final String status;
  final String? errorText;
  final bool hasCustomSplashImage;
  final VoidCallback onRetry;

  @override
  State<_MobileSplashBody> createState() => _MobileSplashBodyState();
}

class _MobileSplashBodyState extends State<_MobileSplashBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..forward();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF071126),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.hasCustomSplashImage)
            const _CustomSplashImageLayer()
          else
            _AnimatedDefaultSplashLayer(
              entrance: _entranceController,
              pulse: _pulseController,
            ),
          const _SplashToneOverlay(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
              child: Column(
                children: [
                  const Spacer(),
                  FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _entranceController,
                      curve: const Interval(0.62, 1.0, curve: Curves.easeOut),
                    ),
                    child: _BottomStatusPill(
                      progress: widget.progress,
                      status: widget.errorText != null
                          ? widget.errorText!
                          : widget.status,
                      hasError: widget.errorText != null,
                      onRetry: widget.onRetry,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 默认开屏图层的带动画版本：logo 缩放淡入、标题/副标题依次滑入、
/// logo 微光脉冲、背景光晕呼吸。
class _AnimatedDefaultSplashLayer extends StatelessWidget {
  const _AnimatedDefaultSplashLayer({
    required this.entrance,
    required this.pulse,
  });

  final AnimationController entrance;
  final AnimationController pulse;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([entrance, pulse]),
      builder: (context, _) {
        final logoScale = CurvedAnimation(
          parent: entrance,
          curve: const Interval(0.0, 0.55, curve: Curves.easeOutBack),
        ).value;
        final logoFade = CurvedAnimation(
          parent: entrance,
          curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
        ).value;
        final titleFade = CurvedAnimation(
          parent: entrance,
          curve: const Interval(0.32, 0.66, curve: Curves.easeOut),
        ).value;
        final titleSlide = CurvedAnimation(
          parent: entrance,
          curve: const Interval(0.32, 0.66, curve: Curves.easeOutCubic),
        ).value;
        final subtitleFade = CurvedAnimation(
          parent: entrance,
          curve: const Interval(0.46, 0.8, curve: Curves.easeOut),
        ).value;
        final subtitleSlide = CurvedAnimation(
          parent: entrance,
          curve: const Interval(0.46, 0.8, curve: Curves.easeOutCubic),
        ).value;

        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(
                  const Color(0xFF071126),
                  const Color(0xFF0E2A4F),
                  _breathing(0.25),
                )!,
                const Color(0xFF0E2A4F),
                Color.lerp(
                  const Color(0xFF0B6B8C),
                  const Color(0xFF0E86A8),
                  _breathing(0.55),
                )!,
              ],
            ),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _BreathingHalo(pulse: pulse),
                  Transform.scale(
                    scale: 0.72 + (0.28 * logoScale),
                    child: Opacity(
                      opacity: logoFade,
                      child: Container(
                        width: 96,
                        height: 96,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(30),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF1E88E5)
                                  .withValues(alpha: 0.35 + 0.3 * _breathing(0.6)),
                              blurRadius: 34 + 16 * _breathing(0.4),
                              spreadRadius: 1,
                              offset: const Offset(0, 14),
                            ),
                          ],
                        ),
                        child: Image.asset(
                          mkwMobileSplashLogoAsset,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) =>
                              const Icon(
                            Icons.cloud_done_rounded,
                            color: Color(0xFF1E88E5),
                            size: 48,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Transform.translate(
                    offset: Offset(0, 26 * (1 - titleSlide)),
                    child: Opacity(
                      opacity: titleFade,
                      child: Text(
                        mkwMobileSplashTitle,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Transform.translate(
                    offset: Offset(0, 20 * (1 - subtitleSlide)),
                    child: Opacity(
                      opacity: subtitleFade,
                      child: Text(
                        mkwMobileSplashSubtitle,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.78),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2.4,
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

  /// 0~1 之间平滑呼吸的进度，基于 pulse 动画二次波峰，避免突兀跳动。
  double _breathing(double phase) {
    final t = (pulse.value + phase) % 1.0;
    return 0.5 - 0.5 * math.cos(t * 2 * math.pi);
  }
}

/// logo 背后的扩散光环，随 pulse 放大并淡出，形成呼吸涟漪效果。
class _BreathingHalo extends StatelessWidget {
  const _BreathingHalo({required this.pulse});

  final AnimationController pulse;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: AnimatedBuilder(
        animation: pulse,
        builder: (context, _) {
          final t = (pulse.value * 2.0) % 1.0;
          return Center(
            child: Container(
              width: 120 + 36 * t,
              height: 120 + 36 * t,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.28 * (1 - t)),
                  width: 1.6,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CustomSplashImageLayer extends StatelessWidget {
  const _CustomSplashImageLayer();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      mkwMobileSplashImageAsset,
      fit: _imageFit,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      filterQuality: FilterQuality.high,
      errorBuilder: (context, error, stackTrace) => const _DefaultSplashLayer(),
    );
  }

  static BoxFit get _imageFit {
    switch (mkwMobileSplashImageFit.trim().toLowerCase()) {
      case 'contain':
        return BoxFit.contain;
      case 'fill':
        return BoxFit.fill;
      case 'fitwidth':
      case 'fit_width':
        return BoxFit.fitWidth;
      case 'fitheight':
      case 'fit_height':
        return BoxFit.fitHeight;
      case 'none':
        return BoxFit.none;
      case 'scaledown':
      case 'scale_down':
        return BoxFit.scaleDown;
      case 'cover':
      default:
        return BoxFit.cover;
    }
  }
}

class _SplashToneOverlay extends StatelessWidget {
  const _SplashToneOverlay();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.10),
            Colors.black.withValues(alpha: 0.00),
            Colors.black.withValues(alpha: 0.48),
          ],
          stops: const [0.0, 0.48, 1.0],
        ),
      ),
    );
  }
}

class _DefaultSplashLayer extends StatelessWidget {
  const _DefaultSplashLayer();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF071126),
            Color(0xFF0E2A4F),
            Color(0xFF0B6B8C),
          ],
        ),
      ),
    );
  }
}

class _BottomStatusPill extends StatelessWidget {
  const _BottomStatusPill({
    required this.progress,
    required this.status,
    required this.hasError,
    required this.onRetry,
  });

  final double progress;
  final String status;
  final bool hasError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: hasError ? 0.52 : 0.36),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: hasError ? _buildErrorContent() : _buildLoadingContent(),
    );
  }

  Widget _buildLoadingContent() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: progress >= 0.98 ? null : progress.clamp(0.04, 0.98),
            valueColor: AlwaysStoppedAnimation<Color>(
              Colors.white.withValues(alpha: 0.94),
            ),
            backgroundColor: Colors.white.withValues(alpha: 0.18),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorContent() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onRetry,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              '重试',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopStartupBody extends StatelessWidget {
  const _DesktopStartupBody({
    required this.status,
    required this.errorText,
    required this.onRetry,
  });

  final String status;
  final String? errorText;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasError)
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Color(0xFFE5485D),
                    size: 44,
                  )
                else
                  const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  hasError ? errorText! : status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Color(0xFF1E88E5),
                  ),
                ),
                if (hasError) ...[
                  const SizedBox(height: 18),
                  FilledButton(onPressed: onRetry, child: const Text('重试')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
