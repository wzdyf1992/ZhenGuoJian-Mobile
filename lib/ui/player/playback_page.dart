import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../app_device.dart';
import '../../local_store.dart';
import '../../picture_in_picture.dart';
import '../../playback_session.dart';
import '../app_scope.dart';
import 'dlna_cast_page.dart';
import 'landscape_player_page.dart';
import 'mini_player.dart';
import 'playback_handle.dart';
import 'player_page.dart';
import 'portrait_player_page.dart';
import 'television_player_page.dart';

class PlaybackPage extends StatefulWidget {
  const PlaybackPage({super.key, required this.store, required this.handle});
  final LocalStore store;
  final PlaybackHandle handle;

  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<PlaybackPage> {
  final _padFullscreen = ValueNotifier(false);
  final _pageScope = FocusScopeNode(debugLabel: 'playbackPage');
  final _pip = PictureInPicture.instance;
  late bool _wideVideo = _measure();
  MediaQueryData? _media;
  bool _shown = false;
  bool _casting = false;
  Player? _bound;
  StreamSubscription<bool>? _playing;

  PlaybackSession get _session => widget.handle.session;

  bool _measure() => _session.aspectKnown && _session.aspectRatio >= 1;

  bool get _television =>
      AppScope.formFactorOf(context) == FormFactor.television;

  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
    _padFullscreen.addListener(_padFullscreenChanged);
    _pip.addListener(_pipChanged);
    _pip.onAction = _action;
    _bind();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _pip.removeListener(_pipChanged);
    if (_pip.onAction == _action) _pip.onAction = null;
    _pip.clear();
    unawaited(_playing?.cancel());
    _pageScope.dispose();
    if (_padFullscreen.value) _applyPadFullscreen(false);
    _padFullscreen.dispose();
    unawaited(AppDevice.resetBrightness());
    widget.handle.dispose();
    super.dispose();
  }

  void _changed() {
    _bind();
    _sync();
    final wide = _measure();
    if (wide != _wideVideo) setState(() => _wideVideo = wide);
  }

  void _bind() {
    final player = _session.player;
    if (identical(player, _bound)) return;
    _bound = player;
    unawaited(_playing?.cancel());
    _playing = player.stream.playing.listen((_) => _sync());
  }

  void _sync() {
    if (!mounted) return;
    final session = _session;
    final playing = session.player.state.playing;
    _pip.update(
      aspectRatio: session.aspectRatio,
      playing: playing,
      hasPrevious: session.hasPrevious,
      hasNext: session.hasNext,
      autoEnter:
          playing &&
          !_television &&
          widget.store.playbackPreferences.autoPictureInPicture,
    );
  }

  void _pipChanged() {
    if (!mounted) return;
    final shown = _pip.shown;
    if (shown && !_shown) _closeRoutesAbove();
    if (!shown && _shown) _pageScope.requestFocus();
    _shown = shown;
    if (!_television) {
      _session.setForeground(
        playerVisible(WidgetsBinding.instance.lifecycleState),
      );
    }
    _sync();
    setState(() {});
  }

  void _closeRoutesAbove() {
    final route = ModalRoute.of(context);
    if (route == null || route.isCurrent) return;
    Navigator.of(context).popUntil((other) => other == route);
  }

  void _action(String action) {
    switch (action) {
      case 'toggle':
        _session.togglePlayback();
      case 'previous':
        unawaited(_session.previous());
      case 'next':
        unawaited(_session.next());
    }
  }

  Future<void> _enterMini() async {
    _closeRoutesAbove();
    await _pip.enter(_session.aspectRatio);
  }

  Future<void> _startCast() async {
    if (_casting || _television) return;
    _casting = true;
    _closeRoutesAbove();
    await _session.beginCast();
    _sync();
    if (!mounted) {
      _casting = false;
      return;
    }
    try {
      final device = await showDlnaDevicePicker(context);
      if (device == null || !mounted) {
        await _session.endCast(
          null,
          foreground: playerVisible(WidgetsBinding.instance.lifecycleState),
        );
        _sync();
        return;
      }
      final result = await Navigator.of(context).push<DlnaCastResult>(
        MaterialPageRoute(
          builder: (_) => DlnaCastPage(
            detail: _session.detail,
            initialIndex: _session.index,
            initialPosition: _session.currentPosition,
            repository: _session.repository,
            store: widget.store,
            device: device,
            profileEpoch: widget.store.profileEpoch,
            quality: _session.quality,
          ),
        ),
      );
      if (!mounted) return;
      await _session.endCast(
        result?.index,
        position: result?.position ?? 0,
        foreground: playerVisible(WidgetsBinding.instance.lifecycleState),
      );
      _sync();
    } finally {
      _casting = false;
    }
  }

  void _padFullscreenChanged() {
    _applyPadFullscreen(_padFullscreen.value);
    setState(() {});
  }

  void _applyPadFullscreen(bool full) {
    unawaited(
      AppDevice.setPlayerOrientation(
        full ? PlayerOrientation.lockedLandscape : PlayerOrientation.auto,
      ),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ).catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final live = MediaQuery.of(context);
    final shown = _pip.shown || _pip.leaving && live.size != _media?.size;
    if (!shown || _media == null) _media = live;
    return Stack(
      fit: StackFit.expand,
      children: [
        FocusScope(
          node: _pageScope,
          child: Offstage(
            offstage: shown,
            child: MediaQuery(
              data: _media!,
              child: Builder(builder: _page),
            ),
          ),
        ),
        if (shown) PictureInPictureView(handle: widget.handle),
      ],
    );
  }

  Widget _page(BuildContext context) {
    final form = AppScope.formFactorOf(context);
    final mini = _pip.available ? () => unawaited(_enterMini()) : null;
    final cast = form == FormFactor.television
        ? null
        : () => unawaited(_startCast());
    return switch (form) {
      FormFactor.pad || FormFactor.window => _padPage(context, mini, cast),
      FormFactor.phone when _wideVideo => LandscapePlayerPage(
        store: widget.store,
        handle: widget.handle,
        onMiniWindow: mini,
        onCast: cast,
      ),
      FormFactor.phone => PortraitPlayerPage(
        store: widget.store,
        handle: widget.handle,
        onMiniWindow: mini,
        onCast: cast,
      ),
      FormFactor.television => TelevisionPlayerPage(handle: widget.handle),
    };
  }

  Widget _padPage(
    BuildContext context,
    VoidCallback? mini,
    VoidCallback? cast,
  ) {
    final size = MediaQuery.sizeOf(context);
    if (_padFullscreen.value || size.width > size.height) {
      return PlayerPage(
        store: widget.store,
        handle: widget.handle,
        padFullscreen: _padFullscreen,
        onMiniWindow: mini,
        onCast: cast,
      );
    }
    return _wideVideo
        ? LandscapePlayerPage(
            store: widget.store,
            handle: widget.handle,
            onFullscreen: () => _padFullscreen.value = true,
            onMiniWindow: mini,
            onCast: cast,
          )
        : PortraitPlayerPage(
            store: widget.store,
            handle: widget.handle,
            onMiniWindow: mini,
            onCast: cast,
          );
  }
}
