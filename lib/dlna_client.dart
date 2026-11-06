import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_device.dart';

class DlnaException implements Exception {
  DlnaException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DlnaService {
  const DlnaService({required this.type, required this.controlUrl});
  final String type;
  final Uri controlUrl;
}

class DlnaDevice {
  const DlnaDevice({
    required this.id,
    required this.name,
    required this.location,
    required this.avTransport,
    this.renderingControl,
    this.manufacturer = '',
    this.model = '',
  });

  final String id;
  final String name;
  final Uri location;
  final DlnaService avTransport;
  final DlnaService? renderingControl;
  final String manufacturer;
  final String model;

  String get host => location.host;
  int get port => location.hasPort ? location.port : 80;
  String get subtitle => [
    manufacturer,
    model,
    host,
  ].where((value) => value.isNotEmpty).join(' · ');
}

class DlnaPosition {
  const DlnaPosition({required this.position, required this.duration});
  final Duration position;
  final Duration duration;
}

class DlnaTransportState {
  static const playing = 'PLAYING';
  static const paused = 'PAUSED_PLAYBACK';
  static const stopped = 'STOPPED';
  static const transitioning = 'TRANSITIONING';
  static const noMedia = 'NO_MEDIA_PRESENT';
}

const _avTransportPrefix = 'urn:schemas-upnp-org:service:AVTransport:';
const _renderingControlPrefix =
    'urn:schemas-upnp-org:service:RenderingControl:';
const _ssdpAddress = '239.255.255.250';
const _ssdpPort = 1900;
const _ssdpTargets = [
  'urn:schemas-upnp-org:device:MediaRenderer:1',
  'urn:schemas-upnp-org:service:AVTransport:1',
  'ssdp:all',
];
const _userAgent = 'ZhenGuoJian/1.0 UPnP/1.0 DLNADOC/1.50';

String xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String xmlUnescape(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

RegExp _xmlElement(String tag) => RegExp(
  '<(?:[A-Za-z0-9_.-]+:)?$tag(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[A-Za-z0-9_.-]+:)?$tag\\s*>',
);

String xmlText(String xml, String tag) {
  final match = _xmlElement(tag).firstMatch(xml);
  return match == null ? '' : xmlUnescape(match.group(1)!.trim());
}

List<String> xmlBlocks(String xml, String tag) =>
    _xmlElement(tag).allMatches(xml).map((match) => match.group(1)!).toList();

String? ssdpHeader(String message, String name) {
  final lower = name.toLowerCase();
  for (final line in const LineSplitter().convert(message)) {
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    if (line.substring(0, separator).trim().toLowerCase() == lower) {
      return line.substring(separator + 1).trim();
    }
  }
  return null;
}

DlnaDevice? parseDlnaDescription(String xml, Uri location) {
  DlnaService? avTransport;
  DlnaService? renderingControl;
  final declaredBase = xmlText(xml, 'URLBase');
  final base = Uri.tryParse(declaredBase)?.hasScheme == true
      ? Uri.parse(declaredBase)
      : location;
  for (final block in xmlBlocks(xml, 'service')) {
    final type = xmlText(block, 'serviceType');
    final control = xmlText(block, 'controlURL');
    if (type.isEmpty || control.isEmpty) continue;
    final Uri controlUrl;
    try {
      controlUrl = base.resolve(control);
    } catch (_) {
      continue;
    }
    if (controlUrl.scheme != 'http') continue;
    if (avTransport == null && type.startsWith(_avTransportPrefix)) {
      avTransport = DlnaService(type: type, controlUrl: controlUrl);
    } else if (renderingControl == null &&
        type.startsWith(_renderingControlPrefix)) {
      renderingControl = DlnaService(type: type, controlUrl: controlUrl);
    }
  }
  if (avTransport == null) return null;
  final name = xmlText(xml, 'friendlyName');
  final udn = xmlText(xml, 'UDN');
  return DlnaDevice(
    id: udn.isNotEmpty ? udn : location.toString(),
    name: name.isNotEmpty ? name : location.host,
    location: location,
    avTransport: avTransport,
    renderingControl: renderingControl,
    manufacturer: xmlText(xml, 'manufacturer'),
    model: xmlText(xml, 'modelName'),
  );
}

String formatDlnaTime(Duration value) {
  final seconds = value.isNegative ? 0 : value.inSeconds;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final rest = seconds % 60;
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(hours)}:${two(minutes)}:${two(rest)}';
}

Duration? parseDlnaTime(String value) {
  final match = RegExp(
    r'^\s*(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d+))?',
  ).firstMatch(value);
  if (match == null) return null;
  final fraction = match.group(4) ?? '';
  final milliseconds = fraction.isEmpty
      ? 0
      : int.parse(fraction.padRight(3, '0').substring(0, 3));
  return Duration(
    hours: int.parse(match.group(1)!),
    minutes: int.parse(match.group(2)!),
    seconds: int.parse(match.group(3)!),
    milliseconds: milliseconds,
  );
}

String dlnaProtocolInfo(String mime) {
  final flags = mime.contains('mpegurl')
      ? 'DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000'
      : 'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';
  return 'http-get:*:$mime:$flags';
}

String dlnaMetadata({
  required String url,
  required String title,
  required String mime,
}) =>
    '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
    'xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
    '<item id="0" parentID="-1" restricted="1">'
    '<dc:title>${xmlEscape(title)}</dc:title>'
    '<upnp:class>object.item.videoItem.movie</upnp:class>'
    '<res protocolInfo="${xmlEscape(dlnaProtocolInfo(mime))}">${xmlEscape(url)}</res>'
    '</item></DIDL-Lite>';

HttpClient _directClient() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 4)
  ..idleTimeout = const Duration(seconds: 10)
  ..findProxy = (_) => 'DIRECT';

class DlnaDiscovery {
  Future<void> search({
    required void Function(DlnaDevice device) onDevice,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final sockets = <RawDatagramSocket>[];
    final locations = <String>{};
    final devices = <String>{};
    final pending = <Future<void>>[];
    final client = _directClient();
    var open = true;

    void receive(RawDatagramSocket socket) {
      Datagram? datagram;
      while (open && (datagram = socket.receive()) != null) {
        final message = utf8.decode(datagram!.data, allowMalformed: true);
        final location = ssdpHeader(message, 'location');
        if (location == null || !locations.add(location)) continue;
        final uri = Uri.tryParse(location);
        if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) continue;
        pending.add(
          _describe(client, uri).then((device) {
            if (open && device != null && devices.add(device.id)) {
              onDevice(device);
            }
          }, onError: (_) {}),
        );
      }
    }

    try {
      final addresses = <InternetAddress>[InternetAddress.anyIPv4];
      final seenAddresses = <String>{InternetAddress.anyIPv4.address};
      for (final entry in await AppDevice.lanAddresses()) {
        final parsed = InternetAddress.tryParse(entry.address);
        if (parsed != null &&
            parsed.type == InternetAddressType.IPv4 &&
            !parsed.isLoopback &&
            !parsed.isLinkLocal &&
            seenAddresses.add(parsed.address)) {
          addresses.add(parsed);
        }
      }
      try {
        for (final network in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        )) {
          for (final address in network.addresses) {
            if (!address.isLoopback &&
                !address.isLinkLocal &&
                seenAddresses.add(address.address)) {
              addresses.add(address);
            }
          }
        }
      } catch (_) {}
      for (final address in addresses) {
        try {
          final socket = await RawDatagramSocket.bind(address, 0);
          try {
            socket.multicastHops = 4;
          } catch (_) {}
          socket.listen((event) {
            if (event == RawSocketEvent.read) receive(socket);
          });
          sockets.add(socket);
        } catch (_) {}
      }
      if (sockets.isEmpty) {
        throw DlnaException('无法打开局域网搜索端口，请确认已连接 Wi-Fi 或有线网络');
      }
      final target = InternetAddress(_ssdpAddress);
      final started = DateTime.now();
      for (var round = 0; round < 3; round++) {
        for (final searchTarget in _ssdpTargets) {
          if (round > 0 && searchTarget == 'ssdp:all') continue;
          final payload = utf8.encode(
            'M-SEARCH * HTTP/1.1\r\n'
            'HOST: $_ssdpAddress:$_ssdpPort\r\n'
            'MAN: "ssdp:discover"\r\n'
            'MX: 2\r\n'
            'ST: $searchTarget\r\n'
            'USER-AGENT: $_userAgent\r\n'
            '\r\n',
          );
          for (final socket in sockets) {
            try {
              socket.send(payload, target, _ssdpPort);
            } catch (_) {}
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      final remaining = timeout - DateTime.now().difference(started);
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    } finally {
      open = false;
      for (final socket in sockets) {
        socket.close();
      }
      try {
        await Future.wait(
          List<Future<void>>.of(pending),
        ).timeout(const Duration(seconds: 4));
      } catch (_) {}
      client.close(force: true);
    }
  }

  static Future<DlnaDevice?> describe(Uri location) async {
    final client = _directClient();
    try {
      return await _describe(client, location);
    } finally {
      client.close(force: true);
    }
  }

  static Future<DlnaDevice?> _describe(HttpClient client, Uri location) async {
    final request = await client
        .getUrl(location)
        .timeout(const Duration(seconds: 4));
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    final response = await request.close().timeout(const Duration(seconds: 4));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 6))) {
      bytes.addAll(chunk);
      if (bytes.length > 512 * 1024) return null;
    }
    return parseDlnaDescription(
      utf8.decode(bytes, allowMalformed: true),
      location,
    );
  }
}

class DlnaRenderer {
  DlnaRenderer(this.device) : _client = _directClient();

  final DlnaDevice device;
  final HttpClient _client;
  bool _closed = false;

  Future<String> _invoke(
    DlnaService service,
    String action,
    Map<String, String> arguments, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (_closed) throw DlnaException('投屏连接已关闭');
    final body = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">',
      )
      ..write('<s:Body><u:$action xmlns:u="${service.type}">');
    arguments.forEach((name, value) {
      body.write('<$name>${xmlEscape(value)}</$name>');
    });
    body.write('</u:$action></s:Body></s:Envelope>');
    final payload = utf8.encode(body.toString());
    try {
      final request = await _client
          .postUrl(service.controlUrl)
          .timeout(const Duration(seconds: 6));
      request.persistentConnection = false;
      request.headers
        ..set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"')
        ..set('SOAPACTION', '"${service.type}#$action"')
        ..set(HttpHeaders.userAgentHeader, _userAgent);
      request.contentLength = payload.length;
      request.add(payload);
      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder.bind(response).join().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        final code = xmlText(text, 'errorCode');
        final description = xmlText(text, 'errorDescription');
        throw DlnaException(
          '电视拒绝了「$action」请求'
          '${code.isEmpty ? '（HTTP ${response.statusCode}）' : '（错误 $code${description.isEmpty ? '' : ' $description'}）'}',
        );
      }
      return text;
    } on DlnaException {
      rethrow;
    } on TimeoutException {
      throw DlnaException('电视响应超时，请确认电视在线且与本机处于同一局域网');
    } on SocketException {
      throw DlnaException('无法连接电视，请确认电视在线且与本机处于同一局域网');
    } on HttpException {
      throw DlnaException('与电视通信失败，请重试');
    }
  }

  Future<void> setUri(
    String url, {
    required String title,
    required String mime,
  }) async {
    try {
      await _invoke(device.avTransport, 'SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': url,
        'CurrentURIMetaData': dlnaMetadata(url: url, title: title, mime: mime),
      }, timeout: const Duration(seconds: 15));
    } on DlnaException {
      await _invoke(device.avTransport, 'SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': url,
        'CurrentURIMetaData': '',
      }, timeout: const Duration(seconds: 15));
    }
  }

  Future<void> play() => _invoke(device.avTransport, 'Play', {
    'InstanceID': '0',
    'Speed': '1',
  }, timeout: const Duration(seconds: 15));

  Future<void> pause() =>
      _invoke(device.avTransport, 'Pause', {'InstanceID': '0'});

  Future<void> stop() =>
      _invoke(device.avTransport, 'Stop', {'InstanceID': '0'});

  Future<void> seek(Duration target) => _invoke(device.avTransport, 'Seek', {
    'InstanceID': '0',
    'Unit': 'REL_TIME',
    'Target': formatDlnaTime(target),
  });

  Future<DlnaPosition> position() async {
    final text = await _invoke(device.avTransport, 'GetPositionInfo', {
      'InstanceID': '0',
    });
    return DlnaPosition(
      position: parseDlnaTime(xmlText(text, 'RelTime')) ?? Duration.zero,
      duration: parseDlnaTime(xmlText(text, 'TrackDuration')) ?? Duration.zero,
    );
  }

  Future<String> transportState() async {
    final text = await _invoke(device.avTransport, 'GetTransportInfo', {
      'InstanceID': '0',
    });
    return xmlText(text, 'CurrentTransportState').toUpperCase();
  }

  bool get supportsVolume => device.renderingControl != null;

  Future<int?> volume() async {
    final service = device.renderingControl;
    if (service == null) return null;
    final text = await _invoke(service, 'GetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
    });
    return int.tryParse(xmlText(text, 'CurrentVolume'));
  }

  Future<void> setVolume(int value) async {
    final service = device.renderingControl;
    if (service == null) return;
    await _invoke(service, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '${value.clamp(0, 100)}',
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}
