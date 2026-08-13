import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:webview_flutter/webview_flutter.dart' as mobile;

bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux);

class AnnouncementDialog extends StatefulWidget {
  final String title;
  final String html;
  final String baseUrl;

  const AnnouncementDialog({
    super.key,
    required this.title,
    required this.html,
    required this.baseUrl,
  });

  static Future<void> show(
    BuildContext context, {
    required String title,
    required String html,
    required String baseUrl,
  }) async {
    if (html.trim().isEmpty) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => AnnouncementDialog(
        title: title,
        html: html,
        baseUrl: baseUrl,
      ),
    );
  }

  @override
  State<AnnouncementDialog> createState() => _AnnouncementDialogState();
}

class _AnnouncementDialogState extends State<AnnouncementDialog> {
  mobile.WebViewController? _mobileController;
  InAppWebViewController? _desktopController;
  Key _desktopKey = UniqueKey();
  bool _loading = true;

  @override
  void initState() {
    super.initState();

    if (!_isDesktop) {
      _mobileController = mobile.WebViewController()
        ..setJavaScriptMode(mobile.JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..setNavigationDelegate(
          mobile.NavigationDelegate(
            onPageFinished: (_) {
              if (mounted) setState(() => _loading = false);
            },
          ),
        );
    }

    // 首帧后再加载，确保能读取 Theme 决定明暗配色
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final origin = Uri.parse(widget.baseUrl).origin;
    final html = _wrapHtml(context, widget.html);

    if (!_isDesktop && _mobileController != null) {
      await _mobileController!.loadHtmlString(html, baseUrl: '$origin/');
    } else if (_isDesktop) {
      setState(() => _desktopKey = UniqueKey());
    }
  }

  String _wrapHtml(BuildContext context, String body) {
    final encodedTitle = const HtmlEscape().convert(widget.title);
    final dark = Theme.of(context).brightness == Brightness.dark;

    final fg = dark ? '#d1d5db' : '#334155';
    final heading = dark ? '#f1f5f9' : '#0f172a';
    final link = dark ? '#7cb8ff' : '#2563eb';
    final codeBg = dark ? 'rgba(255,255,255,.10)' : 'rgba(15,23,42,.06)';
    const border = 'rgba(148,163,184,.30)';

    return '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>$encodedTitle</title>
<style>
  html, body {
    margin: 0;
    padding: 0;
    background: transparent;
    color: $fg;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans SC", sans-serif;
    font-size: 15px;
    line-height: 1.7;
    overflow-wrap: anywhere;
    -webkit-font-smoothing: antialiased;
  }
  body {
    padding: 16px 18px 22px;
    box-sizing: border-box;
  }
  h1, h2, h3, h4, h5 {
    color: $heading;
    line-height: 1.4;
    margin: 0.7em 0 0.35em;
    font-weight: 700;
  }
  h1 { font-size: 1.4em; }
  h2 { font-size: 1.25em; }
  h3 { font-size: 1.12em; }
  p { margin: 0.5em 0; }
  img, video {
    max-width: 100% !important;
    height: auto !important;
    border-radius: 12px;
  }
  a {
    color: $link;
    text-decoration: none;
  }
  a:hover { text-decoration: underline; }
  blockquote {
    border-left: 3px solid $link;
    background: $codeBg;
    margin: 0.6em 0;
    padding: 8px 14px;
    border-radius: 8px;
  }
  code {
    background: $codeBg;
    padding: 1px 6px;
    border-radius: 5px;
    font-size: 0.9em;
  }
  pre {
    background: $codeBg;
    padding: 12px 14px;
    border-radius: 10px;
    overflow: auto;
  }
  pre code { background: transparent; padding: 0; }
  table {
    width: 100%;
    border-collapse: collapse;
    margin: 0.6em 0;
    font-size: 0.95em;
  }
  th, td {
    border: 1px solid $border;
    padding: 7px 10px;
    text-align: left;
  }
  th { background: $codeBg; font-weight: 600; }
  ul, ol { margin: 0.4em 0; padding-left: 1.4em; }
  li { margin: 0.2em 0; }
  hr {
    border: none;
    border-top: 1px solid $border;
    margin: 14px 0;
  }
  fieldset, section, div {
    max-width: 100% !important;
    box-sizing: border-box !important;
  }
</style>
</head>
<body>
$body
</body>
</html>
''';
  }

  Widget _buildDesktopWebView() {
    final origin = Uri.parse(widget.baseUrl).origin;
    final html = _wrapHtml(context, widget.html);

    return InAppWebView(
      key: _desktopKey,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        supportZoom: false,
      ),
      onWebViewCreated: (controller) {
        _desktopController = controller;
        controller.loadData(
          data: html,
          mimeType: 'text/html',
          encoding: 'utf-8',
          baseUrl: WebUri('$origin/'),
        );
      },
      onLoadStop: (controller, url) {
        if (mounted) setState(() => _loading = false);
      },
      onReceivedError: (controller, request, error) {
        if (mounted) setState(() => _loading = false);
      },
    );
  }

  @override
  void dispose() {
    _desktopController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 44,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(theme, colorScheme),
            SizedBox(
              width: double.infinity,
              height: MediaQuery.of(context).size.height * 0.66,
              child: Stack(
                children: [
                  _isDesktop
                      ? _buildDesktopWebView()
                      : mobile.WebViewWidget(controller: _mobileController!),
                  if (_loading)
                    Container(
                      color: colorScheme.surface,
                      alignment: Alignment.center,
                      child: const CircularProgressIndicator(),
                    ),
                ],
              ),
            ),
            _buildFooter(theme, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary.withValues(alpha: 0.14),
            colorScheme.surface,
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.35),
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.campaign_outlined,
              size: 20,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.close, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.35),
          ),
        ),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: FilledButton(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('我知道了'),
        ),
      ),
    );
  }
}
