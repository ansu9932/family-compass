import 'dart:async';
import 'notification_activity.dart';
import 'child_pin.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'internet_signal.dart';

const _captureService = MethodChannel('app.familycompass/media_capture');

class RemoteMediaPage extends StatefulWidget {
  const RemoteMediaPage({
    super.key,
    required this.parent,
    required this.secret,
    required this.relayUrl,
    this.deviceName = "Child phone",
    this.initialMode,
    this.onSetup,
  });
  final bool parent;
  final String secret;
  final String relayUrl;
  final String deviceName;
  final String? initialMode;
  final Future<void> Function()? onSetup;
  @override
  State<RemoteMediaPage> createState() => _RemoteMediaPageState();
}

class _RemoteMediaPageState extends State<RemoteMediaPage>
    with WidgetsBindingObserver {
  late final InternetSignalClient _signal;
  final _renderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  MediaStream? _local;
  Timer? _poll;
  bool _polling = false, _busy = false, _active = false;
  bool _rememberParentConsent = false;
  bool _available = false, _changingAvailability = false;
  Map<String, dynamic>? _pendingRequest;
  Timer? _pendingExpiry;
  int _captureRevision = 0;
  bool _connected = false, _flipping = false;
  bool _leaving = false;
  String? _relayError;
  Timer? _audioStats;
  Timer? _disconnectTimer;
  Timer? _iceRetryTimer;
  Timer? _videoStats;
  bool _restartingIce = false;
  int _iceAttempts = 0, _iceNegotiation = 0, _remoteIceNegotiation = 0;
  String _videoStatus = 'Waiting for video frames…';
  int _audioBytes = 0;
  String _audioStatus = 'Waiting for audio packets…';
  String _captureStage = 'capture';
  String? _consentKey;
  Timer? _flipTimeout;
  String? _session, _mode, _error;
  bool _remoteDescriptionSet = false;
  String _status = 'Connecting to the secure relay…';
  final Set<String> _seenMessages = {};
  Timer? _requestTimeout;
  Timer? _connectionTimeout;
  static const _parentConsentPreference = 'remote_media_parent_auto_accept_v1';
  bool get _parent => widget.parent;
  static const _labels = {
    'camera': 'Remote camera',
    'screen': 'Screen mirroring',
    'audio': 'One-way audio',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _signal = InternetSignalClient(
      baseUrl: widget.relayUrl,
      sharedSecret: widget.secret,
      role: _parent ? 'parent' : 'child',
    );
    if (Platform.isAndroid) {
      _captureService.setMethodCallHandler(_nativeEvent);
    }
    _init();
  }

  Future<void> _init() async {
    try {
      await _renderer.initialize();
      if (Platform.isAndroid) {
        _available =
            await _captureService.invokeMethod<bool>('availabilityStatus') ??
            false;
      }
      final preferences = await SharedPreferences.getInstance();
      _consentKey = '$_parentConsentPreference:${await _signal.room}';
      final rememberConsent = preferences.getBool(_consentKey!) ?? false;
      if (!mounted) return;
      setState(() {
        _rememberParentConsent = rememberConsent;
        _status = _parent
            ? 'Choose a feature. Saved approval on the child phone skips the app prompt.'
            : 'Waiting for a request from the paired parent.';
      });
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pollOnce());
      await _pollOnce();
      if (mounted && _parent && widget.initialMode != null)
        await _request(widget.initialMode!);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start remote media: $e');
    }
  }

  Future<void> _send(
    String kind, {
    String? mode,
    String? sdp,
    String? reason,
    String? sessionId,
    int? negotiation,
  }) async {
    await _signal.send({
      'messageId': base64UrlEncode(
        List<int>.generate(18, (_) => Random.secure().nextInt(256)),
      ),
      'id': sessionId ?? _session,
      'sessionId': sessionId ?? _session,
      'kind': kind,
      if (negotiation != null) 'negotiation': negotiation,
      'mode': mode ?? _mode,
      'sdp': sdp,
      if (reason != null) 'reason': reason,
      'type': kind == 'offer'
          ? 'offer'
          : kind == 'answer'
          ? 'answer'
          : null,
      'sentAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _pollOnce() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      if (!_parent && !_available && !await _childVisible()) return;
      if (!_parent && _active && _mode == 'screen' && await _isLocked()) {
        await _screenEnded();
      }
      final m = await _signal.receive();
      if (mounted && _relayError != null) setState(() => _relayError = null);
      if (m != null) await _handle(m);
    } catch (e) {
      if (mounted && !_active) {
        setState(
          () => _relayError = 'Internet connection interrupted. Reconnecting…',
        );
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _handle(Map<String, dynamic> m) async {
    final id = m['sessionId'];
    final messageId = m['messageId'];
    final sent = m['sentAt'];
    if (id is! String ||
        id.isEmpty ||
        messageId is! String ||
        sent is! String) {
      return;
    }
    final at = DateTime.tryParse(sent)?.toUtc();
    if (at == null ||
        DateTime.now().toUtc().difference(at).abs() >
            const Duration(minutes: 2) ||
        _seenMessages.contains(messageId)) {
      return;
    }
    _seenMessages.add(messageId);
    if (_seenMessages.length > 128) {
      _seenMessages.remove(_seenMessages.first);
    }
    final kind = m['kind'] as String?;
    if ((kind == 'stop' || kind == 'locked' || kind == 'capture-ended') &&
        id == _session) {
      _requestTimeout?.cancel();
      await _cleanup();
      if (mounted) {
        setState(
          () => _status = kind == 'locked'
              ? 'Child phone is locked. Unlock it and start a new sharing session.'
              : kind == 'capture-ended'
              ? 'Android ended screen sharing. Start a new session on the child phone.'
              : 'Session stopped.',
        );
      }
      return;
    }
    if (id == _session && (kind == 'ice-offer' || kind == 'ice-answer')) {
      await _handleIceRecovery(m);
      return;
    }
    if (_parent) {
      if (id != _session) return;
      if (kind == 'flipped' || kind == 'flip-failed') {
        _flipTimeout?.cancel();
        setState(() {
          _flipping = false;
          _status = kind == 'flipped'
              ? 'Camera switched.'
              : 'Camera could not switch. Try again.';
        });
        return;
      }
      if (kind == 'needs-child-action') {
        setState(
          () => _status =
              m['reason'] as String? ??
              'Open the request notification on Android.',
        );
        return;
      }
      if (kind == 'capture-error') {
        final reason = m['reason'];
        await _cleanup();
        if (mounted)
          setState(
            () => _error = reason is String
                ? reason
                : 'The child could not start sharing.',
          );
        return;
      }
      if (kind == 'decline' && id == _session) {
        _requestTimeout?.cancel();
        if (mounted) {
          setState(() => _status = 'The child declined this request.');
        }
        _session = null;
        return;
      }
      if (kind == 'offer' && !_active) {
        _requestTimeout?.cancel();
        await _answer(m);
      }
      if (kind == 'answer' && !_remoteDescriptionSet) {
        await _pc?.setRemoteDescription(
          RTCSessionDescription(m['sdp'] as String?, 'answer'),
        );
        _remoteDescriptionSet = true;
        if (mounted) {
          setState(() => _status = 'Connecting directly to the child phone…');
        }
      }
      return;
    }
    if (kind == 'flip' && id == _session && _mode == 'camera' && _connected) {
      try {
        final track = _local!.getVideoTracks().first;
        await Helper.switchCamera(track);
        await _focusCamera(track);
        await _send('flipped');
      } catch (_) {
        await _send('flip-failed');
      }
      return;
    }
    if (kind == 'request' &&
        !_changingAvailability &&
        !_active &&
        !_busy &&
        _pendingRequest == null) {
      final mode = m['mode'];
      if (mode is! String || !_labels.containsKey(mode)) return;
      _session = id;
      _mode = mode;
      if (mode == 'screen' && await _isLocked()) {
        await _send('locked');
        await _cleanup();
        return;
      }
      final visible = await _childVisible();
      if (!visible &&
          (mode == 'screen' || !_rememberParentConsent || !_available)) {
        _pendingRequest = m;
        if (mounted) setState(() => _busy = true);
        await _captureService.invokeMethod<void>('notifyMediaRequest', {
          'mode': mode,
        });
        await _send(
          'needs-child-action',
          reason: mode == 'screen'
              ? 'Open the screen-sharing notification on Android and confirm Android’s sharing prompt.'
              : 'Open the request notification on Android to start this session.',
        );
        _pendingExpiry?.cancel();
        _pendingExpiry = Timer(const Duration(seconds: 85), () {
          if (_pendingRequest != null) unawaited(_stop());
        });
        return;
      }
      await _acceptAndCapture(mode);
    } else if (kind == 'answer' && id == _session && !_remoteDescriptionSet) {
      await _pc?.setRemoteDescription(
        RTCSessionDescription(m['sdp'] as String?, 'answer'),
      );
      _remoteDescriptionSet = true;
      if (mounted) setState(() => _status = 'Connecting to the parent…');
    }
  }

  Future<bool> _childVisible() async =>
      !Platform.isAndroid ||
      (await _captureService.invokeMethod<bool>('isAppVisible') ?? false);

  Future<void> _nativeEvent(MethodCall call) async {
    if (!mounted) return;
    if (call.method == 'appVisible') {
      await _resumePending();
      unawaited(_pollOnce());
    } else if (call.method == 'availabilityChanged') {
      setState(() {
        _available = call.arguments == true;
        _changingAvailability = false;
      });
      if (!_available && (_active || _pendingRequest != null)) await _stop();
    } else if (call.method == 'availabilityStopped') {
      setState(() {
        _available = false;
        _changingAvailability = false;
      });
      await _stop();
      if (mounted)
        setState(
          () => _status =
              'Availability stopped. Re-enable Keep available to receive requests with this screen closed.',
        );
    } else if (call.method == 'screenSharingStopped') {
      if (_mode == 'screen') await _stop();
    } else if (call.method == 'availabilityError') {
      setState(() {
        _available = false;
        _changingAvailability = false;
        _error = call.arguments as String?;
      });
      await _stop();
    }
  }

  Future<void> _resumePending() async {
    final pending = _pendingRequest;
    if (pending == null || !await _childVisible()) return;
    if (_pendingRequest != pending) return;
    _pendingRequest = null;
    _pendingExpiry?.cancel();
    await _captureService.invokeMethod<void>('clearMediaRequest');
    final sent = DateTime.tryParse(pending['sentAt'] as String? ?? '');
    if (sent == null ||
        DateTime.now().toUtc().difference(sent).abs() >
            const Duration(seconds: 85)) {
      await _stop();
      return;
    }
    await _acceptAndCapture(pending['mode'] as String);
  }

  Future<void> _acceptAndCapture(String mode) async {
    if (!mounted) return;
    final session = _session;
    setState(() => _busy = true);
    final accepted =
        _rememberParentConsent ||
        (await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (c) => AlertDialog(
                title: Text('${_labels[mode]} request'),
                content: const Text(
                  'Your paired parent wants a live session. You can stop sharing at any time.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('Decline'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('Accept this session'),
                  ),
                ],
              ),
            ) ??
            false);
    if (!mounted || session != _session) return;
    if (!accepted) {
      await _send('decline');
      await _cleanup();
      if (mounted) setState(() => _status = 'Request declined.');
      return;
    }
    setState(
      () => _status =
          'Starting ${_labels[mode]}. You can stop sharing at any time.',
    );
    await _captureAndOffer(mode);
  }

  Future<void> _setAvailability(bool enabled) async {
    if (_changingAvailability) return;
    setState(() {
      _changingAvailability = true;
      _error = null;
    });
    try {
      if (enabled) {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Keep available to your parent?'),
            content: const Text(
              'While the persistent notification is present, your paired parent can start the camera or microphone even when this app screen is closed. Android’s camera and microphone indicators remain visible. Stop availability from the notification or this switch. Screen sharing always needs Android confirmation. Re-enable after a restart or Force stop. This uses extra battery.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Enable Keep available'),
              ),
            ],
          ),
        );
        if (accepted != true || !mounted) return;
        for (final permission in ['camera', 'microphone', 'notifications']) {
          await _captureService.invokeMethod<void>('requestMediaPermission', {
            'permission': permission,
          });
        }
        await _setRememberParentConsent(true);
        if (!_rememberParentConsent) return;
        await _captureService.invokeMethod<void>('enableAvailability');
      } else {
        await _stop();
        await _captureService.invokeMethod<void>('disableAvailability');
        if (mounted) setState(() => _available = false);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not change availability: $e');
    } finally {
      if (mounted) setState(() => _changingAvailability = false);
    }
  }

  Future<void> _request(String mode) async {
    if (_busy || _active || _session != null) return;
    setState(() {
      _busy = true;
      _error = null;
      _connected = false;
    });
    try {
      _session = base64UrlEncode(
        List<int>.generate(24, (_) => Random.secure().nextInt(256)),
      );
      _mode = mode;
      _remoteDescriptionSet = false;
      await _send('request');
      final requestedSession = _session;
      _requestTimeout?.cancel();
      _requestTimeout = Timer(const Duration(seconds: 90), () async {
        if (!mounted || _session != requestedSession || _active) return;
        await _stop();
        if (!mounted) return;
        setState(() {
          _status =
              'Child phone did not respond. Check its internet and Keep available notification. Reopen the child app after Force stop or a restart.';
        });
      });
      if (mounted) {
        setState(
          () => _status =
              'Request sent. Waiting for the child phone. Saved approval skips the app prompt; screen sharing needs Android confirmation.',
        );
      }
    } catch (e) {
      await _cleanup();
      if (mounted) setState(() => _error = 'Could not send request: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setRememberParentConsent(bool enabled) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_consentKey!, enabled);
      if (!mounted) return;
      setState(() => _rememberParentConsent = enabled);
      if (!enabled && _available) await _setAvailability(false);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not save this setting: $e');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_parent) unawaited(_resumePending());
      unawaited(_pollOnce());
      if (_parent && _connected && _mode == 'audio')
        unawaited(_preparePlayback());
    }
  }

  Future<void> _preparePlayback() async {
    try {
      if (Platform.isIOS) {
        // Receive-only audio must not request the parent's microphone.
        await Helper.setAppleAudioIOMode(AppleAudioIOMode.remoteOnly);
        await Helper.ensureAudioSession();
      } else {
        await Helper.setSpeakerphoneOn(true);
      }
    } catch (_) {
      if (mounted)
        setState(
          () => _error =
              'Audio output could not start. Disconnect Bluetooth audio and retry.',
        );
    }
  }

  void _watchAudio(RTCPeerConnection pc) {
    _audioStats?.cancel();
    _audioBytes = 0;
    _audioStats = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_pc != pc || !mounted || !_connected) return;
      try {
        final stats = await pc.getStats();
        var bytes = 0;
        for (final report in stats) {
          if (report.type == 'inbound-rtp' &&
              (report.values['kind'] == 'audio' ||
                  report.values['mediaType'] == 'audio')) {
            final value = report.values['bytesReceived'];
            if (value is num) bytes += value.toInt();
          }
        }
        if (!mounted || _pc != pc) return;
        setState(() {
          _audioStatus = bytes > _audioBytes
              ? 'Live audio is arriving. Use the iPhone volume buttons to adjust it.'
              : 'Connected, but no new audio packets. Check the Android microphone and internet.';
          _audioBytes = bytes;
        });
      } catch (_) {
        /* A peer can close while its stats request is in flight. */
      }
    });
  }

  Future<RTCPeerConnection> _newPeer() async {
    final expectedSession = _session;
    final iceServers = await _signal.iceServers();
    if (expectedSession != _session) throw StateError('Session cancelled');
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    if (expectedSession != _session) {
      await pc.close();
      await pc.dispose();
      throw StateError('Session cancelled');
    }
    _pc = pc;
    _connectionTimeout?.cancel();
    _connectionTimeout = Timer(const Duration(seconds: 60), () async {
      if (_pc != pc || _connected) return;
      await _stop();
      if (mounted) {
        setState(
          () => _error =
              'Media could not connect through direct or relay routes. Check both phones’ internet connection and retry.',
        );
      }
    });
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _renderer.srcObject = event.streams.first;
        if (_parent && _mode == 'audio') {
          unawaited(_preparePlayback());
          for (final track in event.streams.first.getAudioTracks()) {
            track.enabled = true;
            unawaited(Helper.setVolume(1.0, track).catchError((Object _) {}));
          }
        }
        if (mounted) setState(() => _active = true);
      }
    };
    pc.onConnectionState = (state) {
      if (!mounted || _pc != pc) return;
      _connected =
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      if (_connected) {
        _disconnectTimer?.cancel();
        _disconnectTimer = null;
        _iceRetryTimer?.cancel();
        _iceAttempts = 0;
        if (_parent && _mode != 'audio') _watchVideo(pc);
        if (_parent && _mode == 'audio') {
          unawaited(_preparePlayback());
          _watchAudio(pc);
        }
        _requestTimeout?.cancel();
        _connectionTimeout?.cancel();
      }
      setState(
        () => _status =
            state == RTCPeerConnectionState.RTCPeerConnectionStateConnected
            ? 'Session connected. The child can stop it at any time.'
            : state == RTCPeerConnectionState.RTCPeerConnectionStateFailed
            ? 'Network changed. Recovering the connection…'
            : 'Connecting to child media…',
      );
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _disconnectTimer ??= Timer(const Duration(seconds: 60), () async {
          if (_pc != pc || _connected) return;
          await _stop();
          if (mounted)
            setState(
              () => _error =
                  'Connection could not recover. Check both phones are online and try again. Pairing is still saved.',
            );
        });
        if (!_parent && !_restartingIce && _iceRetryTimer?.isActive != true) {
          _iceRetryTimer = Timer(
            const Duration(seconds: 3),
            () => _restartIce(pc),
          );
        }
      }
    };
    return pc;
  }

  Future<void> _restartIce(RTCPeerConnection pc) async {
    if (_pc != pc ||
        _connected ||
        _restartingIce ||
        _local == null ||
        _iceAttempts >= 3)
      return;
    final session = _session;
    if (session == null) return;
    _restartingIce = true;
    _iceAttempts++;
    final negotiation = ++_iceNegotiation;
    if (mounted)
      setState(() => _status = 'Recovering the internet connection…');
    try {
      final servers = await _signal.iceServers();
      if (_pc != pc) return;
      await pc.setConfiguration({
        'iceServers': servers,
        'sdpSemantics': 'unified-plan',
      });
      final offer = await pc.createOffer({'iceRestart': true});
      final local = await _gather(pc, offer);
      if (_pc != pc || _session != session) return;
      await _send(
        'ice-offer',
        sdp: local.sdp,
        sessionId: session,
        negotiation: negotiation,
      );
    } on Object {
      // The same visible session gets bounded retries when the network returns.
    } finally {
      if (_pc == pc) {
        _restartingIce = false;
        if (!_connected && _iceAttempts < 3) {
          _iceRetryTimer?.cancel();
          _iceRetryTimer = Timer(
            const Duration(seconds: 12),
            () => _restartIce(pc),
          );
        }
      }
    }
  }

  Future<void> _handleIceRecovery(Map<String, dynamic> message) async {
    final pc = _pc;
    final session = _session;
    final negotiation = message['negotiation'];
    final sdp = message['sdp'];
    if (pc == null || session == null || negotiation is! int || sdp is! String)
      return;
    try {
      if (_parent && message['kind'] == 'ice-offer') {
        if (negotiation <= _remoteIceNegotiation) return;
        _remoteIceNegotiation = negotiation;
        final servers = await _signal.iceServers();
        if (_pc != pc) return;
        await pc.setConfiguration({
          'iceServers': servers,
          'sdpSemantics': 'unified-plan',
        });
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
        final answer = await _gather(pc, await pc.createAnswer());
        if (_pc != pc || _session != session) return;
        await _send(
          'ice-answer',
          sdp: answer.sdp,
          sessionId: session,
          negotiation: negotiation,
        );
      } else if (!_parent &&
          message['kind'] == 'ice-answer' &&
          negotiation == _iceNegotiation) {
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      }
    } on Object {
      // A stale answer or transient network failure must not restart capture.
    }
  }

  Future<void> _focusCamera(MediaStreamTrack track) async {
    try {
      await Helper.setFocusMode(track, CameraFocusMode.auto);
    } on Object {
      // Fixed-focus/unsupported cameras retain their native focus defaults.
    }
  }

  Future<void> _configureCameraSender(RTCPeerConnection pc) async {
    for (final sender in await pc.getSenders()) {
      if (sender.track?.kind != 'video') continue;
      final parameters = sender.parameters;
      if (parameters.encodings?.isEmpty ?? true) continue;
      parameters.degradationPreference =
          RTCDegradationPreference.MAINTAIN_RESOLUTION;
      for (final encoding in parameters.encodings!) {
        encoding.maxBitrate = 6000000;
        encoding.maxFramerate = 30;
        encoding.scaleResolutionDownBy = 1.0;
      }
      try {
        await sender.setParameters(parameters);
      } on Object {
        // The encoder may reject tuning; keep its working adaptive defaults.
      }
    }
  }

  void _watchVideo(RTCPeerConnection pc) {
    _videoStats?.cancel();
    _videoStats = Timer.periodic(const Duration(seconds: 3), (_) async {
      try {
        final reports = await pc.getStats();
        if (!mounted || _pc != pc) return;
        for (final report in reports) {
          if (report.type != 'inbound-rtp' ||
              (report.values['kind'] ?? report.values['mediaType']) != 'video')
            continue;
          final width = report.values['frameWidth'];
          final height = report.values['frameHeight'];
          final fps = report.values['framesPerSecond'];
          if (width is num && height is num && width > 0 && height > 0) {
            setState(
              () => _videoStatus =
                  '$width × $height${fps is num ? ' · ${fps.round()} fps' : ''} · Quality adapts to your connection',
            );
          }
        }
      } on Object {}
    });
  }

  Future<RTCSessionDescription> _gather(
    RTCPeerConnection pc,
    RTCSessionDescription desc,
  ) async {
    final done = Completer<void>();
    Timer? relayReady;
    // A TURN candidate already gives both phones a reachable route. Allow a
    // short window for other candidates instead of waiting for bad adapters.
    pc.onIceCandidate = (candidate) {
      if ((candidate.candidate ?? '').contains(' typ relay ') &&
          relayReady == null) {
        relayReady = Timer(const Duration(milliseconds: 300), () {
          if (!done.isCompleted) done.complete();
        });
      }
    };
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !done.isCompleted) {
        done.complete();
      }
    };
    await pc.setLocalDescription(desc);
    try {
      await done.future.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      // Use the candidates gathered so far rather than stalling the request.
    } finally {
      relayReady?.cancel();
      pc.onIceCandidate = null;
      pc.onIceGatheringState = null;
    }
    return (await pc.getLocalDescription()) ?? desc;
  }

  Future<void> _captureAndOffer(String mode) async {
    final revision = _captureRevision;
    _captureStage = 'permission';
    try {
      if (Platform.isAndroid && mode != 'screen') {
        final requiredPermission = mode == 'audio' ? 'microphone' : 'camera';
        var permissions = await _captureService
            .invokeMapMethod<String, dynamic>('permissionStatus');
        if (permissions?[requiredPermission] != true) {
          await _captureService.invokeMethod<void>('requestMediaPermission', {
            'permission': requiredPermission,
          });
          permissions = await _captureService.invokeMapMethod<String, dynamic>(
            'permissionStatus',
          );
          if (permissions?[requiredPermission] != true)
            throw StateError(
              '$requiredPermission permission is off on Android. Open Child setup → App permissions.',
            );
        }
      }
      if (revision != _captureRevision) return;
      _captureStage = 'capture';
      final media = mode == 'camera'
          ? await navigator.mediaDevices.getUserMedia({
              'audio': false,
              'video': {
                'facingMode': 'environment',
                'width': 1920,
                'height': 1080,
                'frameRate': 30,
              },
            })
          : mode == 'screen'
          ? await navigator.mediaDevices.getDisplayMedia({
              'audio': false,
              'video': true,
            })
          : await navigator.mediaDevices.getUserMedia({
              'audio': {
                'echoCancellation': true,
                'noiseSuppression': true,
                'autoGainControl': true,
              },
              'video': false,
            });
      if (revision != _captureRevision) {
        for (final track in media.getTracks()) {
          await track.stop();
        }
        await media.dispose();
        return;
      }
      _local = media;
      if (mode == 'camera') {
        if (media.getVideoTracks().isEmpty)
          throw StateError('Android did not provide a camera track.');
        await _focusCamera(media.getVideoTracks().first);
      }
      if (mode == 'audio' && media.getAudioTracks().isEmpty)
        throw StateError('Android did not provide a microphone track.');
      _captureStage = 'foreground';
      if (Platform.isAndroid && mode != 'screen') {
        await _captureService.invokeMethod<void>('startCaptureService', {
          'mode': mode == 'camera' ? 'camera' : 'microphone',
        });
      }
      if (mode == 'screen') {
        media.getVideoTracks().first.onEnded = () {
          unawaited(_screenEnded());
        };
      }
      if (revision != _captureRevision) return;
      _captureStage = 'connection';
      final pc = await _newPeer();
      for (final track in media.getTracks()) {
        await pc.addTrack(track, media);
      }
      final offer = await pc.createOffer();
      final local = await _gather(pc, offer);
      if (mode == 'camera') await _configureCameraSender(pc);
      if ((local.sdp ?? '').length > 32000) {
        throw StateError('Signal data is too large.');
      }
      if (revision != _captureRevision) return;
      _captureStage = 'signaling';
      await _send('offer', sdp: local.sdp);
      if (revision != _captureRevision) return;
      if (mounted) {
        setState(() {
          _active = true;
          _status = mode == 'screen'
              ? 'Screen sharing is active. Return here to stop.'
              : 'Capture is active. Return here to stop.';
        });
      }
    } catch (e) {
      if (revision != _captureRevision) return;
      final message = _captureFailure(e);
      try {
        await _send('capture-error', reason: message);
      } on Object {
        // The relay may already be unavailable after a capture denial.
      }
      await _cleanup();
      if (mounted) {
        setState(() => _error = message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _captureFailure(Object error) {
    final text = error.toString();
    if (_captureStage == 'permission')
      return text.replaceFirst('Bad state: ', '');
    if (_captureStage == 'capture')
      return _mode == 'audio'
          ? 'Android could not open the microphone. Turn on Microphone access in Quick Settings, close other recording or calling apps, and retry. Details: $text'
          : _mode == 'camera'
          ? 'Android could not open the camera. Check Camera access in Quick Settings and close other camera apps. For background access, open the child app and enable Keep available. Details: $text'
          : 'Android did not start sharing. Confirm its screen-sharing prompt. Details: $text';
    if (_captureStage == 'foreground')
      return 'Android could not keep capture running. Keep Family Compass Child visible and retry. Details: $text';
    return 'Capture opened, but the internet connection setup failed. Check both phones are online and retry. Details: $text';
  }

  Future<void> _answer(Map<String, dynamic> m) async {
    try {
      if (_mode == 'audio') await _preparePlayback();
      final pc = await _newPeer();
      await pc.setRemoteDescription(
        RTCSessionDescription(m['sdp'] as String?, 'offer'),
      );
      _remoteDescriptionSet = true;
      final answer = await pc.createAnswer();
      final local = await _gather(pc, answer);
      await _send('answer', sdp: local.sdp);
      if (mounted) setState(() => _status = 'Connecting to child media…');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not connect: $e');
      await _cleanup();
    }
  }

  Future<bool> _isLocked() async {
    if (!Platform.isAndroid) return false;
    return await _captureService.invokeMethod<bool>('isDeviceLocked') ?? false;
  }

  Future<void> _screenEnded() async {
    if (_session == null) return;
    final locked = await _isLocked();
    try {
      await _send(locked ? 'locked' : 'capture-ended');
    } catch (_) {}
    await _cleanup();
    if (mounted) {
      setState(
        () => _status = locked
            ? 'Phone locked. Screen sharing stopped.'
            : 'Android ended screen sharing.',
      );
    }
  }

  Future<void> _flipCamera() async {
    if (!_connected || _mode != 'camera' || _flipping) return;
    setState(() => _flipping = true);
    try {
      await _send('flip');
      _flipTimeout = Timer(const Duration(seconds: 15), () {
        if (mounted) {
          setState(() {
            _flipping = false;
            _error = 'Camera switch was not confirmed. Try again.';
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _flipping = false;
          _error = 'Could not switch camera: $e';
        });
      }
    }
  }

  Future<void> _stop({bool notify = true}) async {
    final session = _session, mode = _mode;
    // Stop capture immediately; a slow network must not delay the Stop control.
    await _cleanup();
    if (mounted) setState(() => _status = 'Session stopped.');
    if (notify && session != null) {
      try {
        await _send('stop', sessionId: session, mode: mode);
      } on Object {}
    }
  }

  Future<void> _cleanup() async {
    _captureRevision++;
    _pendingRequest = null;
    _pendingExpiry?.cancel();
    _busy = false;
    if (Platform.isAndroid) {
      try {
        await _captureService.invokeMethod<void>('clearMediaRequest');
      } on Object {}
    }
    _audioStats?.cancel();
    _videoStats?.cancel();
    _videoStatus = 'Waiting for video frames…';
    _iceRetryTimer?.cancel();
    _restartingIce = false;
    _iceAttempts = 0;
    _iceNegotiation = 0;
    _remoteIceNegotiation = 0;
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    _requestTimeout?.cancel();
    _connectionTimeout?.cancel();
    _active = false;
    _connected = false;
    _flipping = false;
    _flipTimeout?.cancel();
    _session = null;
    _remoteDescriptionSet = false;
    final previousMode = _mode;
    _mode = null;
    for (final track in _local?.getTracks() ?? <MediaStreamTrack>[]) {
      try {
        await track.stop();
      } on Object {
        // The native track may already have ended.
      }
    }
    try {
      await _local?.dispose();
    } on Object {
      // Continue closing the peer even if native stream disposal fails.
    }
    _local = null;
    _renderer.srcObject = null;
    final peer = _pc;
    _pc = null;
    try {
      await peer?.close();
      await peer?.dispose();
    } on Object {
      // Native peer resources can already be disposed after a transport error.
    }
    if (_parent && previousMode == 'audio') {
      try {
        if (Platform.isIOS) {
          await Helper.setAppleAudioIOMode(AppleAudioIOMode.none);
        } else {
          await Helper.setSpeakerphoneOn(false);
        }
      } on Object {
        // Audio routing can already be gone when the peer closes.
      }
    }
    if (Platform.isAndroid) {
      try {
        await _captureService.invokeMethod<void>('stopCaptureService');
      } on Object {
        // The Android service may already have stopped with the capture.
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _pendingExpiry?.cancel();
    if (Platform.isAndroid) {
      _captureService.setMethodCallHandler(null);
      unawaited(_captureService.invokeMethod<void>('disableAvailability'));
    }
    unawaited(_cleanup());
    _signal.close();
    unawaited(_renderer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _leaving || (!_active && _session == null && !_busy),
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop || _leaving) return;
      await _stop();
      if (!mounted) return;
      setState(() => _leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(_parent ? widget.deviceName : 'Family Compass Child'),
        actions: [
          if (!_parent)
            IconButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<bool>(builder: (_) => const ChildPinSetup()),
              ),
              icon: const Icon(Icons.password),
              tooltip: 'Change app PIN',
            ),
          if (!_parent && !_active && !_busy && widget.onSetup != null)
            IconButton(
              onPressed: () async {
                await _setAvailability(false);
                await widget.onSetup?.call();
              },
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Setup and permissions',
            ),
          if (_active || _session != null)
            IconButton(
              onPressed: () => _stop(),
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: 'Stop session',
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          if (_relayError != null)
            Text(_relayError!, style: const TextStyle(color: Colors.orange)),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red)),
          if (!_parent) ...[
            Text(
              widget.deviceName,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ChildActivitySettings(
                    secret: widget.secret,
                    relayUrl: widget.relayUrl,
                  ),
                ),
              ),
              icon: const Icon(Icons.notifications_none),
              label: const Text('Notification activity settings'),
            ),
          ],
          Text(_status),
          if (_parent && _session != null && !_connected) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(
              semanticsLabel: 'Connecting to child phone',
            ),
            const SizedBox(height: 8),
            const Text(
              'Keep both phones online. Connection can take a few seconds.',
            ),
          ],
          if (_parent && _connected && _mode == 'camera')
            OutlinedButton.icon(
              onPressed: _flipping ? null : _flipCamera,
              icon: const Icon(Icons.flip_camera_android),
              label: Text(_flipping ? 'Switching camera…' : 'Flip camera'),
            ),
          const SizedBox(height: 18),
          if (_parent && _active && _mode != 'audio')
            AspectRatio(
              aspectRatio: 9 / 16,
              child: RTCVideoView(
                _renderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
            ),
          if (_parent && _active && _mode != 'audio') Text(_videoStatus),
          if (_active && _mode == 'audio') ...[
            const Icon(Icons.volume_up, size: 72),
            if (_parent && _connected) Text(_audioStatus),
          ],
          if (_parent && !_active && _session == null) ...[
            _modeButton('camera', Icons.camera_alt_outlined),
            _modeButton('screen', Icons.screen_share_outlined),
            _modeButton('audio', Icons.headphones_outlined),
          ],
          if (!_parent && !_active) ...[
            SwitchListTile(
              value: _available,
              onChanged: _busy || _changingAvailability
                  ? null
                  : (value) => unawaited(_setAvailability(value)),
              title: const Text('Keep available when app screen is closed'),
              subtitle: Text(
                _available
                    ? 'Available to your paired parent. Stop here or from the persistent notification.'
                    : 'Enable while this screen is open. A visible service keeps camera and audio available after leaving the app.',
              ),
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              value: _rememberParentConsent,
              onChanged: _busy || _consentKey == null
                  ? null
                  : (enabled) => unawaited(_setRememberParentConsent(enabled)),
              title: const Text('Allow this parent to start sessions'),
              subtitle: const Text(
                'After you enable this once, camera and audio requests start automatically. Android may ask for camera or microphone access the first time. Screen sharing still needs Android’s confirmation each time.',
              ),
            ),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Your paired parent can see battery, charging and Wi-Fi/mobile-data status while this app is available. Keep the phone online. With Keep available enabled, you can leave or close the app screen; its visible service continues running. Screen requests show a notification: tap it and confirm Android’s prompt. Force stop, a restart, or Android stopping the service requires reopening this app. Availability can use extra battery and cannot guarantee a one-second connection.',
                ),
              ),
            ),
          ],
          if (_active)
            OutlinedButton.icon(
              onPressed: () => _stop(),
              icon: const Icon(Icons.stop),
              label: const Text('Stop sharing now'),
            ),
        ],
      ),
    ),
  );
  Widget _modeButton(String mode, IconData icon) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: FilledButton.icon(
      onPressed: _busy || _active ? null : () => _request(mode),
      icon: Icon(icon),
      label: Text(_busy ? 'Waiting…' : 'Request ${_labels[mode]}'),
    ),
  );
}
