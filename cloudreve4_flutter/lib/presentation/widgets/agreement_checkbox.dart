import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'agreement_content.dart';

/// 协议类型。
enum AgreementKind { userAgreement, privacyPolicy }

/// 登录/注册页面的"用户协议 + 隐私协议"勾选组件。
///
/// 点击协议名称时：
/// - 若服务端配置了对应 URL（tosUrl / privacyPolicyUrl），用系统浏览器打开；
/// - 否则展示内置的协议文本对话框。
class AgreementCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? tosUrl;
  final String? privacyPolicyUrl;
  final TextStyle? textStyle;

  const AgreementCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.tosUrl,
    this.privacyPolicyUrl,
    this.textStyle,
  });

  Future<void> _openAgreement(BuildContext context, AgreementKind kind) async {
    final url = switch (kind) {
      AgreementKind.userAgreement => tosUrl,
      AgreementKind.privacyPolicy => privacyPolicyUrl,
    };

    final trimmed = url?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (ok) return;
      }
    }

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AgreementContentDialog(kind: kind),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle = textStyle ??
        theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );

    final linkStyle = baseStyle?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 22,
          height: 22,
          child: Checkbox(
            value: value,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) => onChanged(v ?? false),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text.rich(
              TextSpan(
                style: baseStyle,
                children: [
                  const TextSpan(text: '我已阅读并同意'),
                  TextSpan(
                    text: '《用户协议》',
                    style: linkStyle,
                    recognizer: TapGestureRecognizer()
                      ..onTap = () =>
                          _openAgreement(context, AgreementKind.userAgreement),
                  ),
                  const TextSpan(text: '和'),
                  TextSpan(
                    text: '《隐私协议》',
                    style: linkStyle,
                    recognizer: TapGestureRecognizer()
                      ..onTap = () =>
                          _openAgreement(context, AgreementKind.privacyPolicy),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 展示内置协议文本的对话框。
class AgreementContentDialog extends StatelessWidget {
  final AgreementKind kind;

  const AgreementContentDialog({super.key, required this.kind});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = kind == AgreementKind.userAgreement
        ? AgreementContent.userAgreementTitle
        : AgreementContent.privacyPolicyTitle;
    final content = kind == AgreementKind.userAgreement
        ? AgreementContent.userAgreement
        : AgreementContent.privacyPolicy;

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 480,
        height: 400,
        child: SingleChildScrollView(
          child: Text(
            content,
            style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
