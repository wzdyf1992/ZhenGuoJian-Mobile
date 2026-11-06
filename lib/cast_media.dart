import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'cast_media_server.dart';
import 'core_bridge.dart';
import 'models.dart';

String _formatSeconds(double value) {
  final total = value < 0 ? 0 : value.floor();
  String two(int number) => number.toString().padLeft(2, '0');
  final clock = '${two(total ~/ 60 % 60)}:${two(total % 60)}';
  return total >= 3600 ? '${total ~/ 3600}:$clock' : clock;
}

class CastMedia {
  const CastMedia({
    required this.plan,
    required this.link,
    this.isHls = false,
    this.remuxed = false,
    this.cacheFile,
  });

  final PlaybackPlan plan;
  final CastLink link;
  final bool isHls;
  final bool remuxed;
  final File? cacheFile;
  String get url => link.url;
  String get mime => link.mime;
}

bool get castDecryptionSupported => Platform.isAndroid || Platform.isIOS;

bool castLoopbackUrl(Uri uri) =>
    uri.scheme == 'http' &&
    (uri.host == '127.0.0.1' || uri.host == 'localhost' || uri.host == '::1');

class CastMediaPreparer {
  CastMediaPreparer(this.repository);

  final AppRepository repository;
  final _server = CastMediaServer.instance;
  final _probeClient = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..autoUncompress = false
    ..idleTimeout = const Duration(seconds: 10)
    ..connectionTimeout = const Duration(seconds: 6);
  int? _session;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  static Future<Directory> _cacheDirectory() async =>
      Directory(path.join((await getTemporaryDirectory()).path, 'dlna_cast'));

  static Future<void> clearCache() async {
    try {
      final directory = await _cacheDirectory();
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {}
  }

  static Future<void> pruneCache({
    Set<String> keepPaths = const {},
    int maxFiles = 3,
    Directory? directory,
  }) async {
    try {
      final targetDir = directory ?? await _cacheDirectory();
      if (!await targetDir.exists()) return;
      final normalizedKeep = keepPaths.map(path.normalize).toSet();
      final entries = <({File file, DateTime modified})>[];
      await for (final entity in targetDir.list()) {
        if (entity is! File) continue;
        final normalized = path.normalize(entity.path);
        if (normalized.endsWith('.part.mp4') ||
            normalizedKeep.contains(normalized)) {
          continue;
        }
        try {
          entries.add((file: entity, modified: await entity.lastModified()));
        } catch (_) {}
      }
      entries.sort((a, b) => b.modified.compareTo(a.modified));
      for (var i = maxFiles; i < entries.length; i++) {
        try {
          await entries[i].file.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<bool> _probeLoopback(Uri uri) async {
    Future<({int status, String contentType, List<int> prefix})> fetch({
      required bool ranged,
    }) async {
      final request = await _probeClient
          .getUrl(uri)
          .timeout(const Duration(seconds: 8));
      if (ranged) request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final bytes = <int>[];
      var completed = false;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 10),
        )) {
          final need = 1024 - bytes.length;
          if (chunk.length <= need) {
            bytes.addAll(chunk);
          } else {
            bytes.addAll(chunk.sublist(0, need));
          }
          if (bytes.length >= 1024) break;
        }
        if (bytes.length < 1024) completed = true;
      } finally {
        if (!completed) {
          unawaited(
            response.detachSocket().then(
              (socket) => socket.destroy(),
              onError: (_) {},
            ),
          );
        }
      }
      return (
        status: response.statusCode,
        contentType:
            response.headers.value(HttpHeaders.contentTypeHeader) ?? '',
        prefix: bytes,
      );
    }

    final m3u8Path = uri.path.toLowerCase().endsWith('.m3u8');
    try {
      var result = await fetch(ranged: !m3u8Path);
      if (!m3u8Path && result.status == HttpStatus.badGateway) {
        result = await fetch(ranged: false);
      }
      if (_cancelled) throw AppFailure('已取消投屏准备');
      if (result.status != HttpStatus.ok &&
          result.status != HttpStatus.partialContent) {
        final message = utf8
            .decode(result.prefix, allowMalformed: true)
            .trim()
            .split('\n')
            .first
            .trim();
        throw AppFailure(
          message.isEmpty ? '片源响应异常（HTTP ${result.status}）' : message,
        );
      }
      final sample = utf8
          .decode(result.prefix, allowMalformed: true)
          .replaceFirst('\ufeff', '')
          .trimLeft();
      return m3u8Path ||
          result.contentType.toLowerCase().contains('mpegurl') ||
          sample.startsWith('#EXTM3U');
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw AppFailure('片源连接超时，请重试或切换线路');
    } on SocketException {
      throw AppFailure('无法连接本机媒体服务，请重试');
    }
  }

  Future<CastMedia> prepare(
    PlaybackPlan plan, {
    required String cacheKey,
    required String lanAddress,
    required void Function(String status) onStatus,
    bool compatMp4 = false,
  }) async {
    _cancelled = false;
    if (plan.url.isEmpty) throw AppFailure('站源未返回播放地址，请重试');
    if (plan.local) {
      final file = File(plan.url);
      if (!await file.exists()) {
        throw AppFailure('本地视频不可用，请重新下载或改为在线投屏。', code: 'local_media');
      }
      final isHls = path.extension(file.path).toLowerCase() == '.m3u8';
      if (plan.decryptionKey.isNotEmpty || (isHls && compatMp4)) {
        if (!castDecryptionSupported) {
          throw AppFailure('当前平台暂不支持本地流转换投屏。');
        }
        final remuxed = await _remuxToMp4(
          plan,
          '$cacheKey|local_mp4',
          onStatus,
          isHls: isHls,
          actionLabel: plan.decryptionKey.isNotEmpty
              ? '正在为电视解密视频'
              : '正在转换为电视兼容格式',
        );
        return CastMedia(
          plan: plan,
          link: await _server.publishFile(remuxed, lanAddress),
          isHls: isHls,
          remuxed: true,
          cacheFile: remuxed,
        );
      }
      final link = isHls
          ? await _server.publishDirectory(file, lanAddress)
          : await _server.publishFile(file, lanAddress);
      return CastMedia(plan: plan, link: link, isHls: isHls);
    }
    final uri = Uri.tryParse(plan.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw AppFailure('播放地址无效，无法投屏');
    }
    final loopback = castLoopbackUrl(uri) && uri.pathSegments.length == 2;
    var isHls =
        uri.path.toLowerCase().endsWith('.m3u8') ||
        plan.url.toLowerCase().contains('m3u8');
    if (loopback) {
      onStatus('正在检测片源连接与流格式');
      isHls = await _probeLoopback(uri);
    }
    if (plan.decryptionKey.isNotEmpty) {
      if (!castDecryptionSupported) {
        throw AppFailure('该视频经过加密，需要先在本机解密；当前平台暂不支持。');
      }
      final file = await _remuxToMp4(
        plan,
        cacheKey,
        onStatus,
        isHls: isHls,
        actionLabel: '正在为电视解密视频',
      );
      return CastMedia(
        plan: plan,
        link: await _server.publishFile(file, lanAddress),
        isHls: isHls,
        remuxed: true,
        cacheFile: file,
      );
    }
    if (compatMp4 && castDecryptionSupported) {
      final file = await _remuxToMp4(
        plan,
        '$cacheKey|compat',
        onStatus,
        isHls: isHls,
        actionLabel: '正在转换为电视兼容格式',
      );
      return CastMedia(
        plan: plan,
        link: await _server.publishFile(file, lanAddress),
        isHls: isHls,
        remuxed: true,
        cacheFile: file,
      );
    }
    if (loopback) {
      final overrideName = isHls && !uri.path.toLowerCase().endsWith('.m3u8')
          ? 'index.m3u8'
          : null;
      return CastMedia(
        plan: plan,
        link: await _server.publishProxy(
          uri,
          lanAddress,
          overrideName: overrideName,
        ),
        isHls: isHls,
      );
    }
    return CastMedia(
      plan: plan,
      link: CastLink(
        token: '',
        url: plan.url,
        mime: isHls ? castPlaylistMime : 'video/mp4',
      ),
      isHls: isHls,
    );
  }

  Future<File> _remuxToMp4(
    PlaybackPlan plan,
    String cacheKey,
    void Function(String status) onStatus, {
    required bool isHls,
    required String actionLabel,
  }) async {
    final directory = await _cacheDirectory();
    await directory.create(recursive: true);
    final digest = sha1.convert(utf8.encode(cacheKey)).toString();
    final target = File(path.join(directory.path, '$digest.mp4'));
    if (await target.exists() && await target.length() > 0) return target;
    final partial = File(path.join(directory.path, '$digest.part.mp4'));
    onStatus(actionLabel);
    final parsed = Uri.tryParse(plan.url);
    final attachHeaders =
        !plan.local &&
        plan.headers.isNotEmpty &&
        (parsed == null || !castLoopbackUrl(parsed));
    final arguments = <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-y',
      '-protocol_whitelist',
      plan.local ? 'file,crypto,data' : 'http,https,tcp,tls,crypto,data,file',
      if (attachHeaders) ...[
        '-headers',
        [
          for (final entry in plan.headers.entries)
            if (entry.value.isNotEmpty) '${entry.key}: ${entry.value}\r\n',
        ].join(),
      ],
      if (isHls) ...[
        '-f',
        'hls',
        '-allowed_extensions',
        'ALL',
        '-extension_picky',
        '0',
      ],
      if (plan.decryptionKey.isNotEmpty) ...[
        '-decryption_key',
        plan.decryptionKey,
      ],
      '-i',
      plan.url,
      '-map',
      '0:v:0?',
      '-map',
      '0:a:0?',
      '-c',
      'copy',
      '-map_metadata',
      '-1',
      '-movflags',
      '+faststart',
      '-f',
      'mp4',
      partial.path,
    ];
    final finished = Completer<Object?>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      arguments,
      (result) async {
        try {
          final code = await result.getReturnCode();
          if (finished.isCompleted) return;
          finished.complete(
            ReturnCode.isSuccess(code)
                ? null
                : AppFailure(
                    _cancelled || ReturnCode.isCancel(code)
                        ? '已取消投屏准备'
                        : '为电视准备视频失败（${code?.getValue() ?? -1}），请重试或换一个清晰度。',
                  ),
          );
        } catch (error) {
          if (!finished.isCompleted) finished.complete(error);
        }
      },
      null,
      (statistics) {
        final seconds = statistics.getTime() / 1000;
        if (seconds > 0) {
          onStatus('$actionLabel · 已处理 ${_formatSeconds(seconds)}');
        }
      },
    );
    _session = session.getSessionId();
    try {
      if (_cancelled) await FFmpegKit.cancel(_session);
      final failure = await finished.future;
      if (failure != null) throw failure;
    } catch (_) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      rethrow;
    } finally {
      _session = null;
    }
    if (!await partial.exists() || await partial.length() == 0) {
      throw AppFailure('为电视准备的视频为空，请重试');
    }
    return partial.rename(target.path);
  }

  Future<void> cancel() async {
    _cancelled = true;
    final session = _session;
    if (session != null) {
      try {
        await FFmpegKit.cancel(session);
      } catch (_) {}
    }
  }

  Future<void> dispose(CastMedia media) async {
    if (media.link.token.isNotEmpty) await _server.release(media.link.token);
    if (media.plan.session.isNotEmpty) {
      try {
        await repository.release(media.plan.session);
      } catch (_) {}
    }
  }

  void close() {
    _probeClient.close(force: true);
  }
}
