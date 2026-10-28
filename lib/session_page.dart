import 'dart:async';
import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/io.dart';

import 'dhlive_api.dart';

/// Runs one Digital Human session: creates the platform session (demo mode),
/// keeps the control WebSocket, joins the RTC channel and renders the avatar.
///
/// Production apps should keep [DhliveApi] and the control WebSocket on their
/// backend and receive only the `rtc` credentials in the app. See README.md.
class SessionPage extends StatefulWidget {
  const SessionPage({
    super.key,
    this.api,
    this.hostId,
    this.userId,
    this.rtcOnly,
  }) : assert(api != null || rtcOnly != null);

  /// Demo mode: the app itself creates the session and holds the control WS.
  final DhliveApi? api;
  final String? hostId;
  final String? userId;

  /// RTC-only mode: credentials produced by a customer backend.
  final RtcCredentials? rtcOnly;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  final List<String> _logs = <String>[];
  final ScrollController _logScroll = ScrollController();

  String _status = '准备中…';
  String? _sessionId;
  PlatformSession? _session;
  IOWebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsEvents;

  RtcEngine? _engine;
  RtcConnection? _connection;
  int? _remoteUid;
  bool _joined = false;
  bool _muted = false;
  bool _ending = false;
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    try {
      final rtc = widget.rtcOnly ?? await _createPlatformSession();
      if (!mounted) return;
      await _joinRtc(rtc);
    } catch (error) {
      _log('启动失败：$error');
      if (mounted) setState(() => _status = '失败：$error');
    }
  }

  Future<RtcCredentials> _createPlatformSession() async {
    final api = widget.api!;
    final hostId = widget.hostId!.trim();

    _log('创建会话：POST ${api.baseUrl}/v1/hosts/$hostId/sessions');
    final created = await api.createSession(
      hostId: hostId,
      userId: widget.userId,
      timezone: 'Asia/Shanghai',
    );
    _sessionId = created.id;
    _session = created;
    _log('会话 ${created.id} 已创建，状态 ${created.status}；等待 ready…');
    // `rtc`/`websocket` only exist on this create response (201); GET polling
    // returns a public view with those fields stripped.
    if (mounted) setState(() => _status = '等待主播准备（${created.status}）');

    final ready = await api.waitUntilReady(
      created,
      onPoll: (session) {
        _log('轮询状态：${session.status}');
        if (mounted) setState(() => _status = '等待主播准备（${session.status}）');
      },
    );
    _session = ready;
    _log('会话 ready，rtc provider=${ready.rtc.provider}（凭据取自创建响应）');

    await _connectControlWebSocket(ready);
    return ready.rtc;
  }

  Future<void> _connectControlWebSocket(PlatformSession session) async {
    final url = session.websocketUrl;
    final token = session.sessionToken;
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      _log('响应没有 websocket 凭证；跳过控制通道（RTC 仍可观看）');
      return;
    }
    try {
      final channel = IOWebSocketChannel.connect(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
        pingInterval: const Duration(seconds: 20),
      );
      await channel.ready.timeout(const Duration(seconds: 10));
      _ws = channel;
      _wsEvents = channel.stream.listen(
        _onControlEvent,
        onError: (Object error) => _log('控制 WS 错误：$error'),
        onDone: () => _log('控制 WS 已关闭'),
      );
      _sendControlCommand('session.initialize', {
        'protocol_version': '1.0',
        'connection_id': 'app_${DateTime.now().millisecondsSinceEpoch}',
      });
      _log('控制 WS 已连接');
    } catch (error) {
      _log('控制 WS 连接失败（RTC 仍可观看）：$error');
    }
  }

  void _onControlEvent(dynamic raw) {
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is! Map<String, dynamic>) return;
      final type = (decoded['type'] ?? '').toString();
      final data = decoded['data'];
      final text = data is Map ? data['text'] ?? data['message'] ?? '' : '';
      _log('WS $type${text.toString().isEmpty ? '' : '：$text'}');
      if (type == 'session.ended') {
        _log('平台会话已结束');
      }
    } catch (_) {
      _log('WS ${raw.toString().substring(0, raw.toString().length.clamp(0, 160))}');
    }
  }

  void _sendControlCommand(String type, Map<String, dynamic> data) {
    final session = _session;
    final ws = _ws;
    if (session == null || ws == null) return;
    ws.sink.add(jsonEncode({
      'type': type,
      'event_id': 'evt_${DateTime.now().microsecondsSinceEpoch}',
      'session_id': session.id,
      'data': data,
    }));
  }

  Future<void> _joinRtc(RtcCredentials rtc) async {
    if (rtc.provider != 'agora') {
      _log('本示例只实现 Agora；当前 provider=${rtc.provider}');
      if (mounted) setState(() => _status = '不支持的 RTC provider: ${rtc.provider}');
      return;
    }

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _log('麦克风权限被拒绝，将以静音方式加入');
    }

    final engine = createAgoraRtcEngine();
    _engine = engine;
    await engine.initialize(RtcEngineContext(appId: rtc.appId));
    engine.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        _connection = connection;
        _log('已加入 RTC 频道 ${connection.channelId}，uid=${connection.localUid}，${elapsed}ms');
        if (mounted) setState(() => _status = '已加入频道，等待主播音视频…');
      },
      onUserJoined: (connection, remoteUid, elapsed) {
        _log('远端用户加入 uid=$remoteUid，${elapsed}ms');
        if (mounted) {
          setState(() {
            _remoteUid = remoteUid;
            _joined = true;
            _status = '对话中';
          });
        }
      },
      onUserOffline: (connection, remoteUid, reason) {
        _log('远端用户离开 uid=$remoteUid（$reason）');
        if (mounted) {
          setState(() {
            if (_remoteUid == remoteUid) _remoteUid = null;
            _joined = false;
          });
        }
      },
      onLeaveChannel: (connection, stats) {
        _log('已离开频道');
        if (mounted) setState(() => _joined = false);
      },
      onError: (err, msg) {
        _log('RTC 错误 $err：$msg');
      },
    ));

    await engine.enableAudio();
    await engine.enableVideo();
    await engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);

    final uid = int.tryParse(rtc.userId) ?? 0;
    await engine.joinChannel(
      token: rtc.token,
      channelId: rtc.channelId,
      uid: uid,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        publishMicrophoneTrack: true,
        publishCameraTrack: false,
        autoSubscribeAudio: true,
        autoSubscribeVideo: true,
      ),
    );
    _log('joinChannel 已调用（uid=$uid）');
    if (mounted) setState(() => _status = '正在加入频道…');
  }

  Future<void> _toggleMute() async {
    final engine = _engine;
    if (engine == null) return;
    final next = !_muted;
    await engine.muteLocalAudioStream(next);
    if (mounted) setState(() => _muted = next);
    _log(next ? '已静音麦克风' : '已恢复麦克风');
  }

  Future<void> _end() async {
    if (_ending) return;
    setState(() => _ending = true);
    _sendControlCommand('session.end', const {});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _wsEvents?.cancel();
    await _ws?.sink.close();
    _ws = null;
    if (_engine != null) {
      await _engine!.leaveChannel();
      await _engine!.release();
      _engine = null;
    }
    final api = widget.api;
    final sessionId = _sessionId;
    if (api != null && sessionId != null) {
      try {
        await api.endSession(sessionId);
        _log('平台会话 $sessionId 已结束');
      } catch (error) {
        _log('结束平台会话失败：$error');
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _log(String message) {
    final line = '${DateTime.now().toIso8601String().substring(11, 19)} $message';
    if (!mounted) return;
    setState(() {
      _logs.add(line);
      if (_logs.length > 300) _logs.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.animateTo(
          _logScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    if (_fullscreen) {
      SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _wsEvents?.cancel();
    _ws?.sink.close();
    _engine?.leaveChannel();
    _engine?.release();
    _logScroll.dispose();
    super.dispose();
  }

  /// Switches between the normal conversation layout and an immersive
  /// portrait full-screen player, matching the web demo's 9:16 stage.
  Future<void> _setFullscreen(bool fullscreen) async {
    if (_fullscreen == fullscreen) return;
    if (fullscreen) {
      // Portrait fullscreen, like the web demo: do not rotate the device.
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(const []);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (mounted) setState(() => _fullscreen = fullscreen);
  }

  Widget _videoView() {
    if (_remoteUid == null || _engine == null) {
      return Center(
        child: Text(
          widget.rtcOnly == null ? '等待主播准备并加入频道…' : '等待远端视频…',
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }
    return AgoraVideoView(
      controller: VideoViewController.remote(
        rtcEngine: _engine!,
        canvas: VideoCanvas(uid: _remoteUid),
        connection: _connection ?? RtcConnection(),
        useAndroidSurfaceView: true,
      ),
    );
  }

  Widget _fullscreenToggle() {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: IconButton(
        key: const ValueKey('fullscreen-toggle'),
        tooltip: _fullscreen ? '退出全屏' : '全屏',
        color: Colors.white,
        icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
        onPressed: () => _setFullscreen(!_fullscreen),
      ),
    );
  }

  Widget _videoStage({required bool fullscreen}) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _videoView(),
          Positioned(
            top: fullscreen ? 12 : 8,
            right: fullscreen ? 12 : 8,
            child: SafeArea(bottom: false, left: false, child: _fullscreenToggle()),
          ),
        ],
      ),
    );
  }

  Widget _buildFullscreen() {
    // Keep the same 9:16 portrait stage as the web integration demo; on tall
    // screens the black background letterboxes the video instead of stretching
    // or rotating it.
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: 9 / 16,
              child: _videoView(),
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: SafeArea(bottom: false, left: false, child: _fullscreenToggle()),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _fullscreen) _setFullscreen(false);
      },
      child: _fullscreen ? _buildFullscreen() : _buildNormal(theme),
    );
  }

  Widget _buildNormal(ThemeData theme) {
    return Scaffold(
      appBar: AppBar(title: const Text('DHLive 数字人会话')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Icon(
                  _joined ? Icons.videocam : Icons.hourglass_top,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(_status)),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: _videoStage(fullscreen: false),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _engine == null ? null : _toggleMute,
                    icon: Icon(_muted ? Icons.mic_off : Icons.mic),
                    label: Text(_muted ? '取消静音' : '静音'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _ending ? null : _end,
                    icon: const Icon(Icons.call_end),
                    label: const Text('结束会话'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: ListView.builder(
                controller: _logScroll,
                itemCount: _logs.length,
                itemBuilder: (context, index) => Text(
                  _logs[index],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
