import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/cast_media.dart';
import 'package:duanju_app/cast_media_server.dart';
import 'package:duanju_app/dlna_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _description = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <URLBase>http://192.168.1.20:49152/</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>客厅电视 &amp; 盒子</friendlyName>
    <manufacturer>Example</manufacturer>
    <modelName>TV-1</modelName>
    <UDN>uuid:renderer-1</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/upnp/control/RenderingControl</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>upnp/control/AVTransport</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

Future<HttpClientResponse> _get(
  HttpClient client,
  String url, {
  String? range,
  String method = 'GET',
}) async {
  final request = await client.openUrl(method, Uri.parse(url));
  if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
  return request.close();
}

void main() {
  test('parses renderer description and resolves control URLs', () {
    final device = parseDlnaDescription(
      _description,
      Uri.parse('http://192.168.1.20:49152/description.xml'),
    )!;
    expect(device.id, 'uuid:renderer-1');
    expect(device.name, '客厅电视 & 盒子');
    expect(device.subtitle, 'Example · TV-1 · 192.168.1.20');
    expect(
      device.avTransport.controlUrl.toString(),
      'http://192.168.1.20:49152/upnp/control/AVTransport',
    );
    expect(
      device.renderingControl!.controlUrl.toString(),
      'http://192.168.1.20:49152/upnp/control/RenderingControl',
    );
    expect(
      parseDlnaDescription(
        '<root><device><friendlyName>NAS</friendlyName></device></root>',
        Uri.parse('http://192.168.1.2/desc.xml'),
      ),
      isNull,
    );
  });

  test('formats and parses DLNA times and SSDP headers', () {
    expect(formatDlnaTime(const Duration(seconds: 3725)), '01:02:05');
    expect(formatDlnaTime(const Duration(seconds: -3)), '00:00:00');
    expect(
      parseDlnaTime('0:01:30.500'),
      const Duration(seconds: 90, milliseconds: 500),
    );
    expect(parseDlnaTime('NOT_IMPLEMENTED'), isNull);
    expect(
      ssdpHeader(
        'HTTP/1.1 200 OK\r\nCache-Control: max-age=1800\r\nLocation: http://10.0.0.5:1400/xml\r\n\r\n',
        'LOCATION',
      ),
      'http://10.0.0.5:1400/xml',
    );
    final metadata = dlnaMetadata(
      url: 'http://10.0.0.2:1/cast/a/b.mp4?x=1&y=2',
      title: '<剧> 第 1 集',
      mime: 'video/mp4',
    );
    expect(metadata, contains('&lt;剧&gt; 第 1 集'));
    expect(metadata, contains('b.mp4?x=1&amp;y=2'));
    expect(metadata, contains('http-get:*:video/mp4:DLNA.ORG_OP=01'));
  });

  test('controls renderer through SOAP actions', () async {
    final actions = <String>[];
    final bodies = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final action = request.headers.value('soapaction') ?? '';
      final body = await utf8.decoder.bind(request).join();
      actions.add(action);
      bodies.add(body);
      final response = request.response;
      if (action.endsWith('#GetPositionInfo"')) {
        response.write(
          '<s:Envelope><s:Body><u:GetPositionInfoResponse>'
          '<TrackDuration>0:02:00</TrackDuration><RelTime>0:00:42</RelTime>'
          '</u:GetPositionInfoResponse></s:Body></s:Envelope>',
        );
      } else if (action.endsWith('#GetTransportInfo"')) {
        response.write(
          '<s:Envelope><s:Body><u:GetTransportInfoResponse>'
          '<CurrentTransportState>PLAYING</CurrentTransportState>'
          '</u:GetTransportInfoResponse></s:Body></s:Envelope>',
        );
      } else if (action.endsWith('#Seek"') && body.contains('99:00:00')) {
        response.statusCode = 500;
        response.write(
          '<s:Envelope><s:Body><s:Fault><detail><UPnPError>'
          '<errorCode>711</errorCode><errorDescription>Illegal seek target</errorDescription>'
          '</UPnPError></detail></s:Fault></s:Body></s:Envelope>',
        );
      } else {
        response.write('<s:Envelope><s:Body/></s:Envelope>');
      }
      await response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final renderer = DlnaRenderer(
      DlnaDevice(
        id: 'uuid:test',
        name: 'Test',
        location: Uri.parse('$base/desc.xml'),
        avTransport: DlnaService(
          type: 'urn:schemas-upnp-org:service:AVTransport:1',
          controlUrl: Uri.parse('$base/avt'),
        ),
      ),
    );
    try {
      await renderer.setUri(
        'http://10.0.0.2:8000/cast/t/a.mp4',
        title: '测试',
        mime: 'video/mp4',
      );
      await renderer.play();
      await renderer.seek(const Duration(seconds: 75));
      final position = await renderer.position();
      expect(position.position, const Duration(seconds: 42));
      expect(position.duration, const Duration(minutes: 2));
      expect(await renderer.transportState(), DlnaTransportState.playing);
      await expectLater(
        renderer.seek(const Duration(hours: 99)),
        throwsA(
          isA<DlnaException>().having(
            (error) => error.message,
            'message',
            contains('711'),
          ),
        ),
      );
      expect(
        actions.first,
        '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"',
      );
      expect(
        bodies.first,
        contains('<CurrentURI>http://10.0.0.2:8000/cast/t/a.mp4</CurrentURI>'),
      );
      expect(bodies.first, contains('&lt;DIDL-Lite'));
      expect(bodies[2], contains('<Target>00:01:15</Target>'));
      expect(renderer.supportsVolume, isFalse);
    } finally {
      renderer.close();
      await server.close(force: true);
    }
  });

  test('serves local files with byte ranges over the cast server', () async {
    final directory = await Directory.systemTemp.createTemp('cast_test');
    final file = File('${directory.path}${Platform.pathSeparator}episode.mp4');
    await file.writeAsBytes(List.generate(1000, (index) => index % 256));
    final server = CastMediaServer.instance;
    final link = await server.publishFile(file, '127.0.0.1');
    final client = HttpClient();
    try {
      expect(link.mime, 'video/mp4');
      final full = await _get(client, link.url);
      expect(full.statusCode, 200);
      expect(full.headers.value('transferMode.dlna.org'), 'Streaming');
      expect((await full.expand((chunk) => chunk).toList()).length, 1000);
      final partial = await _get(client, link.url, range: 'bytes=10-19');
      expect(partial.statusCode, 206);
      expect(partial.headers.value('content-range'), 'bytes 10-19/1000');
      expect(
        await partial.expand((chunk) => chunk).toList(),
        List.generate(10, (index) => index + 10),
      );
      final suffix = await _get(client, link.url, range: 'bytes=-5');
      expect(suffix.headers.value('content-range'), 'bytes 995-999/1000');
      await suffix.drain<void>();
      final invalid = await _get(client, link.url, range: 'bytes=2000-');
      expect(invalid.statusCode, 416);
      await invalid.drain<void>();
      final other = await _get(
        client,
        link.url.replaceFirst('episode.mp4', 'other.mp4'),
      );
      expect(other.statusCode, 404);
      await other.drain<void>();
      await server.release(link.token);
      final gone = await _get(client, link.url)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => throw const SocketException('closed'),
          )
          .then<int>((response) async {
            await response.drain<void>();
            return response.statusCode;
          })
          .catchError((_) => 0);
      expect(gone, anyOf(0, 410));
    } finally {
      client.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test('proxies loopback playback streams and rewrites playlists', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = 'http://127.0.0.1:${upstream.port}/session';
    final ranges = <String?>[];
    upstream.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/session/index.m3u8') {
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        response.write(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="$origin/key.key"\n#EXTINF:4,\n$origin/seg.ts\n#EXT-X-ENDLIST\n',
        );
      } else if (request.uri.path == '/session/seg.ts') {
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        response.statusCode = 206;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-3/4');
        response.headers.contentType = ContentType('video', 'mp2t');
        response.contentLength = 4;
        response.add([1, 2, 3, 4]);
      } else {
        response.statusCode = 404;
      }
      await response.close();
    });
    final server = CastMediaServer.instance;
    final link = await server.publishProxy(
      Uri.parse('$origin/index.m3u8'),
      '127.0.0.1',
    );
    final client = HttpClient();
    try {
      expect(link.mime, castPlaylistMime);
      final playlist = await _get(client, link.url);
      expect(playlist.statusCode, 200);
      final body = await utf8.decoder.bind(playlist).join();
      final public = link.url.substring(0, link.url.lastIndexOf('/') + 1);
      expect(body, isNot(contains(origin)));
      expect(body, contains('URI="${public}key.key"'));
      expect(body, contains('${public}seg.ts'));
      final segment = await _get(client, '${public}seg.ts', range: 'bytes=0-3');
      expect(segment.statusCode, 206);
      expect(segment.headers.value('content-range'), 'bytes 0-3/4');
      expect(await segment.expand((chunk) => chunk).toList(), [1, 2, 3, 4]);
      expect(ranges, ['bytes=0-3']);
      final escape = await _get(client, '$public..');
      expect(escape.statusCode, anyOf(404, 410));
      await escape.drain<void>();
    } finally {
      client.close(force: true);
      await server.release(link.token);
      await upstream.close(force: true);
    }
  });

  test('rewrites only the published playback origin', () {
    expect(
      rewriteCastPlaylist(
        '#EXTM3U\nhttp://127.0.0.1:1/a/x.ts\nhttp://127.0.0.1:1/b/y.ts',
        'http://127.0.0.1:1/a/',
        'http://192.168.1.3:9/cast/t/',
      ),
      '#EXTM3U\nhttp://192.168.1.3:9/cast/t/x.ts\nhttp://127.0.0.1:1/b/y.ts',
    );
    expect(castMimeForName('a.TS'), 'video/mp2t');
    expect(castMimeForName('index.m3u8'), castPlaylistMime);
    expect(normalizeCastContentType('seg.ts', 'image/jpeg'), 'video/mp2t');
    expect(
      normalizeCastContentType('video.mp4', 'application/octet-stream'),
      'video/mp4',
    );
  });

  test('excludes VPN and virtual adapters when choosing LAN address', () {
    final interfaces = <CastNetInterface>[
      (name: 'tun0', address: '172.19.0.1'),
      (name: 'Meta', address: '198.18.0.1'),
      (name: 'rmnet_data0', address: '10.8.0.2'),
      (name: 'VirtualBox Host-Only Network', address: '192.168.56.1'),
      (name: 'vEthernet (WSL)', address: '172.24.16.1'),
      (name: 'wlan0', address: '192.168.1.50'),
      (name: 'eth0', address: '192.168.2.10'),
    ];
    expect(
      selectCastLanAddress(
        '192.168.1.20',
        interfaces,
        socketAddress: '172.19.0.1',
      ),
      '192.168.1.50',
    );
    expect(
      rankCastLanAddresses(
        '192.168.1.20',
        interfaces,
        socketAddress: '198.18.0.1',
      ),
      ['192.168.1.50', '192.168.2.10'],
    );
    expect(
      selectCastLanAddress('192.168.43.88', const [
        (name: 'rmnet0', address: '100.72.1.9'),
        (name: 'ap0', address: '192.168.43.1'),
      ], socketAddress: '100.72.1.9'),
      '192.168.43.1',
    );
  });

  test('preserves cast server port when Host header omits port', () {
    expect(
      castAuthorityForRequest('192.168.1.50', '192.168.1.50:54321', 54321),
      '192.168.1.50:54321',
    );
    expect(
      castAuthorityForRequest(
        '192.168.1.50:54321',
        '192.168.1.50:54321',
        54321,
      ),
      '192.168.1.50:54321',
    );
    expect(
      castAuthorityForRequest('127.0.0.1', '192.168.1.50:54321', 54321),
      '192.168.1.50:54321',
    );
  });

  test(
    'handles portless Host, HEAD probes, extensionless HLS, and disguised TS',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${upstream.port}/session';
      final methods = <String>[];
      upstream.listen((request) async {
        methods.add('${request.method}:${request.uri.path}');
        final response = request.response;
        if (request.method == 'HEAD') {
          response.statusCode = HttpStatus.forbidden;
          await response.close();
          return;
        }
        if (request.uri.path == '/session/stream.mp4') {
          response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          response.write(
            '#EXTM3U\n#EXTINF:4,\n$origin/disguised.ts\n#EXT-X-ENDLIST\n',
          );
        } else if (request.uri.path == '/session/disguised.ts') {
          final range = request.headers.value(HttpHeaders.rangeHeader);
          response.headers.set(HttpHeaders.contentTypeHeader, 'image/jpeg');
          if (range == 'bytes=0-0') {
            response.statusCode = HttpStatus.partialContent;
            response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/6');
            response.contentLength = 1;
            response.add([9]);
          } else {
            response.contentLength = 6;
            response.add([9, 8, 7, 6, 5, 4]);
          }
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
      final server = CastMediaServer.instance;
      final link = await server.publishProxy(
        Uri.parse('$origin/stream.mp4'),
        '127.0.0.1',
        overrideName: 'index.m3u8',
      );
      final parsedLink = Uri.parse(link.url);
      final client = HttpClient();
      try {
        expect(link.url, endsWith('/index.m3u8'));
        expect(link.mime, castPlaylistMime);
        final rawSocket = await Socket.connect('127.0.0.1', parsedLink.port);
        rawSocket.write(
          'GET ${parsedLink.path} HTTP/1.1\r\n'
          'Host: 127.0.0.1\r\n'
          'Connection: close\r\n\r\n',
        );
        final rawReply = await utf8.decoder.bind(rawSocket).join();
        expect(
          rawReply,
          contains(
            'http://127.0.0.1:${parsedLink.port}/cast/${link.token}/disguised.ts',
          ),
        );
        expect(rawReply, isNot(contains('127.0.0.1:80/')));

        final publicBase = link.url.substring(0, link.url.lastIndexOf('/') + 1);
        final headSeg = await _get(
          client,
          '${publicBase}disguised.ts',
          method: 'HEAD',
        );
        expect(headSeg.statusCode, HttpStatus.ok);
        expect(
          headSeg.headers.value(HttpHeaders.contentTypeHeader),
          'video/mp2t',
        );
        expect(headSeg.contentLength, 6);
        await headSeg.drain<void>();

        final getSeg = await _get(client, '${publicBase}disguised.ts');
        expect(getSeg.statusCode, HttpStatus.ok);
        expect(
          getSeg.headers.value(HttpHeaders.contentTypeHeader),
          'video/mp2t',
        );
        expect(await getSeg.expand((chunk) => chunk).toList(), [
          9,
          8,
          7,
          6,
          5,
          4,
        ]);

        expect(methods.where((entry) => entry.startsWith('HEAD:')), isEmpty);
        final stats = server.statsFor(link.token);
        expect(stats.requests, 3);
        expect(stats.bytes, greaterThan(6));
      } finally {
        client.close(force: true);
        await server.release(link.token);
        await upstream.close(force: true);
      }
    },
  );

  test(
    'prunes old remuxed cache files while preserving active, next, and partial files',
    () async {
      final directory = await Directory.systemTemp.createTemp('cast_prune_');
      try {
        final now = DateTime.now();
        Future<File> makeFile(String name, int ageSeconds) async {
          final file = File('${directory.path}/$name');
          await file.writeAsBytes(const [1, 2, 3, 4]);
          await file.setLastModified(
            now.subtract(Duration(seconds: ageSeconds)),
          );
          return file;
        }

        final active = await makeFile('active.mp4', 500);
        final next = await makeFile('next.mp4', 400);
        final partial = await makeFile('building.part.mp4', 600);
        final recent1 = await makeFile('recent1.mp4', 10);
        final recent2 = await makeFile('recent2.mp4', 20);
        final stale1 = await makeFile('stale1.mp4', 200);
        final stale2 = await makeFile('stale2.mp4', 300);

        await CastMediaPreparer.pruneCache(
          keepPaths: {active.path, next.path},
          maxFiles: 2,
          directory: directory,
        );

        expect(await active.exists(), isTrue);
        expect(await next.exists(), isTrue);
        expect(await partial.exists(), isTrue);
        expect(await recent1.exists(), isTrue);
        expect(await recent2.exists(), isTrue);
        expect(await stale1.exists(), isFalse);
        expect(await stale2.exists(), isFalse);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
