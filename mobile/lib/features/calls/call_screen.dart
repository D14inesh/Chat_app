import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/avatar.dart';
import '../../theme.dart';
import '../conversations/conversations_provider.dart';
import 'call_controller.dart';

/// The website's call filters, in the same order.
const _filters = {
  'none': 'None',
  'mono': 'Mono',
  'warm': 'Warm',
  'cool': 'Cool',
  'vivid': 'Vivid',
  'vintage': 'Vintage',
  'noir': 'Noir',
  'soft': 'Soft',
};

/// Full-screen overlay for every non-idle call phase -- incoming-ringing,
/// outgoing-ringing, and connected. Mounted once at the app root (see
/// app.dart) so it appears over whatever screen is currently open,
/// matching how a phone call interrupts anything on-screen.
class CallOverlay extends ConsumerStatefulWidget {
  const CallOverlay({super.key});

  @override
  ConsumerState<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends ConsumerState<CallOverlay> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;
  bool _selfEnlarged = false; // tap the self-view to swap it to full screen
  bool _showFilters = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _initRenderers();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(callControllerProvider).connectedAt != null) setState(() {});
    });
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (mounted) setState(() => _renderersReady = true);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callControllerProvider);
    if (!call.isActive || !_renderersReady) {
      _selfEnlarged = false;
      _showFilters = false;
      return const SizedBox.shrink();
    }

    _localRenderer.srcObject = call.screenSharing ? call.screenStream : call.localStream;
    _remoteRenderer.srcObject = call.remoteStream;
    final controller = ref.read(callControllerProvider.notifier);
    final isVideo = call.callType == 'video';
    final peer = call.conversationId == null
        ? null
        : ref.watch(conversationsProvider).valueOrNull?.where((c) => c.id == call.conversationId).firstOrNull?.peer;

    final remoteView = RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);
    final selfView = RTCVideoView(
      _localRenderer,
      mirror: !call.screenSharing,
      objectFit: call.screenSharing ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
    final showVideo = isVideo && call.remoteStream != null;

    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Stack(
          children: [
            if (showVideo)
              Positioned.fill(child: _selfEnlarged ? selfView : remoteView)
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Avatar(label: call.peerName ?? '?', color: peer?.avatarColor, photoUrl: peer?.photoUrl, radius: 52),
                    const SizedBox(height: 16),
                    Text(call.peerName ?? '', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            if (isVideo && call.localStream != null && call.phase == CallPhase.connected)
              Positioned(
                right: 16,
                top: 56,
                width: 104,
                height: 148,
                child: GestureDetector(
                  onTap: () => setState(() => _selfEnlarged = !_selfEnlarged),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: Colors.white24)),
                      child: _selfEnlarged && showVideo ? remoteView : selfView,
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  if (showVideo)
                    Text(call.peerName ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                  Text(_statusText(call), style: const TextStyle(color: Colors.white70)),
                  if (call.screenSharing)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('🖥 Sharing your screen', style: TextStyle(color: Colors.amberAccent)),
                    ),
                ],
              ),
            ),
            if (call.error != null)
              Positioned(
                top: 84,
                left: 20,
                right: 20,
                child: Text(call.error!, style: const TextStyle(color: VeyonColors.danger), textAlign: TextAlign.center),
              ),
            if (_showFilters && isVideo && call.phase == CallPhase.connected)
              Positioned(
                bottom: 130,
                left: 0,
                right: 0,
                child: SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final f in _filters.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(f.value),
                            selected: call.filter == f.key,
                            onSelected: (_) => controller.setFilter(f.key),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: _controls(call, controller, isVideo),
            ),
          ],
        ),
      ),
    );
  }

  String _statusText(CallState call) {
    switch (call.phase) {
      case CallPhase.outgoingRinging:
        return 'Calling…';
      case CallPhase.incomingRinging:
        return 'Incoming ${call.callType == 'video' ? 'video' : 'voice'} call';
      case CallPhase.connecting:
        return 'Connecting…';
      case CallPhase.connected:
        final since = call.connectedAt;
        if (since == null) return 'Connecting…';
        final d = DateTime.now().difference(since);
        final m = d.inMinutes.toString().padLeft(2, '0');
        final s = (d.inSeconds % 60).toString().padLeft(2, '0');
        return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
      default:
        return '';
    }
  }

  Widget _controls(CallState call, CallController controller, bool isVideo) {
    if (call.phase == CallPhase.incomingRinging) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _RoundButton(icon: Icons.call_end_rounded, color: VeyonColors.danger, label: 'Decline', onTap: controller.declineCall),
          _RoundButton(icon: isVideo ? Icons.videocam_rounded : Icons.call_rounded, color: Colors.green, label: 'Accept', onTap: controller.acceptCall),
        ],
      );
    }
    final connected = call.phase == CallPhase.connected;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 14,
      runSpacing: 12,
      children: [
        _RoundButton(
          icon: call.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          color: call.micMuted ? Colors.white : Colors.white24,
          iconColor: call.micMuted ? Colors.black : Colors.white,
          label: call.micMuted ? 'Unmute' : 'Mute',
          onTap: controller.toggleMic,
        ),
        _RoundButton(
          icon: controller.speakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded,
          color: controller.speakerOn ? Colors.white : Colors.white24,
          iconColor: controller.speakerOn ? Colors.black : Colors.white,
          label: 'Speaker',
          onTap: controller.toggleSpeaker,
        ),
        if (isVideo)
          _RoundButton(
            icon: call.cameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded,
            color: Colors.white24,
            label: 'Camera',
            onTap: controller.toggleCamera,
          ),
        if (isVideo && !call.screenSharing)
          _RoundButton(icon: Icons.cameraswitch_rounded, color: Colors.white24, label: 'Flip', onTap: controller.switchCamera),
        if (isVideo && connected && !call.screenSharing)
          _RoundButton(
            icon: Icons.auto_awesome_rounded,
            color: call.filter != 'none' ? Colors.white : Colors.white24,
            iconColor: call.filter != 'none' ? Colors.black : Colors.white,
            label: 'Filters',
            onTap: () => setState(() => _showFilters = !_showFilters),
          ),
        if (isVideo && connected)
          _RoundButton(
            icon: call.screenSharing ? Icons.stop_screen_share_rounded : Icons.screen_share_rounded,
            color: call.screenSharing ? Colors.white : Colors.white24,
            iconColor: call.screenSharing ? Colors.black : Colors.white,
            label: call.screenSharing ? 'Stop share' : 'Share screen',
            onTap: controller.toggleScreenShare,
          ),
        _RoundButton(icon: Icons.call_end_rounded, color: VeyonColors.danger, label: 'End', onTap: controller.hangUp),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color iconColor;
  final String? label;
  final VoidCallback onTap;
  const _RoundButton({required this.icon, required this.color, required this.onTap, this.iconColor = Colors.white, this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: iconColor),
          ),
        ),
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(label!, style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ),
      ],
    );
  }
}
