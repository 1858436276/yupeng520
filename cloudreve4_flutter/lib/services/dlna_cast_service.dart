import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

/// DLNA 投屏设备（局域网内的电视/盒子/投影仪）
class CastDevice {
  final String friendlyName;
  final String location;
  final String? avTransportUrl;
  final String? renderingControlUrl;

  const CastDevice({
    required this.friendlyName,
    required this.location,
    this.avTransportUrl,
    this.renderingControlUrl,
  });

  @override
  String toString() => '$friendlyName ($location)';
}

/// DLNA 投屏服务：SSDP 发现 + UPnP AVTransport 控制。
///
/// - 仅依赖 `dart:io` + `xml`，无需 platform channel；
/// - 使用 M-SEARCH 单播响应机制，无需申请 Android MulticastLock；
/// - iOS 需在 Info.plist 中配置 NSLocalNetworkUsageDescription。
class DlnaCastService {
  DlnaCastService._();

  static final DlnaCastService instance = DlnaCastService._();

  static const _ssdpAddress = '239.255.255.250';
  static const _ssdpPort = 1900;

  /// 局域网搜索可投屏设备
  Future<List<CastDevice>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final devices = <CastDevice>[];
    final seen = <String>{};
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;
    final completer = Completer<List<CastDevice>>();

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      // MediaRenderer 即能播放音视频的 DLNA 设备
      const searchTarget = 'urn:schemas-upnp-org:device:MediaRenderer:1';
      final message = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: $_ssdpAddress:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 3\r\n'
          'ST: $searchTarget\r\n'
          'USER-AGENT: Flutter-DLNA/1.0 UPnP/1.1\r\n'
          '\r\n';
      final data = utf8.encode(message);

      // 发两次提高成功率，规避丢包
      for (var i = 0; i < 2; i++) {
        socket.send(data, InternetAddress(_ssdpAddress), _ssdpPort);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        try {
          final text = utf8.decode(datagram.data, allowMalformed: true);
          final location = RegExp(
            r'LOCATION:\s*(\S+)',
            caseSensitive: false,
          ).firstMatch(text)?.group(1);
          if (location == null || !seen.add(location)) return;
          _fetchDevice(location).then((device) {
            if (device != null) devices.add(device);
          });
        } catch (_) {}
      });

      Timer(timeout, () {
        sub?.cancel();
        socket?.close();
        // 给设备描述文件拉取留一点余量
        Future<void>.delayed(const Duration(milliseconds: 400), () {
          if (!completer.isCompleted) completer.complete(devices);
        });
      });
    } catch (e) {
      sub?.cancel();
      socket?.close();
      if (!completer.isCompleted) completer.completeError(e);
    }

    return completer.future;
  }

  /// 拉取设备描述文件，解析 AVTransport 控制地址
  Future<CastDevice?> _fetchDevice(String location) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(Uri.parse(location));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      final doc = XmlDocument.parse(body);
      final friendlyName =
          doc.findAllElements('friendlyName').firstOrNull?.innerText.trim() ??
              '未知设备';

      final base = Uri.parse(location);
      final baseUrl = '${base.scheme}://${base.host}:${base.port}';
      String? avTransport;
      String? renderingControl;

      for (final service in doc.findAllElements('service')) {
        final type =
            service.findElements('serviceType').firstOrNull?.innerText.trim() ??
                '';
        final path =
            service.findElements('controlURL').firstOrNull?.innerText.trim();
        if (path == null || path.isEmpty) continue;
        final url = path.startsWith('http')
            ? path
            : '$baseUrl${path.startsWith('/') ? '' : '/'}$path';
        if (type.contains('AVTransport')) avTransport = url;
        if (type.contains('RenderingControl')) renderingControl = url;
      }
      if (avTransport == null) return null;

      return CastDevice(
        friendlyName: friendlyName,
        location: location,
        avTransportUrl: avTransport,
        renderingControlUrl: renderingControl,
      );
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 投屏播放（推送 URL 并立即播放）
  Future<void> castUrl(CastDevice device, String url, {String? title}) async {
    final controlUrl = device.avTransportUrl;
    if (controlUrl == null) throw Exception('设备不支持 AVTransport');

    final metadata = _buildMetadata(url, title ?? '');
    await _soap(controlUrl, 'SetAVTransportURI', '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>${_escapeXml(url)}</CurrentURI>
      <CurrentURIMetaData>${_escapeXml(metadata)}</CurrentURIMetaData>
    </u:SetAVTransportURI>
  </s:Body>
</s:Envelope>''');

    await play(device);
  }

  /// 恢复/开始播放
  Future<void> play(CastDevice device) async {
    final controlUrl = device.avTransportUrl;
    if (controlUrl == null) return;
    await _soap(controlUrl, 'Play', '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Speed>1</Speed>
    </u:Play>
  </s:Body>
</s:Envelope>''');
  }

  /// 暂停
  Future<void> pause(CastDevice device) async {
    final controlUrl = device.avTransportUrl;
    if (controlUrl == null) return;
    await _soap(controlUrl, 'Pause', '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Pause>
  </s:Body>
</s:Envelope>''');
  }

  /// 停止
  Future<void> stop(CastDevice device) async {
    final controlUrl = device.avTransportUrl;
    if (controlUrl == null) return;
    await _soap(controlUrl, 'Stop', '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Stop>
  </s:Body>
</s:Envelope>''');
  }

  /// 跳转进度
  Future<void> seek(CastDevice device, Duration position) async {
    final controlUrl = device.avTransportUrl;
    if (controlUrl == null) return;
    await _soap(controlUrl, 'Seek', '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Unit>REL_TIME</Unit>
      <Target>${_formatHms(position)}</Target>
    </u:Seek>
  </s:Body>
</s:Envelope>''');
  }

  String _formatHms(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
  }

  String _buildMetadata(String url, String title) {
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>${_escapeXml(title)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:video/*:*">${_escapeXml(url)}</res>'
        '</item></DIDL-Lite>';
  }

  String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<void> _soap(String url, String action, String body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set(
        'SOAPAction',
        '"urn:schemas-upnp-org:service:AVTransport:1#$action"',
      );
      req.write(body);
      final resp = await req.close();
      if (resp.statusCode != 200) {
        final err = await resp.transform(utf8.decoder).join();
        throw Exception('SOAP $action 失败 (${resp.statusCode}): $err');
      }
    } finally {
      client.close();
    }
  }
}