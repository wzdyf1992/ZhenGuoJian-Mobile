import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

import 'app_device.dart';

const castPlaylistMime = 'application/vnd.apple.mpegurl';

typedef CastNetInterface = ({String name, String address});

class CastStats {
  const CastStats({
    this.requests = 0,
    this.bytes = 0,
    this.lastPath = '',
    this.lastStatus = 0,
  });

  final int requests;
  final int bytes;
  final String lastPath;
  final int lastStatus;
}

class _MutableCastStats {
  int requests = 0;
  int bytes = 0;
  String lastPath = '';
  int lastStatus = 0;

  CastStats snapshot() => CastStats(
    requests: requests,
    bytes: bytes,
    lastPath: lastPath,
    lastStatus: lastStatus,
  );
}

String castMimeForName(String name) =>
    switch (path.extension(name).toLowerCase()) {
      '.m3u8' => castPlaylistMime,
      '.ts' => 'video/mp2t',
      '.mp4' || '.m4s' || '.m4v' => 'video/mp4',
      '.mkv' => 'video/x-matroska',
      '.aac' => 'audio/aac',
      '.m4a' => 'audio/mp4',
      '.mp3' => 'audio/mpeg',
      '.vtt' || '.webvtt' => 'text/vtt',
      '.key' => 'application/octet-stream',
      _ => 'application/octet-stream',
    };

String normalizeCastContentType(String name, String upstreamContentType) {
  final ext = path.extension(name).toLowerCase();
  final lower = upstreamContentType.trim().toLowerCase();
  if (ext == '.m3u8' || lower.contains('mpegurl')) return castPlaylistMime;
  if (ext == '.ts') return 'video/mp2t';
  if (ext == '.key') return 'application/octet-stream';
  if (ext == '.mp4' || ext == '.m4s' || ext == '.m4v') {
    if (lower.startsWith('video/') || lower.startsWith('audio/')) {
      return upstreamContentType.trim();
    }
    return 'video/mp4';
  }
  if (upstreamContentType.trim().isNotEmpty) return upstreamContentType.trim();
  return castMimeForName(name);
}

String castAuthorityForRequest(
  String? rawHost,
  String defaultHost,
  int serverPort,
) {
  final value = rawHost?.trim() ?? '';
  if (value.isEmpty) return defaultHost;
  final defaultLoopback =
      defaultHost.startsWith('127.0.0.1') ||
      defaultHost.startsWith('localhost') ||
      defaultHost.startsWith('[::1]');
  if (!defaultLoopback &&
      (value.startsWith('127.0.0.1') ||
          value.startsWith('localhost') ||
          value.startsWith('[::1]'))) {
    return defaultHost;
  }
  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close <= 0) return defaultHost;
    if (close + 1 < value.length && value[close + 1] == ':') {
      final port = int.tryParse(value.substring(close + 2));
      return port != null && port > 0
          ? value
          : '${value.substring(0, close + 1)}:$serverPort';
    }
    return '${value.substring(0, close + 1)}:$serverPort';
  }
  final colon = value.indexOf(':');
  if (colon > 0 && colon == value.lastIndexOf(':')) {
    final port = int.tryParse(value.substring(colon + 1));
    if (port != null && port > 0) return value;
    return '${value.substring(0, colon)}:$serverPort';
  }
  if (colon >= 0) return defaultHost;
  return '$value:$serverPort';
}

String rewriteCastPlaylist(String body, String origin, String public) =>
    body.replaceAll(origin, public);

class CastLink {
  const CastLink({required this.token, required this.url, required this.mime});
  final String token;
  final String url;
  final String mime;
}

abstract class _CastEntry {
  _CastEntry(this.host);
  final String host;
  Future<void> serve(
    HttpRequest request,
    String token,
    String name,
    _MutableCastStats stats,
  );
}

final _contentRangeTotal = RegExp(r'^bytes\s+\d+-\d+/(\d+)$');

class _ProxyEntry extends _CastEntry {
  _ProxyEntry(
    super.host,
    this.serverPort,
    this.origin,
    this.entryPublicName,
    this.entryUpstreamName,
    this.forceEntryPlaylist,
    this.client,
  );

  final int serverPort;
  final Uri origin;
  final String entryPublicName;
  final String entryUpstreamName;
  final bool forceEntryPlaylist;
  final HttpClient client;

  @override
  Future<void> serve(
    HttpRequest request,
    String token,
    String name,
    _MutableCastStats stats,
  ) async {
    final response = request.response;
    final isHead = request.method == 'HEAD';
    final upstreamName = name == entryPublicName ? entryUpstreamName : name;
    final playlistHint =
        (name == entryPublicName && forceEntryPlaylist) ||
        name.toLowerCase().endsWith('.m3u8');
    final clientRange = request.headers.value(HttpHeaders.rangeHeader);
    final upstream = await client
        .openUrl('GET', origin.resolve(upstreamName))
        .timeout(const Duration(seconds: 12));
    if (!playlistHint) {
      if (clientRange != null) {
        upstream.headers.set(HttpHeaders.rangeHeader, clientRange);
        final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
        if (ifRange != null) {
          upstream.headers.set(HttpHeaders.ifRangeHeader, ifRange);
        }
      } else if (isHead) {
        upstream.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      }
    }
    final reply = await upstream.close().timeout(const Duration(seconds: 25));
    var completed = false;
    try {
      final rawType = reply.headers.value(HttpHeaders.contentTypeHeader) ?? '';
      final playlist =
          playlistHint || rawType.toLowerCase().contains('mpegurl');
      if (playlist &&
          (reply.statusCode == HttpStatus.ok ||
              reply.statusCode == HttpStatus.partialContent)) {
        final body = await utf8.decoder
            .bind(reply)
            .join()
            .timeout(const Duration(seconds: 25));
        completed = true;
        final authority = castAuthorityForRequest(
          request.headers.value(HttpHeaders.hostHeader),
          host,
          serverPort,
        );
        final bytes = utf8.encode(
          rewriteCastPlaylist(
            body,
            origin.toString(),
            'http://$authority/cast/$token/',
          ),
        );
        response.statusCode = HttpStatus.ok;
        stats.lastStatus = HttpStatus.ok;
        response.headers.set(HttpHeaders.contentTypeHeader, castPlaylistMime);
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        _dlnaHeaders(response, seekable: false);
        response.contentLength = bytes.length;
        if (!isHead) {
          response.add(bytes);
          stats.bytes += bytes.length;
        }
        return;
      }
      final mime = normalizeCastContentType(name, rawType);
      if (isHead &&
          clientRange == null &&
          reply.statusCode == HttpStatus.partialContent) {
        final contentRange =
            reply.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        final totalMatch = _contentRangeTotal.firstMatch(contentRange.trim());
        final total = totalMatch == null
            ? null
            : int.tryParse(totalMatch.group(1)!);
        response.statusCode = HttpStatus.ok;
        stats.lastStatus = HttpStatus.ok;
        response.headers.set(HttpHeaders.contentTypeHeader, mime);
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        for (final header in const [
          HttpHeaders.etagHeader,
          HttpHeaders.lastModifiedHeader,
        ]) {
          final value = reply.headers.value(header);
          if (value != null) response.headers.set(header, value);
        }
        if (total != null) response.contentLength = total;
        _dlnaHeaders(response, seekable: true);
        await reply.drain<void>();
        completed = true;
        return;
      }
      response.statusCode = reply.statusCode;
      stats.lastStatus = reply.statusCode;
      if (reply.statusCode == HttpStatus.ok ||
          reply.statusCode == HttpStatus.partialContent) {
        response.headers.set(HttpHeaders.contentTypeHeader, mime);
        response.headers.set(
          HttpHeaders.acceptRangesHeader,
          reply.headers.value(HttpHeaders.acceptRangesHeader) ?? 'bytes',
        );
        for (final header in const [
          HttpHeaders.contentRangeHeader,
          HttpHeaders.etagHeader,
          HttpHeaders.lastModifiedHeader,
        ]) {
          final value = reply.headers.value(header);
          if (value != null) response.headers.set(header, value);
        }
        _dlnaHeaders(
          response,
          seekable: path.extension(name).toLowerCase() != '.key',
        );
      }
      if (reply.contentLength >= 0) {
        response.contentLength = reply.contentLength;
      }
      if (isHead) return;
      await for (final chunk in reply) {
        response.add(chunk);
        stats.bytes += chunk.length;
      }
      completed = true;
    } finally {
      if (!completed) {
        unawaited(
          reply.detachSocket().then(
            (socket) => socket.destroy(),
            onError: (_) {},
          ),
        );
      }
    }
  }
}

class _FileEntry extends _CastEntry {
  _FileEntry(super.host, this.file, this.name);
  final File file;
  final String name;

  @override
  Future<void> serve(
    HttpRequest request,
    String token,
    String name,
    _MutableCastStats stats,
  ) async {
    if (name != this.name) {
      request.response.statusCode = HttpStatus.notFound;
      stats.lastStatus = HttpStatus.notFound;
      return;
    }
    await _serveFile(request, file, castMimeForName(name), stats);
  }
}

class _DirectoryEntry extends _CastEntry {
  _DirectoryEntry(super.host, this.root);
  final Directory root;

  @override
  Future<void> serve(
    HttpRequest request,
    String token,
    String name,
    _MutableCastStats stats,
  ) async {
    final file = File(path.join(root.path, name));
    if (path.normalize(file.parent.path) != path.normalize(root.path) ||
        !await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      stats.lastStatus = HttpStatus.notFound;
      return;
    }
    await _serveFile(request, file, castMimeForName(name), stats);
  }
}

void _dlnaHeaders(HttpResponse response, {required bool seekable}) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set('transferMode.dlna.org', 'Streaming');
  response.headers.set(
    'contentFeatures.dlna.org',
    seekable
        ? 'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000'
        : 'DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000',
  );
}

Future<void> _serveFile(
  HttpRequest request,
  File file,
  String mime,
  _MutableCastStats stats,
) async {
  final response = request.response;
  final length = await file.length();
  final isPlaylist = mime.contains('mpegurl');
  response.headers.set(HttpHeaders.contentTypeHeader, mime);
  if (!isPlaylist) {
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  }
  _dlnaHeaders(response, seekable: !isPlaylist);
  var start = 0;
  var end = length - 1;
  final range = isPlaylist
      ? null
      : request.headers.value(HttpHeaders.rangeHeader);
  final match = range == null
      ? null
      : RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
  if (match != null) {
    final first = match.group(1)!;
    final last = match.group(2)!;
    if (first.isEmpty && last.isNotEmpty) {
      start = max(0, length - int.parse(last));
    } else if (first.isNotEmpty) {
      start = int.parse(first);
      if (last.isNotEmpty) end = min(int.parse(last), length - 1);
    }
    if (start >= length || start > end) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      stats.lastStatus = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      return;
    }
    response.statusCode = HttpStatus.partialContent;
    stats.lastStatus = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/$length',
    );
  } else {
    stats.lastStatus = HttpStatus.ok;
  }
  response.contentLength = max(0, end - start + 1);
  if (request.method == 'HEAD' || length == 0) return;
  await for (final chunk in file.openRead(start, end + 1)) {
    response.add(chunk);
    stats.bytes += chunk.length;
  }
}

class CastMediaServer {
  CastMediaServer._();
  static final instance = CastMediaServer._();

  final _entries = <String, _CastEntry>{};
  final _stats = <String, _MutableCastStats>{};
  final _random = Random.secure();
  final _client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..autoUncompress = false
    ..maxConnectionsPerHost = 24
    ..idleTimeout = const Duration(seconds: 30)
    ..connectionTimeout = const Duration(seconds: 6);
  HttpServer? _server;
  Future<HttpServer>? _starting;

  Future<HttpServer> _ensure() {
    final server = _server;
    if (server != null) return Future.value(server);
    return _starting ??= () async {
      try {
        final bound = await HttpServer.bind(InternetAddress.anyIPv4, 0);
        bound.autoCompress = false;
        bound.idleTimeout = const Duration(minutes: 5);
        bound.listen(_handle, onError: (_) {});
        _server = bound;
        return bound;
      } finally {
        _starting = null;
      }
    }();
  }

  String _token() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16),
  ).map((value) => value.padLeft(2, '0')).join();

  CastStats statsFor(String token) =>
      _stats[token]?.snapshot() ?? const CastStats();

  Future<CastLink> _publish(
    _CastEntry Function(String host, int port) create,
    String name,
    String lanAddress,
  ) async {
    final server = await _ensure();
    final host = '$lanAddress:${server.port}';
    final token = _token();
    _entries[token] = create(host, server.port);
    _stats[token] = _MutableCastStats();
    return CastLink(
      token: token,
      url: 'http://$host/cast/$token/${Uri.encodeComponent(name)}',
      mime: castMimeForName(name),
    );
  }

  Future<CastLink> publishProxy(
    Uri asset,
    String lanAddress, {
    String? overrideName,
  }) {
    final segments = asset.pathSegments;
    if (segments.length != 2 || segments.any((value) => value.isEmpty)) {
      throw ArgumentError.value(asset, 'asset');
    }
    final upstreamName = segments.last;
    final publicName = overrideName ?? upstreamName;
    final forcePlaylist = publicName.toLowerCase().endsWith('.m3u8');
    final origin = Uri(
      scheme: asset.scheme,
      host: asset.host,
      port: asset.port,
      path: '/${segments.first}/',
    );
    return _publish(
      (host, port) => _ProxyEntry(
        host,
        port,
        origin,
        publicName,
        upstreamName,
        forcePlaylist,
        _client,
      ),
      publicName,
      lanAddress,
    );
  }

  Future<CastLink> publishFile(File file, String lanAddress) {
    final name = path.basename(file.path);
    return _publish(
      (host, _) => _FileEntry(host, file, name),
      name,
      lanAddress,
    );
  }

  Future<CastLink> publishDirectory(File entry, String lanAddress) => _publish(
    (host, _) => _DirectoryEntry(host, entry.parent),
    path.basename(entry.path),
    lanAddress,
  );

  Future<void> release(String token) async {
    _entries.remove(token);
    _stats.remove(token);
    if (_entries.isEmpty) {
      final server = _server;
      _server = null;
      await server?.close(force: true);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length != 3 || segments.first != 'cast') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final token = segments[1];
      final name = segments[2];
      final entry = _entries[token];
      final stats = _stats[token];
      if (entry == null || stats == null) {
        response.statusCode = HttpStatus.gone;
        return;
      }
      if (name.isEmpty ||
          name == '.' ||
          name == '..' ||
          name.contains('/') ||
          name.contains('\\')) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      stats.requests++;
      stats.lastPath = name;
      await entry.serve(request, token, name, stats);
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }
}

const _virtualInterfaceTokens = [
  'tun',
  'tap',
  'ppp',
  'pptp',
  'l2tp',
  'ipsec',
  'wireguard',
  'utun',
  'tailscale',
  'zerotier',
  'clash',
  'mihomo',
  'meta',
  'sing-box',
  'nekobox',
  'v2ray',
  'wintun',
  'vmnet',
  'vmware',
  'vbox',
  'virtualbox',
  'vethernet',
  'hyper-v',
  'wsl',
  'docker',
  'br-',
  'virbr',
  'rmnet',
  'ccmni',
  'pdp_ip',
  'clat',
  'dummy',
];

const _physicalLanTokens = [
  'wlan',
  'eth',
  'en',
  'wl',
  'ap',
  'swlan',
  'wi-fi',
  'wifi',
  'ethernet',
];

bool _virtualInterfaceName(String name) {
  final lower = name.trim().toLowerCase();
  if (lower.isEmpty) return false;
  if (lower == 'lo' || lower.startsWith('wg')) return true;
  for (final token in _virtualInterfaceTokens) {
    if (lower.contains(token)) return true;
  }
  return false;
}

bool _physicalLanName(String name) {
  final lower = name.trim().toLowerCase();
  if (lower.isEmpty) return false;
  for (final token in _physicalLanTokens) {
    if (lower.startsWith(token) || lower.contains(token)) return true;
  }
  return false;
}

List<int>? _ipv4Bytes(String host) {
  final parsed = InternetAddress.tryParse(host.trim());
  if (parsed == null || parsed.type != InternetAddressType.IPv4) return null;
  final raw = parsed.rawAddress;
  return raw.length == 4 ? raw : null;
}

bool _usableLanBytes(List<int> bytes) {
  if (bytes[0] == 0 || bytes[0] == 127 || bytes[0] >= 224) return false;
  if (bytes[0] == 169 && bytes[1] == 254) return false;
  if (bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)) return false;
  if (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) return false;
  return true;
}

int _privateScore(List<int> bytes) {
  if (bytes[0] == 192 && bytes[1] == 168) return 240;
  if (bytes[0] == 10) return 220;
  if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) return 180;
  return 0;
}

List<String> rankCastLanAddresses(
  String targetHost,
  Iterable<CastNetInterface> interfaces, {
  String? socketAddress,
}) {
  final target = _ipv4Bytes(targetHost);
  final scores = <String, int>{};
  for (final item in interfaces) {
    if (_virtualInterfaceName(item.name)) continue;
    final bytes = _ipv4Bytes(item.address);
    if (bytes == null || !_usableLanBytes(bytes)) continue;
    var score = _privateScore(bytes);
    if (target != null) {
      if (bytes[0] == target[0] &&
          bytes[1] == target[1] &&
          bytes[2] == target[2]) {
        score += 1000;
      } else if (bytes[0] == target[0] && bytes[1] == target[1]) {
        score += 500;
      }
    }
    if (_physicalLanName(item.name)) score += 100;
    if (socketAddress != null && item.address == socketAddress) score += 50;
    final previous = scores[item.address];
    if (previous == null || score > previous) scores[item.address] = score;
  }
  if (scores.isEmpty && socketAddress != null) {
    final bytes = _ipv4Bytes(socketAddress);
    if (bytes != null && _usableLanBytes(bytes)) {
      scores[socketAddress] = _privateScore(bytes);
    }
  }
  final ranked = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return [for (final entry in ranked) entry.key];
}

String? selectCastLanAddress(
  String targetHost,
  Iterable<CastNetInterface> interfaces, {
  String? socketAddress,
}) {
  final ranked = rankCastLanAddresses(
    targetHost,
    interfaces,
    socketAddress: socketAddress,
  );
  return ranked.isEmpty ? null : ranked.first;
}

Future<List<String>> castLanCandidatesFor(String host, int port) async {
  final interfaces = <CastNetInterface>[];
  interfaces.addAll(await AppDevice.lanAddresses());
  try {
    for (final network in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final address in network.addresses) {
        if (address.isLoopback || address.isLinkLocal) continue;
        interfaces.add((name: network.name, address: address.address));
      }
    }
  } catch (_) {}
  String? socketAddress;
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 3),
    );
    final local = socket.address;
    socket.destroy();
    if (local.type == InternetAddressType.IPv4 && !local.isLoopback) {
      socketAddress = local.address;
    }
  } catch (_) {}
  final ranked = rankCastLanAddresses(
    host,
    interfaces,
    socketAddress: socketAddress,
  );
  if (ranked.isNotEmpty) return ranked;
  throw const SocketException('未找到可供电视访问的局域网地址');
}

Future<String> castLanAddressFor(String host, int port) async =>
    (await castLanCandidatesFor(host, port)).first;
