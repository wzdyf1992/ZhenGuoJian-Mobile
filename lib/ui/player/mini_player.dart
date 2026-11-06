import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../picture_in_picture.dart';
import 'playback_handle.dart';

bool playerVisible(AppLifecycleState? state) =>
    state == AppLifecycleState.resumed ||
    state == AppLifecycleState.inactive ||
    PictureInPicture.instance.active;

Widget _video(PlaybackHandle handle) => Video(
  key: ValueKey(handle.session.player),
  controller: handle.video(handle.session.player),
  controls: NoVideoControls,
  fill: Colors.black,
  pauseUponEnteringBackgroundMode: false,
);

const _spinner = IgnorePointer(
  child: Center(
    child: SizedBox.square(
      dimension: 28,
      child: CircularProgressIndicator(strokeWidth: 3),
    ),
  ),
);

class PictureInPictureView extends StatelessWidget {
  const PictureInPictureView({super.key, required this.handle});
  final PlaybackHandle handle;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: handle.session,
    builder: (context, _) {
      final session = handle.session;
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _video(handle),
            if (session.loading || session.ready && session.stalled) _spinner,
          ],
        ),
      );
    },
  );
}
