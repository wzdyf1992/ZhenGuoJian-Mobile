import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../app_device.dart';
import '../../cast_media.dart';
import '../../cast_media_server.dart';
import '../../core_bridge.dart';
import '../../diary_service.dart';
import '../../dlna_client.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../playback_loader.dart';
import 'episode_grid.dart';
import 'playback_sheets.dart';
import 'player_surface.dart';

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1048576).toStringAsFixed(1)} MB';
}

class DlnaCastResult {
  const DlnaCastResult({required this.index, required this.position});
  final int index;
  final double position;
}

Future<DlnaDevice?> showDlnaDevicePicker(BuildContext context) {
  final theme = Theme.of(context);
  return showModalBottomSheet<DlnaDevice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: theme.colorScheme.surfaceContainerLow,
    builder: (_) => const _DlnaDevicePicker(),
  );
}

class _DlnaDevicePicker extends StatefulWidget {
  const _DlnaDevicePicker();
  @override
  State<_DlnaDevicePicker> createState() => _DlnaDevicePickerState();
}

class _DlnaDevicePickerState extends State<_DlnaDevicePicker> {
  static final List<DlnaDevice> _remembered = [];
  final _devices = <DlnaDevice>[];
  final _discovery = DlnaDiscovery();
  bool _searching = false;
  String? _error;
  int _round = 0;

  @override
  void initState() {
    super.initState();
    _devices.addAll(_remembered);
    unawaited(_search());
  }

  Future<void> _search() async {
    if (_searching) return;
    final round = ++_round;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      await _discovery.search(
        onDevice: (device) {
          if (!mounted || round != _round) return;
          setState(() {
            _devices.removeWhere((item) => item.id == device.id);
            _devices.add(device);
            _remembered
              ..removeWhere((item) => item.id == device.id)
              ..add(device);
          });
        },
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted && round == _round) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .7,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            children: [
              const Expanded(child: Text('投屏到电视', style: sheetTitle)),
              if (_searching)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  tooltip: '重新搜索',
                  onPressed: _search,
                  icon: const Icon(Icons.refresh_rounded),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '支持 DLNA / UPnP 的电视、盒子和投屏接收器（如乐播投屏、当贝、小米、海信、TCL、创维等）。请确认电视与本机连接同一局域网。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Flexible(
            child: _devices.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(20, 32, 20, 36),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.connected_tv_rounded,
                          size: 48,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(_searching ? '正在搜索局域网中的投屏设备…' : '没有找到可投屏的设备'),
                        if (!_searching) ...[
                          const SizedBox(height: 8),
                          Text(
                            '请打开电视的投屏/DLNA 接收功能，关闭路由器 AP 隔离后重新搜索。',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      return ListTile(
                        key: ValueKey('dlna-device-${device.id}'),
                        leading: const Icon(Icons.tv_rounded),
                        title: Text(
                          device.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          device.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).pop(device),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class DlnaCastPage extends StatefulWidget {
  const DlnaCastPage({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.initialPosition,
    required this.repository,
    required this.store,
    required this.device,
    required this.profileEpoch,
    this.quality = 0,
    this.localOnly = false,
  });

  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final AppRepository repository;
  final LocalStore store;
  final DlnaDevice device;
  final int profileEpoch;
  final int quality;
  final bool localOnly;

  @override
  State<DlnaCastPage> createState() => _DlnaCastPageState();
}

class _DlnaCastPageState extends State<DlnaCastPage> {
  late final DlnaRenderer _renderer;
  late final PlaybackLoader _loader;
  late final CastMediaPreparer _preparer;
  late final CastMediaPreparer _nextPreparer;
  late int _index;
  late int _quality;
  CastMedia? _media;
  CastMedia? _nextReady;
  Future<CastMedia?>? _nextFuture;
  int _nextTicket = 0;
  int? _nextIndex;
  String? _nextSpec;
  DateTime _nextExpires = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _nextRetryAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pollTimer;
  Timer? _saveTimer;
  int _generation = 0;
  int _pollTick = 0;
  int _atEndTicks = 0;
  bool _busy = true;
  bool _closed = false;
  bool _polling = false;
  bool _sawPlaying = false;
  bool _finished = false;
  bool _compatMp4 = false;
  bool _autoCompatTried = false;
  int _failures = 0;
  String _status = '正在连接电视';
  String? _error;
  String _transport = '';
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration? _pendingSeek;
  double? _dragValue;
  int? _volume;
  String? _lanAddress;
  List<String> _lanCandidates = const [];
  DateTime? _sentAt;
  DateTime? _playingSince;
  CastStats _stats = const CastStats();
  String? _savedKey;
  String _sessionSignature = '';

  Episode get _episode => widget.detail.episodes[_index];
  bool get _playing => _transport == DlnaTransportState.playing;
  bool get _profileValid => widget.store.profileEpoch == widget.profileEpoch;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _quality = widget.quality;
    _renderer = DlnaRenderer(widget.device);
    _loader = PlaybackLoader(widget.repository);
    _preparer = CastMediaPreparer(widget.repository);
    _nextPreparer = CastMediaPreparer(widget.repository);
    AppDevice.onCastAction = _handleSystemCastAction;
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _poll(),
    );
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    unawaited(_start());
  }

  Future<void> _start() async {
    _syncPlatformSession(force: true);
    await CastMediaPreparer.clearCache();
    if (_closed) return;
    await _load(_index, position: widget.initialPosition);
    if (_renderer.supportsVolume) {
      try {
        final volume = await _renderer.volume();
        if (mounted && !_closed) setState(() => _volume = volume);
      } catch (_) {}
    }
  }

  void _handleSystemCastAction(String action) {
    if (_closed || !mounted) return;
    switch (action) {
      case 'play':
        if (!_busy && _media != null && !_playing) unawaited(_togglePlayback());
      case 'pause':
        if (!_busy && _media != null && _playing) unawaited(_togglePlayback());
      case 'toggle':
        unawaited(_togglePlayback());
      case 'previous':
        if (!_busy && _index > 0) unawaited(_load(_index - 1));
      case 'next':
        if (!_busy && _index + 1 < widget.detail.episodes.length) {
          unawaited(_load(_index + 1));
        }
      case 'stop':
        unawaited(_finish());
    }
  }

  void _syncPlatformSession({bool force = false}) {
    if (_closed) return;
    final title =
        '${widget.detail.drama.title} 第 ${widget.detail.episodes[_index].number} 集';
    final playing = _playing;
    final paused = _transport == DlnaTransportState.paused;
    final hasPrev = _index > 0;
    final hasNext = _index + 1 < widget.detail.episodes.length;
    final signature = '$title|$playing|$paused|$hasPrev|$hasNext';
    if (!force && signature == _sessionSignature) return;
    _sessionSignature = signature;
    unawaited(
      AppDevice.updateCastSession(
        active: true,
        deviceName: widget.device.name,
        title: title,
        playing: playing,
        paused: paused,
        hasPrevious: hasPrev,
        hasNext: hasNext,
      ),
    );
  }

  String _specFor(int index, String lanAddress) =>
      '$index|$_quality|$_compatMp4|$lanAddress|${widget.localOnly}';

  void _clearNext({int? keepIndex, String? keepSpec}) {
    if (keepIndex != null &&
        keepSpec != null &&
        _nextIndex == keepIndex &&
        _nextSpec == keepSpec) {
      return;
    }
    _nextTicket++;
    _nextIndex = null;
    _nextSpec = null;
    _nextFuture = null;
    _nextRetryAt = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(_nextPreparer.cancel());
    unawaited(widget.repository.cancelPreload().catchError((Object _) {}));
    final ready = _nextReady;
    _nextReady = null;
    if (ready != null) {
      unawaited(_nextPreparer.dispose(ready));
    }
  }

  void _pruneTempFiles() {
    final keep = <String>{
      if (_media?.cacheFile != null) _media!.cacheFile!.path,
      if (_nextReady?.cacheFile != null) _nextReady!.cacheFile!.path,
    };
    unawaited(CastMediaPreparer.pruneCache(keepPaths: keep));
  }

  Future<CastMedia?> _prepareWithRoutes(
    CastMediaPreparer preparer,
    PlaybackPlan initialPlan, {
    required int episodeIndex,
    required String lanAddress,
    required bool Function() active,
    required Future<PlaybackPlan?> Function(PlaybackPlan current) nextRoute,
    required void Function(String status) onStatus,
  }) async {
    var currentPlan = initialPlan;
    while (true) {
      try {
        return await preparer.prepare(
          currentPlan,
          cacheKey:
              '${widget.detail.drama.id}|${widget.detail.episodes[episodeIndex].id}|${currentPlan.quality}|${currentPlan.routeIndex}|${currentPlan.local}',
          lanAddress: lanAddress,
          compatMp4: _compatMp4,
          onStatus: onStatus,
        );
      } catch (error) {
        if (!active() ||
            preparer.cancelled ||
            currentPlan.local ||
            currentPlan.routeIndex + 1 >= currentPlan.routeCount) {
          await widget.repository.release(currentPlan.session);
          rethrow;
        }
        DiaryService.add(
          '[DLNA] 线路 ${currentPlan.routeIndex + 1}/${currentPlan.routeCount} 准备失败（$error），自动切换下一线路',
        );
        onStatus(
          '当前线路不可用，正在切换备用线路 (${currentPlan.routeIndex + 2}/${currentPlan.routeCount})',
        );
        final fallbackPlan = await nextRoute(currentPlan);
        await widget.repository.release(currentPlan.session);
        if (fallbackPlan == null) return null;
        if (!active()) {
          await widget.repository.release(fallbackPlan.session);
          return null;
        }
        currentPlan = fallbackPlan;
      }
    }
  }

  void _maybePreloadNext() {
    final activeMedia = _media;
    final lanAddress = _lanAddress;
    final nextIndex = _index + 1;
    if (_closed ||
        _busy ||
        _error != null ||
        activeMedia == null ||
        lanAddress == null ||
        !_profileValid ||
        !_sawPlaying ||
        nextIndex >= widget.detail.episodes.length) {
      return;
    }
    final localOrRemuxed = activeMedia.remuxed || activeMedia.plan.local;
    final playedEnough =
        localOrRemuxed ||
        _position >= const Duration(seconds: 3) ||
        (_playingSince != null &&
            DateTime.now().difference(_playingSince!) >=
                const Duration(seconds: 4));
    if (!playedEnough) return;
    final spec = _specFor(nextIndex, lanAddress);
    if (_nextReady != null && _nextIndex == nextIndex && _nextSpec == spec) {
      if (DateTime.now().isBefore(_nextExpires)) return;
      _clearNext();
    }
    if (_nextFuture != null && _nextIndex == nextIndex && _nextSpec == spec) {
      return;
    }
    if (DateTime.now().isBefore(_nextRetryAt)) return;
    _clearNext();
    final future = _prepareNext(nextIndex, lanAddress, spec);
    _nextFuture = future;
    unawaited(future);
  }

  Future<CastMedia?> _prepareNext(
    int nextIndex,
    String lanAddress,
    String spec,
  ) async {
    final ticket = ++_nextTicket;
    _nextIndex = nextIndex;
    _nextSpec = spec;
    if (mounted && !_closed) setState(() {});
    bool active() => !_closed && ticket == _nextTicket && _profileValid;
    final episode = widget.detail.episodes[nextIndex];
    try {
      final PlaybackPlan? plan;
      if (widget.localOnly) {
        plan = await widget.repository.localPlayback(
          widget.detail.drama,
          episode,
        );
      } else {
        plan = await widget.repository.preload(
          widget.detail.drama,
          episode,
          quality: _quality,
        );
      }
      if (plan == null || plan.url.isEmpty) return null;
      if (!active()) {
        await widget.repository.release(plan.session);
        return null;
      }
      final prepared = await _prepareWithRoutes(
        _nextPreparer,
        plan,
        episodeIndex: nextIndex,
        lanAddress: lanAddress,
        active: active,
        nextRoute: (current) => widget.repository.fallback(current),
        onStatus: (_) {},
      );
      if (prepared == null) return null;
      if (!active()) {
        await _nextPreparer.dispose(prepared);
        return null;
      }
      var expires = DateTime.now().add(
        prepared.remuxed || prepared.plan.local
            ? const Duration(hours: 6)
            : const Duration(minutes: 6),
      );
      if (!prepared.remuxed &&
          !prepared.plan.local &&
          prepared.plan.expiresAt > 0) {
        final authExpiry = DateTime.fromMillisecondsSinceEpoch(
          prepared.plan.expiresAt,
        ).subtract(const Duration(seconds: 15));
        if (authExpiry.isBefore(expires)) expires = authExpiry;
      }
      if (!expires.isAfter(DateTime.now())) {
        await _nextPreparer.dispose(prepared);
        return null;
      }
      _nextReady = prepared;
      _nextExpires = expires;
      _pruneTempFiles();
      DiaryService.add('[DLNA] 已在后台提前备好第 ${episode.number} 集');
      if (mounted && !_closed) setState(() {});
      return prepared;
    } catch (_) {
      if (active()) {
        _nextRetryAt = DateTime.now().add(const Duration(seconds: 20));
      }
      return null;
    } finally {
      if (ticket == _nextTicket) {
        _nextFuture = null;
        if (mounted && !_closed) setState(() {});
      }
    }
  }

  Future<String> _lan({bool refresh = false}) async {
    if (!refresh && _lanAddress != null) return _lanAddress!;
    final candidates = await castLanCandidatesFor(
      widget.device.host,
      widget.device.port,
    );
    _lanCandidates = candidates;
    final selected = _lanAddress != null && candidates.contains(_lanAddress)
        ? _lanAddress!
        : candidates.first;
    _lanAddress = selected;
    return selected;
  }

  Future<void> _load(
    int index, {
    double position = 0,
    PlaybackPlan? presetPlan,
    bool resetAutoCompat = true,
  }) async {
    if (_closed || index < 0 || index >= widget.detail.episodes.length) return;
    final ticket = ++_generation;
    final previousTransport = _transport;
    final hadMedia = _media != null;
    await _saveProgress();
    await _preparer.cancel();
    if (!_current(ticket)) return;
    if (resetAutoCompat) _autoCompatTried = false;
    setState(() {
      _index = index;
      _busy = true;
      _error = null;
      _finished = false;
      _sawPlaying = false;
      _atEndTicks = 0;
      _transport = '';
      _sentAt = null;
      _playingSince = null;
      _stats = const CastStats();
      _position = Duration.zero;
      _duration = Duration.zero;
      _pendingSeek = position > 1
          ? Duration(milliseconds: (position * 1000).round())
          : null;
      _status = '正在准备第 ${widget.detail.episodes[index].number} 集';
    });
    _syncPlatformSession(force: true);
    CastMedia? media;
    try {
      final lanAddress = await _lan(refresh: _lanCandidates.isEmpty);
      if (!_current(ticket)) return;
      final spec = _specFor(index, lanAddress);
      if (presetPlan == null &&
          _nextReady != null &&
          _nextIndex == index &&
          _nextSpec == spec &&
          DateTime.now().isBefore(_nextExpires)) {
        media = _nextReady;
        _nextReady = null;
        _nextIndex = null;
        _nextSpec = null;
        _nextTicket++;
      } else if (presetPlan == null &&
          _nextFuture != null &&
          _nextIndex == index &&
          _nextSpec == spec) {
        if (mounted && _current(ticket)) {
          setState(
            () =>
                _status = '正在完成第 ${widget.detail.episodes[index].number} 集后台准备',
          );
        }
        final awaited = await _nextFuture;
        if (!_current(ticket)) {
          if (awaited != null && identical(_nextReady, awaited)) {
            _clearNext();
          } else if (awaited != null) {
            await _nextPreparer.dispose(awaited);
          }
          return;
        }
        if (awaited != null) {
          if (identical(_nextReady, awaited)) {
            _nextReady = null;
            _nextIndex = null;
            _nextSpec = null;
            _nextTicket++;
          }
          media = awaited;
        }
      } else {
        _clearNext();
      }
      if (media == null) {
        _clearNext();
        if (mounted && _current(ticket)) {
          setState(
            () => _status = '正在解析第 ${widget.detail.episodes[index].number} 集',
          );
        }
        final resolved = presetPlan != null
            ? await _loader.use(presetPlan)
            : await _loader.load(
                widget.detail.drama,
                widget.detail.episodes[index],
                quality: _quality,
                localOnly: widget.localOnly,
              );
        if (resolved == null) return;
        if (!_current(ticket)) {
          await widget.repository.release(resolved.session);
          return;
        }
        media = await _prepareWithRoutes(
          _preparer,
          resolved,
          episodeIndex: index,
          lanAddress: lanAddress,
          active: () => _current(ticket),
          nextRoute: _loader.fallback,
          onStatus: (status) {
            if (mounted && _current(ticket)) setState(() => _status = status);
          },
        );
        if (media == null) return;
      }
      if (!_current(ticket)) {
        await _preparer.dispose(media);
        return;
      }
      DiaryService.add('[DLNA] 投屏到 ${widget.device.name}: ${media.url}');
      setState(() => _status = '正在发送到 ${widget.device.name}');
      final needStop =
          hadMedia &&
          previousTransport != DlnaTransportState.stopped &&
          previousTransport != DlnaTransportState.noMedia;
      if (needStop) {
        try {
          await _renderer.stop();
        } catch (_) {}
        if (!_current(ticket)) {
          await _preparer.dispose(media);
          return;
        }
      }
      await _renderer.setUri(
        media.url,
        title:
            '${widget.detail.drama.title} 第 ${widget.detail.episodes[index].number} 集',
        mime: media.mime,
      );
      if (!_current(ticket)) {
        await _preparer.dispose(media);
        return;
      }
      try {
        await _renderer.play();
      } on DlnaException {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await _renderer.play();
      }
      final previous = _media;
      _media = media;
      media = null;
      if (previous != null) await _preparer.dispose(previous);
      _pruneTempFiles();
      if (mounted && _current(ticket)) {
        setState(() {
          _busy = false;
          _sentAt = DateTime.now();
          _stats = _media!.link.token.isEmpty
              ? const CastStats()
              : CastMediaServer.instance.statsFor(_media!.link.token);
          _status = '已发送，等待电视连接播放';
        });
        _syncPlatformSession();
      }
    } catch (error) {
      DiaryService.add('[DLNA] 投屏失败: $error');
      if (media != null) await _preparer.dispose(media);
      if (mounted && _current(ticket)) {
        setState(() {
          _busy = false;
          _error = error is AppFailure || error is DlnaException
              ? error.toString()
              : '投屏失败：$error';
        });
        _syncPlatformSession();
      }
    }
  }

  bool _current(int ticket) =>
      !_closed && mounted && ticket == _generation && _profileValid;

  Future<void> _poll() async {
    final activeMedia = _media;
    if (_closed || _polling || _busy || activeMedia == null) return;
    _pollTick++;
    final liveStats = activeMedia.link.token.isEmpty
        ? const CastStats()
        : CastMediaServer.instance.statsFor(activeMedia.link.token);
    if (mounted &&
        _current(_generation) &&
        (liveStats.requests != _stats.requests ||
            liveStats.bytes != _stats.bytes)) {
      setState(() => _stats = liveStats);
    }
    final fastPoll =
        !_sawPlaying ||
        (_duration > Duration.zero &&
            _duration - _position <= const Duration(seconds: 12));
    if (!fastPoll && _pollTick.isOdd) return;
    _polling = true;
    final ticket = _generation;
    try {
      final state = await _renderer.transportState();
      final position = await _renderer.position();
      if (!_current(ticket)) return;
      _failures = 0;
      final latestStats = activeMedia.link.token.isEmpty
          ? const CastStats()
          : CastMediaServer.instance.statsFor(activeMedia.link.token);
      final previousPosition = _position;
      final previousDuration = _duration;
      if (state == DlnaTransportState.playing ||
          position.position > const Duration(seconds: 1)) {
        _sawPlaying = true;
        _playingSince ??= DateTime.now();
      }
      final sentAt = _sentAt;
      if (!_sawPlaying &&
          !_compatMp4 &&
          !_autoCompatTried &&
          castDecryptionSupported &&
          !activeMedia.remuxed &&
          !activeMedia.plan.local &&
          latestStats.requests > 0 &&
          sentAt != null &&
          DateTime.now().difference(sentAt) >= const Duration(seconds: 5) &&
          (state == DlnaTransportState.stopped ||
              state == DlnaTransportState.noMedia)) {
        _autoCompatTried = true;
        _compatMp4 = true;
        _clearNext();
        DiaryService.add('[DLNA] 电视未能直接播放流（$state），自动开启 MP4 兼容模式重试');
        final resumeSeconds = (_pendingSeek ?? _position).inMilliseconds / 1000;
        unawaited(
          _load(_index, position: resumeSeconds, resetAutoCompat: false),
        );
        return;
      }
      final pendingSeek = _pendingSeek;
      if (pendingSeek != null &&
          state == DlnaTransportState.playing &&
          position.duration > Duration.zero) {
        _pendingSeek = null;
        if (pendingSeek < position.duration - const Duration(seconds: 3)) {
          unawaited(_renderer.seek(pendingSeek).catchError((_) {}));
        }
      }
      final effectiveDuration = position.duration > Duration.zero
          ? position.duration
          : previousDuration;
      if (effectiveDuration > Duration.zero &&
          position.position >= effectiveDuration &&
          position.position == previousPosition &&
          state != DlnaTransportState.paused) {
        _atEndTicks++;
      } else {
        _atEndTicks = 0;
      }
      final endWindow = Duration(
        milliseconds: max(
          6000,
          (effectiveDuration.inMilliseconds * 0.08).round(),
        ),
      );
      final reachedTail =
          effectiveDuration > Duration.zero &&
          (previousPosition >= effectiveDuration - endWindow ||
              position.position >= effectiveDuration - endWindow);
      final ended =
          _sawPlaying &&
          !_finished &&
          reachedTail &&
          (state == DlnaTransportState.stopped ||
              state == DlnaTransportState.noMedia ||
              _atEndTicks >= 3);
      setState(() {
        _stats = latestStats;
        _transport = state;
        _status = switch (state) {
          DlnaTransportState.playing => '正在电视上播放',
          DlnaTransportState.paused => '已暂停',
          DlnaTransportState.transitioning =>
            latestStats.requests > 0 ? '电视已连入，正在缓冲画面' : '电视正在准备加载',
          DlnaTransportState.stopped => _sawPlaying ? '电视已停止播放' : '等待电视开始播放',
          DlnaTransportState.noMedia => '电视没有正在播放的内容',
          _ => state.isEmpty ? '等待电视响应' : state,
        };
        if (state == DlnaTransportState.playing ||
            state == DlnaTransportState.paused ||
            position.position > Duration.zero) {
          _position = position.position;
        }
        if (position.duration > Duration.zero) _duration = position.duration;
      });
      _syncPlatformSession();
      if (ended) {
        _finished = true;
        _position = effectiveDuration;
        await _saveProgress();
        if (_index + 1 < widget.detail.episodes.length && mounted && !_closed) {
          unawaited(_load(_index + 1));
        } else if (mounted && !_closed) {
          setState(() => _status = '已播放完最后一集');
        }
        return;
      }
      _maybePreloadNext();
    } catch (error) {
      if (_current(ticket) && ++_failures >= 6) {
        setState(() => _status = '与电视的连接不稳定：$error');
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _saveProgress() async {
    if (!_profileValid || _media == null || !_sawPlaying) return;
    final position = _position.inMilliseconds / 1000;
    final duration = _duration.inMilliseconds / 1000;
    if (position < .1) return;
    final key = '$_index:$position:$duration';
    if (key == _savedKey) return;
    final entry = WatchEntry(
      drama: widget.repository.catalogUpdates.current(widget.detail.drama),
      episode: _episode.number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      await widget.store.saveWatch(entry);
      _savedKey = key;
    } catch (_) {}
  }

  Future<void> _togglePlayback() async {
    if (_busy || _media == null) return;
    final playing = _playing;
    setState(
      () => _transport = playing
          ? DlnaTransportState.paused
          : DlnaTransportState.playing,
    );
    _syncPlatformSession();
    try {
      if (playing) {
        await _renderer.pause();
        await _saveProgress();
      } else {
        await _renderer.play();
      }
    } catch (error) {
      _toast(error.toString());
    }
  }

  Future<void> _seek(Duration target) async {
    if (_busy || _media == null) return;
    final clamped = target < Duration.zero
        ? Duration.zero
        : _duration > Duration.zero && target > _duration
        ? _duration
        : target;
    setState(() => _position = clamped);
    try {
      await _renderer.seek(clamped);
    } catch (error) {
      _toast(error.toString());
    }
  }

  Future<void> _changeVolume(int delta) async {
    final current = _volume;
    if (current == null) return;
    final next = (current + delta).clamp(0, 100);
    setState(() => _volume = next);
    try {
      await _renderer.setVolume(next);
    } catch (error) {
      _toast(error.toString());
    }
  }

  Future<void> _toggleCompatMode() async {
    if (_busy) return;
    setState(() => _compatMp4 = !_compatMp4);
    _clearNext();
    final resume = (_pendingSeek ?? _position).inMilliseconds / 1000;
    await _load(_index, position: resume, resetAutoCompat: false);
  }

  Future<void> _switchRoute() async {
    final current = _media?.plan;
    if (_busy || current == null || current.local || current.routeCount <= 1) {
      return;
    }
    final resume = (_pendingSeek ?? _position).inMilliseconds / 1000;
    try {
      setState(() {
        _busy = true;
        _error = null;
        _status = '正在切换播放线路';
      });
      final PlaybackPlan next;
      if (current.routeIndex + 1 < current.routeCount) {
        next = await widget.repository.fallback(current);
      } else {
        next = await widget.repository.resolveOnline(
          widget.detail.drama,
          _episode,
          quality: _quality,
        );
      }
      if (!mounted || _closed) {
        await widget.repository.release(next.session);
        return;
      }
      await _load(_index, position: resume, presetPlan: next);
    } catch (error) {
      if (!mounted || _closed) return;
      setState(() => _busy = false);
      _toast(error.toString());
    }
  }

  Future<void> _pickQuality() async {
    final qualities = _media?.plan.qualities ?? const <int>[];
    if (_busy || qualities.isEmpty) return;
    final theme = Theme.of(context);
    final selected = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader(
              children: [Expanded(child: Text('投屏清晰度', style: sheetTitle))],
            ),
            ListTile(
              leading: Icon(
                _quality == 0
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
              ),
              title: const Text('自动'),
              onTap: () => Navigator.pop(context, 0),
            ),
            for (final item in qualities)
              ListTile(
                leading: Icon(
                  _quality == item
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                ),
                title: Text('${item}P'),
                onTap: () => Navigator.pop(context, item),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || selected == _quality || !mounted || _closed) return;
    _quality = selected;
    _clearNext();
    final resume = (_pendingSeek ?? _position).inMilliseconds / 1000;
    await _load(_index, position: resume);
  }

  Future<void> _pickLanAddress() async {
    if (_busy || _lanCandidates.length <= 1) return;
    final theme = Theme.of(context);
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader(
              children: [Expanded(child: Text('切换本机局域网地址', style: sheetTitle))],
            ),
            for (final item in _lanCandidates)
              ListTile(
                leading: Icon(
                  _lanAddress == item
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                ),
                title: Text(item),
                subtitle: item == _lanCandidates.first
                    ? const Text('推荐（与电视网段最匹配）')
                    : null,
                onTap: () => Navigator.pop(context, item),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || selected == _lanAddress || !mounted || _closed) {
      return;
    }
    _lanAddress = selected;
    _clearNext();
    final resume = (_pendingSeek ?? _position).inMilliseconds / 1000;
    await _load(_index, position: resume);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _finish() async {
    if (_closed) return;
    await _saveProgress();
    final position = _position.inMilliseconds / 1000;
    final result = DlnaCastResult(
      index: _index,
      position: _finished || position < 1 ? 0 : position,
    );
    await _shutdown();
    if (mounted) Navigator.of(context).pop(result);
  }

  Future<void> _shutdown() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    if (AppDevice.onCastAction == _handleSystemCastAction) {
      AppDevice.onCastAction = null;
    }
    _pollTimer?.cancel();
    _saveTimer?.cancel();
    _clearNext();
    await _preparer.cancel();
    _preparer.close();
    _nextPreparer.close();
    try {
      await _renderer.stop().timeout(const Duration(seconds: 3));
    } catch (_) {}
    _renderer.close();
    final media = _media;
    _media = null;
    if (media != null) await _preparer.dispose(media);
    await _loader.close();
    await AppDevice.updateCastSession(active: false);
    await CastMediaPreparer.clearCache();
  }

  @override
  void dispose() {
    unawaited(_shutdown());
    super.dispose();
  }

  Future<void> _pickEpisode() async {
    final theme = Theme.of(context);
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      constraints: BoxConstraints.tightFor(
        height: MediaQuery.sizeOf(context).height * .6,
      ),
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            children: [
              const Text('选集', style: sheetTitle),
              Expanded(
                child: Text(
                  '共 ${widget.detail.episodes.length} 集',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
                tooltip: '关闭',
              ),
            ],
          ),
          Expanded(
            child: EpisodeGrid(
              episodes: widget.detail.episodes,
              current: _index,
              selecting: false,
              selected: const {},
              touch: true,
              onSelectionChanged: () {},
              onPick: (index) => Navigator.of(context).pop(index),
            ),
          ),
        ],
      ),
    );
    if (selected != null && mounted && !_closed) await _load(selected);
  }

  Widget _buildDiagnostics(ThemeData theme) {
    final media = _media;
    if (_busy || media == null || media.link.token.isEmpty) {
      return const SizedBox.shrink();
    }
    final authority = Uri.tryParse(media.url)?.authority ?? _lanAddress ?? '';
    final elapsed = _sentAt == null
        ? Duration.zero
        : DateTime.now().difference(_sentAt!);
    if (_stats.requests == 0 && elapsed >= const Duration(seconds: 8)) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '电视（${widget.device.host}）尚未连入本机媒体服务（$authority）。\n'
            '若开启了 VPN / 代理工具，请开启「绕过局域网」或暂时关闭 TUN 模式后点「重试」；同时确认路由器未开启 AP 隔离（电脑端需放行防火墙）。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
        ),
      );
    }
    final modeLabel = media.remuxed
        ? 'MP4 兼容流'
        : media.isHls
        ? 'HLS 流'
        : '直连流';
    final nextHint = _nextReady != null && _nextIndex == _index + 1
        ? ' · 下一集已就绪'
        : _nextFuture != null && _nextIndex == _index + 1
        ? ' · 正在预备下一集'
        : '';
    final detail = _stats.requests > 0
        ? '电视已连接（$authority）· 已传输 ${_formatBytes(_stats.bytes)} · $modeLabel$nextHint'
        : '本机服务地址：$authority · 等待电视拉取媒体流';
    final showCompatHint =
        _stats.requests > 0 &&
        !_sawPlaying &&
        !_compatMp4 &&
        !media.remuxed &&
        castDecryptionSupported &&
        elapsed >= const Duration(seconds: 8);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        showCompatHint
            ? '$detail\n若电视提示加载失败，可开启下方「兼容模式（转 MP4）」或切换清晰度重试。'
            : detail,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = _duration.inMilliseconds / 1000;
    final position = (_dragValue ?? _position.inMilliseconds / 1000).clamp(
      0.0,
      duration > 0 ? duration : 1.0,
    );
    final controlsEnabled = !_busy && _media != null && _error == null;
    final plan = _media?.plan;
    final qualities = plan?.qualities ?? const <int>[];
    final currentQuality = _quality > 0 ? '${_quality}P' : '自动';
    final waitingLong =
        !_busy &&
        !_sawPlaying &&
        _sentAt != null &&
        DateTime.now().difference(_sentAt!) >= const Duration(seconds: 8);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_finish());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '停止投屏并返回',
            onPressed: _finish,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: Text(
            '投屏到 ${widget.device.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  Container(
                    constraints: const BoxConstraints(minHeight: 180),
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _playing
                              ? Icons.cast_connected_rounded
                              : Icons.connected_tv_rounded,
                          size: 64,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            _error ?? _status,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _error != null
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (_busy) ...[
                          const SizedBox(height: 12),
                          const SizedBox(
                            width: 160,
                            child: LinearProgressIndicator(),
                          ),
                        ],
                      ],
                    ),
                  ),
                  _buildDiagnostics(theme),
                  const SizedBox(height: 20),
                  Text(
                    widget.detail.drama.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '第 ${_episode.number} 集 · 共 ${widget.detail.episodes.length} 集',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text(
                          formatClock(
                            Duration(milliseconds: (position * 1000).round()),
                          ),
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: position,
                          max: duration > 0 ? duration : 1,
                          onChanged: controlsEnabled && duration > 0
                              ? (value) => setState(() => _dragValue = value)
                              : null,
                          onChangeEnd: (value) {
                            setState(() => _dragValue = null);
                            if (controlsEnabled && duration > 0) {
                              unawaited(
                                _seek(
                                  Duration(
                                    milliseconds: (value * 1000).round(),
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      ),
                      SizedBox(
                        width: 52,
                        child: Text(
                          formatClock(_duration),
                          style: const TextStyle(
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        tooltip: '上一集',
                        onPressed: _index > 0 && !_busy
                            ? () => _load(_index - 1)
                            : null,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      IconButton(
                        tooltip: '后退 10 秒',
                        onPressed: controlsEnabled
                            ? () =>
                                  _seek(_position - const Duration(seconds: 10))
                            : null,
                        icon: const Icon(Icons.replay_10_rounded),
                      ),
                      IconButton.filled(
                        tooltip: _playing ? '暂停' : '播放',
                        iconSize: 40,
                        onPressed: controlsEnabled ? _togglePlayback : null,
                        icon: Icon(
                          _playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: '前进 10 秒',
                        onPressed: controlsEnabled
                            ? () =>
                                  _seek(_position + const Duration(seconds: 10))
                            : null,
                        icon: const Icon(Icons.forward_10_rounded),
                      ),
                      IconButton(
                        tooltip: '下一集',
                        onPressed:
                            _index + 1 < widget.detail.episodes.length && !_busy
                            ? () => _load(_index + 1)
                            : null,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                    ],
                  ),
                  if (_volume != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: '音量减',
                          onPressed: () => _changeVolume(-5),
                          icon: const Icon(Icons.volume_down_rounded),
                        ),
                        SizedBox(
                          width: 72,
                          child: Text(
                            '音量 $_volume',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        IconButton(
                          tooltip: '音量加',
                          onPressed: () => _changeVolume(5),
                          icon: const Icon(Icons.volume_up_rounded),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _pickEpisode,
                        icon: const Icon(Icons.grid_view_rounded),
                        label: const Text('选集'),
                      ),
                      if (qualities.length > 1 || _quality > 0)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _pickQuality,
                          icon: const Icon(Icons.hd_outlined),
                          label: Text('清晰度 · $currentQuality'),
                        ),
                      if (plan != null && !plan.local && plan.routeCount > 1)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _switchRoute,
                          icon: const Icon(Icons.alt_route_rounded),
                          label: Text(
                            '换线路 (${plan.routeIndex + 1}/${plan.routeCount})',
                          ),
                        ),
                      if (!widget.localOnly && castDecryptionSupported)
                        FilterChip(
                          selected: _compatMp4,
                          onSelected: _busy ? null : (_) => _toggleCompatMode(),
                          label: const Text('兼容模式（转 MP4）'),
                        ),
                      if (_lanCandidates.length > 1)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _pickLanAddress,
                          icon: const Icon(Icons.lan_outlined),
                          label: Text('网卡 ${_lanAddress ?? ''}'),
                        ),
                      if (_error != null || waitingLong)
                        FilledButton.tonalIcon(
                          onPressed: _busy
                              ? null
                              : () async {
                                  await _lan(refresh: true);
                                  if (mounted && !_closed) {
                                    await _load(
                                      _index,
                                      position:
                                          (_pendingSeek ?? _position)
                                              .inMilliseconds /
                                          1000,
                                    );
                                  }
                                },
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重试'),
                        ),
                      FilledButton.icon(
                        onPressed: _finish,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('退出投屏'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '投屏期间视频由本机后台服务持续转发给电视，锁屏也可继续连播，通知栏可快捷切集与暂停。退出投屏后会回到本机并停在当前进度。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
