/// 1:1 audio/video calling over WebRTC, signaled through the same
/// call-offer/-answer/-decline/-ice/-end WS frames the web app uses (see
/// server-py/ws/hub.py's on_call_* handlers, which only relay these frames
/// between the two participants and never inspect the SDP/ICE payloads).
/// STUN-only (no TURN), matching app.js's ICE_SERVERS -- calls work
/// reliably on the same network or open internet paths, but may fail to
/// connect across some carrier-grade NATs without a TURN relay.
library call_controller;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/nav_key.dart';
import '../auth/session.dart';

const _iceServers = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
};

enum CallPhase { idle, outgoingRinging, incomingRinging, connecting, connected, ended }

class CallState {
  final CallPhase phase;
  final String? conversationId;
  final String? peerUserId;
  final String? peerName;
  final String callType; // 'audio' | 'video'
  final MediaStream? localStream;
  final MediaStream? remoteStream;
  final bool micMuted;
  final bool cameraOff;
  final String? error;

  /// Colour filter on my outgoing camera ('none', 'mono', 'warm', …).
  final String filter;

  /// My screen instead of my camera (video calls).
  final bool screenSharing;
  final MediaStream? screenStream;

  /// When the call actually connected — for the duration timer.
  final DateTime? connectedAt;

  const CallState({
    this.filter = 'none',
    this.screenSharing = false,
    this.screenStream,
    this.connectedAt,
    this.phase = CallPhase.idle,
    this.conversationId,
    this.peerUserId,
    this.peerName,
    this.callType = 'audio',
    this.localStream,
    this.remoteStream,
    this.micMuted = false,
    this.cameraOff = false,
    this.error,
  });

  bool get isActive => phase != CallPhase.idle && phase != CallPhase.ended;

  CallState copyWith({
    CallPhase? phase,
    String? conversationId,
    String? peerUserId,
    String? peerName,
    String? callType,
    MediaStream? localStream,
    MediaStream? remoteStream,
    bool? micMuted,
    bool? cameraOff,
    String? error,
    String? filter,
    bool? screenSharing,
    MediaStream? screenStream,
    bool clearScreenStream = false,
    DateTime? connectedAt,
  }) =>
      CallState(
        filter: filter ?? this.filter,
        screenSharing: screenSharing ?? this.screenSharing,
        screenStream: clearScreenStream ? null : (screenStream ?? this.screenStream),
        connectedAt: connectedAt ?? this.connectedAt,
        phase: phase ?? this.phase,
        conversationId: conversationId ?? this.conversationId,
        peerUserId: peerUserId ?? this.peerUserId,
        peerName: peerName ?? this.peerName,
        callType: callType ?? this.callType,
        localStream: localStream ?? this.localStream,
        remoteStream: remoteStream ?? this.remoteStream,
        micMuted: micMuted ?? this.micMuted,
        cameraOff: cameraOff ?? this.cameraOff,
        error: error,
      );
}

/// Lives for the whole signed-in session (not per-screen) so an incoming
/// call can be answered no matter which screen is open -- see app.dart's
/// wiring of this provider at the app root.
class CallController extends StateNotifier<CallState> {
  final Session session;
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  RTCPeerConnection? _pc;
  RTCSessionDescription? _pendingOffer;
  final List<RTCIceCandidate> _pendingRemoteIce = [];

  CallController(this.session) : super(const CallState()) {
    _wsSub = session.ws?.frames.listen(_onFrame);
  }

  void _onFrame(Map<String, dynamic> frame) async {
    switch (frame['type']) {
      case 'call-offer':
        if (state.isActive) {
          // Already on a call -- politely decline the second one, matching
          // the web client's single-active-call assumption.
          session.ws?.send({'type': 'call-decline', 'conversationId': frame['conversationId'], 'toUserId': frame['fromUserId']});
          return;
        }
        _pendingOffer = RTCSessionDescription(frame['sdp']['sdp'] as String, frame['sdp']['type'] as String);
        String peerName = 'Someone';
        try {
          final user = await session.api.getUser(frame['fromUserId'] as String);
          peerName = user['displayName'] as String? ?? peerName;
        } catch (_) {}
        state = state.copyWith(
          phase: CallPhase.incomingRinging,
          conversationId: frame['conversationId'] as String,
          peerUserId: frame['fromUserId'] as String,
          peerName: peerName,
          callType: frame['callType'] as String,
        );
        break;
      case 'call-answer':
        if (frame['conversationId'] != state.conversationId) return;
        final desc = RTCSessionDescription(frame['sdp']['sdp'] as String, frame['sdp']['type'] as String);
        await _pc?.setRemoteDescription(desc);
        await _drainPendingIce();
        state = state.copyWith(phase: CallPhase.connected);
        break;
      case 'call-decline':
      case 'call-end':
        if (frame['conversationId'] != state.conversationId) return;
        await _teardown();
        break;
      case 'call-ice':
        if (frame['conversationId'] != state.conversationId) return;
        final c = frame['candidate'] as Map<String, dynamic>;
        final candidate = RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?);
        if (_pc == null) {
          _pendingRemoteIce.add(candidate);
        } else {
          await _pc!.addCandidate(candidate);
        }
        break;
      case 'call-claimed':
        // Another of our own devices answered/declined first -- stop ringing here.
        if (state.phase == CallPhase.outgoingRinging) await _teardown();
        break;
      case 'call-error':
        // The server refused the call (e.g. the person is offline or blocked).
        final ctx = veyonNavigatorKey.currentContext;
        if (ctx != null) {
          ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(frame['error'] as String? ?? 'Call failed.')));
        }
        if (state.phase == CallPhase.outgoingRinging || state.phase == CallPhase.connecting) await _teardown();
        break;
    }
  }

  Future<void> _drainPendingIce() async {
    for (final c in _pendingRemoteIce) {
      await _pc!.addCandidate(c);
    }
    _pendingRemoteIce.clear();
  }

  Future<RTCPeerConnection> _createPeerConnection(String conversationId, String peerUserId) async {
    final pc = await createPeerConnection(_iceServers);
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      session.ws?.send({
        'type': 'call-ice',
        'conversationId': conversationId,
        'toUserId': peerUserId,
        'candidate': {'candidate': candidate.candidate, 'sdpMid': candidate.sdpMid, 'sdpMLineIndex': candidate.sdpMLineIndex},
      });
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        state = state.copyWith(remoteStream: event.streams.first, connectedAt: state.connectedAt ?? DateTime.now());
      }
    };
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _teardown();
      }
    };
    return pc;
  }

  Future<void> startCall({required String conversationId, required String peerUserId, required String peerName, required String callType}) async {
    if (state.isActive) return;
    state = state.copyWith(
      phase: CallPhase.outgoingRinging,
      conversationId: conversationId,
      peerUserId: peerUserId,
      peerName: peerName,
      callType: callType,
      error: null,
    );
    try {
      final localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': callType == 'video'});
      state = state.copyWith(localStream: localStream);
      _pc = await _createPeerConnection(conversationId, peerUserId);
      for (final track in localStream.getTracks()) {
        await _pc!.addTrack(track, localStream);
      }
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      session.ws?.send({
        'type': 'call-offer',
        'conversationId': conversationId,
        'toUserId': peerUserId,
        'callType': callType,
        'sdp': {'type': offer.type, 'sdp': offer.sdp},
      });
    } catch (e) {
      state = state.copyWith(phase: CallPhase.ended, error: 'Could not start the call: $e');
      await _teardown();
    }
  }

  Future<void> acceptCall() async {
    if (_pendingOffer == null || state.conversationId == null || state.peerUserId == null) return;
    state = state.copyWith(phase: CallPhase.connecting);
    try {
      final localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': state.callType == 'video'});
      state = state.copyWith(localStream: localStream);
      _pc = await _createPeerConnection(state.conversationId!, state.peerUserId!);
      for (final track in localStream.getTracks()) {
        await _pc!.addTrack(track, localStream);
      }
      await _pc!.setRemoteDescription(_pendingOffer!);
      await _drainPendingIce();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      session.ws?.send({
        'type': 'call-answer',
        'conversationId': state.conversationId,
        'toUserId': state.peerUserId,
        'sdp': {'type': answer.type, 'sdp': answer.sdp},
      });
      state = state.copyWith(phase: CallPhase.connected);
    } catch (e) {
      state = state.copyWith(error: 'Could not answer the call: $e');
      await declineCall();
    }
  }

  Future<void> declineCall() async {
    if (state.conversationId != null && state.peerUserId != null) {
      session.ws?.send({'type': 'call-decline', 'conversationId': state.conversationId, 'toUserId': state.peerUserId});
    }
    await _teardown();
  }

  Future<void> hangUp() async {
    if (state.conversationId != null && state.peerUserId != null) {
      session.ws?.send({'type': 'call-end', 'conversationId': state.conversationId, 'toUserId': state.peerUserId});
    }
    await _teardown();
  }

  Future<void> _teardown() async {
    final video = state.localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (video.isNotEmpty && video.first.id != null) {
      await _native.invokeMethod('forgetTrack', {'trackId': video.first.id}).catchError((_) => null);
    }
    if (state.screenSharing) await _stopScreenShare(restoreCamera: false);
    for (final track in state.localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _pc?.close();
    _pc = null;
    _pendingOffer = null;
    _pendingRemoteIce.clear();
    state = const CallState(phase: CallPhase.idle);
  }

  void toggleMic() {
    final tracks = state.localStream?.getAudioTracks() ?? const [];
    if (tracks.isEmpty) return;
    tracks.first.enabled = state.micMuted;
    state = state.copyWith(micMuted: !state.micMuted);
  }

  void toggleCamera() {
    final tracks = state.localStream?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return;
    tracks.first.enabled = state.cameraOff;
    state = state.copyWith(cameraOff: !state.cameraOff);
  }

  Future<void> switchCamera() async {
    if (state.screenSharing) return;
    final tracks = state.localStream?.getVideoTracks() ?? const [];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  // ── Video filters & screen share (native side: MainActivity.kt) ──────

  static const _native = MethodChannel('veyon/call');

  /// Same filters as the website. Applied to the outgoing camera frames,
  /// so the other person sees it too.
  Future<void> setFilter(String id) async {
    final tracks = state.localStream?.getVideoTracks() ?? const [];
    if (tracks.isEmpty || tracks.first.id == null) return;
    try {
      final ok = await _native.invokeMethod<bool>('setFilter', {'trackId': tracks.first.id, 'filter': id});
      if (ok == true) state = state.copyWith(filter: id);
    } catch (_) {
      state = state.copyWith(error: 'Filters aren\'t available on this phone.');
    }
  }

  Future<RTCRtpSender?> _findVideoSender() async {
    final senders = await _pc?.getSenders() ?? const <RTCRtpSender>[];
    return senders.where((s) => s.track?.kind == 'video').firstOrNull;
  }

  /// Share my screen instead of my camera (and back) — swaps the outgoing
  /// video without renegotiating, like the website.
  Future<void> toggleScreenShare() async {
    if (state.callType != 'video' || _pc == null) return;
    if (state.screenSharing) {
      await _stopScreenShare(restoreCamera: true);
      return;
    }
    try {
      // Android: ask for capture consent, then start the foreground service
      // it requires, then capture.
      final allowed = await Helper.requestCapturePermission();
      if (!allowed) return;
      await _native.invokeMethod('startScreenShareService');
      final screen = await navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
      final track = screen.getVideoTracks().first;
      final sender = await _findVideoSender();
      await sender?.replaceTrack(track);
      track.onEnded = () => _stopScreenShare(restoreCamera: true);
      state = state.copyWith(screenSharing: true, screenStream: screen);
    } catch (e) {
      await _native.invokeMethod('stopScreenShareService').catchError((_) => null);
      state = state.copyWith(error: 'Could not share your screen.');
    }
  }

  Future<void> _stopScreenShare({required bool restoreCamera}) async {
    final screen = state.screenStream;
    if (restoreCamera) {
      final camera = state.localStream?.getVideoTracks().firstOrNull;
      final sender = await _findVideoSender();
      if (camera != null) await sender?.replaceTrack(camera);
    }
    for (final t in screen?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _native.invokeMethod('stopScreenShareService').catchError((_) => null);
    state = state.copyWith(screenSharing: false, clearScreenStream: true);
  }

  /// Loudspeaker on/off.
  bool _speaker = false;
  bool get speakerOn => _speaker;
  Future<void> toggleSpeaker() async {
    _speaker = !_speaker;
    await Helper.setSpeakerphoneOn(_speaker);
    state = state.copyWith();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _teardown();
    super.dispose();
  }
}

final callControllerProvider = StateNotifierProvider<CallController, CallState>((ref) {
  final session = ref.watch(sessionControllerProvider);
  return CallController(session);
});
