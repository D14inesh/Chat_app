/// Group audio/video calling -- "join a room", not ring-and-accept, matching
/// server-py/ws/hub.py's on_group_call_* handlers (docstring: "start or join
/// a room"). Protocol, exactly as the server enforces it:
///   - Join: send `group-call-join` {conversationId, callType} -> get back
///     `group-call-state` {participantIds} (who's ALREADY in the room).
///   - Every conversation member (not just those in the call) is fanned out
///     `group-call-participant-joined`/`-left` for the room's membership.
///   - Mesh topology, glare-free by convention: only the ALREADY-PRESENT
///     side ever creates an offer to a newly-joined peer (triggered by
///     `participant-joined`); a peer never offers to someone already in its
///     initial `participantIds` list -- it just waits to be offered to.
///   - `group-call-claimed`: another of this same account's devices took
///     over the room slot -- this screen must stop and close.
/// STUN-only, no TURN, same as 1:1 calls (call_controller.dart).
library group_call_screen;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../models/conversation.dart';
import '../../theme.dart';
import '../auth/session.dart';

const _iceServers = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
};

class GroupCallScreen extends ConsumerStatefulWidget {
  final Conversation conversation;
  final String callType; // 'audio' | 'video'
  const GroupCallScreen({super.key, required this.conversation, required this.callType});

  @override
  ConsumerState<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends ConsumerState<GroupCallScreen> {
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  MediaStream? _localStream;
  final Map<String, RTCPeerConnection> _peers = {};
  final Map<String, MediaStream> _remoteStreams = {};
  final Map<String, RTCVideoRenderer> _renderers = {};
  final Map<String, List<RTCIceCandidate>> _pendingIce = {};
  final Map<String, String> _names = {};
  bool _joined = false;
  bool _micMuted = false;
  bool _cameraOff = false;
  String? _error;
  MediaStream? _screen; // while sharing my screen
  static const _native = MethodChannel('veyon/call');

  String get _conversationId => widget.conversation.id;
  bool get _isVideo => widget.callType == 'video';

  @override
  void initState() {
    super.initState();
    _wsSub = ref.read(sessionControllerProvider).ws?.frames.listen(_onFrame);
    _join();
  }

  @override
  void dispose() {
    _leave();
    _wsSub?.cancel();
    for (final r in _renderers.values) {
      r.dispose();
    }
    super.dispose();
  }

  void _send(Map<String, dynamic> frame) {
    ref.read(sessionControllerProvider).ws?.send({'conversationId': _conversationId, ...frame});
  }

  Future<void> _join() async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': _isVideo});
      setState(() {});
      _send({'type': 'group-call-join', 'callType': widget.callType});
    } catch (e) {
      setState(() => _error = 'Could not access camera/mic: $e');
    }
  }

  void _leave() {
    if (_joined) _send({'type': 'group-call-leave'});
    for (final pc in _peers.values) {
      pc.close();
    }
    for (final s in _remoteStreams.values) {
      for (final t in s.getTracks()) {
        t.stop();
      }
    }
    for (final t in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      t.stop();
    }
    for (final t in _screen?.getTracks() ?? <MediaStreamTrack>[]) {
      t.stop();
    }
    if (_screen != null) _native.invokeMethod('stopScreenShareService').catchError((_) => null);
  }

  Future<String> _nameFor(String userId) async {
    if (_names.containsKey(userId)) return _names[userId]!;
    try {
      final user = await ref.read(sessionControllerProvider).api.getUser(userId);
      final name = user['displayName'] as String? ?? 'Someone';
      _names[userId] = name;
      return name;
    } catch (_) {
      return 'Someone';
    }
  }

  Future<RTCPeerConnection> _ensurePeer(String userId) async {
    final existing = _peers[userId];
    if (existing != null) return existing;

    final pc = await createPeerConnection(_iceServers);
    _peers[userId] = pc;
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _send({
        'type': 'group-call-ice',
        'toUserId': userId,
        'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex},
      });
    };
    pc.onTrack = (event) async {
      if (event.streams.isEmpty) return;
      _remoteStreams[userId] = event.streams.first;
      final renderer = _renderers.putIfAbsent(userId, () => RTCVideoRenderer());
      if (renderer.textureId == null) await renderer.initialize();
      renderer.srcObject = event.streams.first;
      if (mounted) setState(() {});
    };
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed || s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _removePeer(userId);
      }
    };
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await pc.addTrack(track, _localStream!);
    }
    // Someone joins while I'm sharing: send them the screen too.
    final screen = _screen?.getVideoTracks().firstOrNull;
    if (screen != null) await (await _videoSender(pc))?.replaceTrack(screen);
    return pc;
  }

  void _removePeer(String userId) {
    _peers.remove(userId)?.close();
    for (final t in _remoteStreams.remove(userId)?.getTracks() ?? <MediaStreamTrack>[]) {
      t.stop();
    }
    _renderers.remove(userId)?.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _offerTo(String userId) async {
    final pc = await _ensurePeer(userId);
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _send({'type': 'group-call-offer', 'toUserId': userId, 'sdp': {'type': offer.type, 'sdp': offer.sdp}});
  }

  Future<void> _onFrame(Map<String, dynamic> frame) async {
    if (frame['conversationId'] != _conversationId) return;
    final type = frame['type'];
    switch (type) {
      case 'group-call-state':
        // Existing room members -- we wait for THEM to offer to us (see
        // file docstring); just remember their names for placeholder tiles.
        final ids = (frame['participantIds'] as List<dynamic>).cast<String>();
        for (final id in ids) {
          _nameFor(id).then((_) => mounted ? setState(() {}) : null);
        }
        setState(() => _joined = true);
        break;
      case 'group-call-participant-joined':
        final userId = frame['userId'] as String;
        if (userId == ref.read(sessionControllerProvider).user?.id || !_joined) return;
        await _nameFor(userId);
        if (!_peers.containsKey(userId)) await _offerTo(userId);
        break;
      case 'group-call-participant-left':
        _removePeer(frame['userId'] as String);
        break;
      case 'group-call-offer': {
        final userId = frame['fromUserId'] as String;
        await _nameFor(userId);
        final pc = await _ensurePeer(userId);
        final sdp = frame['sdp'] as Map<String, dynamic>;
        await pc.setRemoteDescription(RTCSessionDescription(sdp['sdp'] as String, sdp['type'] as String));
        for (final c in _pendingIce.remove(userId) ?? const <RTCIceCandidate>[]) {
          await pc.addCandidate(c);
        }
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        _send({'type': 'group-call-answer', 'toUserId': userId, 'sdp': {'type': answer.type, 'sdp': answer.sdp}});
        break;
      }
      case 'group-call-answer': {
        final userId = frame['fromUserId'] as String;
        final pc = _peers[userId];
        if (pc == null) return;
        final sdp = frame['sdp'] as Map<String, dynamic>;
        await pc.setRemoteDescription(RTCSessionDescription(sdp['sdp'] as String, sdp['type'] as String));
        for (final c in _pendingIce.remove(userId) ?? const <RTCIceCandidate>[]) {
          await pc.addCandidate(c);
        }
        break;
      }
      case 'group-call-ice': {
        final userId = frame['fromUserId'] as String;
        final c = frame['candidate'] as Map<String, dynamic>;
        final candidate = RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?);
        final pc = _peers[userId];
        if (pc == null) {
          _pendingIce.putIfAbsent(userId, () => []).add(candidate);
        } else {
          await pc.addCandidate(candidate);
        }
        break;
      }
      case 'group-call-claimed':
        if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
        break;
      case 'group-call-error':
        setState(() => _error = frame['error'] as String?);
        break;
    }
  }

  void _toggleMic() {
    final tracks = _localStream?.getAudioTracks() ?? const [];
    if (tracks.isEmpty) return;
    tracks.first.enabled = _micMuted;
    setState(() => _micMuted = !_micMuted);
  }

  Future<RTCRtpSender?> _videoSender(RTCPeerConnection pc) async =>
      (await pc.getSenders()).where((s) => s.track?.kind == 'video').firstOrNull;

  /// Share my screen with everyone in the call (video calls).
  Future<void> _toggleScreen() async {
    if (_screen != null) return _stopScreen();
    try {
      final allowed = await Helper.requestCapturePermission();
      if (!allowed) return;
      await _native.invokeMethod('startScreenShareService');
      final screen = await navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
      final track = screen.getVideoTracks().first;
      for (final pc in _peers.values) {
        await (await _videoSender(pc))?.replaceTrack(track);
      }
      track.onEnded = _stopScreen;
      setState(() => _screen = screen);
    } catch (_) {
      await _native.invokeMethod('stopScreenShareService').catchError((_) => null);
      if (mounted) setState(() => _error = 'Could not share your screen.');
    }
  }

  Future<void> _stopScreen() async {
    final screen = _screen;
    if (screen == null) return;
    final camera = _localStream?.getVideoTracks().firstOrNull;
    for (final pc in _peers.values) {
      if (camera != null) await (await _videoSender(pc))?.replaceTrack(camera);
    }
    for (final t in screen.getTracks()) {
      await t.stop();
    }
    await _native.invokeMethod('stopScreenShareService').catchError((_) => null);
    if (mounted) setState(() => _screen = null);
  }

  void _toggleCamera() {
    final tracks = _localStream?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return;
    tracks.first.enabled = _cameraOff;
    setState(() => _cameraOff = !_cameraOff);
  }

  @override
  Widget build(BuildContext context) {
    final tileIds = _remoteStreams.keys.toList();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.conversation.displayName('Group call')),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: VeyonColors.danger))),
            Expanded(
              child: GridView.count(
                crossAxisCount: tileIds.length <= 1 ? 1 : 2,
                padding: const EdgeInsets.all(8),
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: [
                  _LocalTile(stream: _screen ?? _localStream, isVideo: _isVideo, cameraOff: _cameraOff && _screen == null),
                  for (final id in tileIds) _RemoteTile(renderer: _renderers[id], name: _names[id] ?? '…', isVideo: _isVideo),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _RoundButton(icon: _micMuted ? Icons.mic_off_rounded : Icons.mic_rounded, color: Colors.white24, onTap: _toggleMic),
                  if (_isVideo) _RoundButton(icon: _cameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded, color: Colors.white24, onTap: _toggleCamera),
                  if (_isVideo)
                    _RoundButton(
                      icon: _screen != null ? Icons.stop_screen_share_rounded : Icons.screen_share_rounded,
                      color: _screen != null ? Theme.of(context).colorScheme.secondary : Colors.white24,
                      onTap: _toggleScreen,
                    ),
                  _RoundButton(icon: Icons.call_end_rounded, color: VeyonColors.danger, onTap: () => Navigator.of(context).pop()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalTile extends StatefulWidget {
  final MediaStream? stream;
  final bool isVideo;
  final bool cameraOff;
  const _LocalTile({required this.stream, required this.isVideo, required this.cameraOff});

  @override
  State<_LocalTile> createState() => _LocalTileState();
}

class _LocalTileState extends State<_LocalTile> {
  final _renderer = RTCVideoRenderer();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _renderer.initialize().then((_) {
      _renderer.srcObject = widget.stream;
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void didUpdateWidget(covariant _LocalTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.stream != oldWidget.stream) _renderer.srcObject = widget.stream;
  }

  @override
  void dispose() {
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        color: const Color(0xFF141A33),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_ready && widget.isVideo && !widget.cameraOff) RTCVideoView(_renderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
            const Positioned(bottom: 6, left: 8, child: Text('You', style: TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
  }
}

class _RemoteTile extends StatelessWidget {
  final RTCVideoRenderer? renderer;
  final String name;
  final bool isVideo;
  const _RemoteTile({required this.renderer, required this.name, required this.isVideo});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        color: const Color(0xFF1B2340),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isVideo && renderer != null) RTCVideoView(renderer!, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
            else
              Center(child: CircleAvatar(radius: 28, backgroundColor: VeyonColors.bubbleMe, child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white)))),
            Positioned(bottom: 6, left: 8, child: Text(name, style: const TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _RoundButton({required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(width: 56, height: 56, decoration: BoxDecoration(color: color, shape: BoxShape.circle), child: Icon(icon, color: Colors.white)),
    );
  }
}
