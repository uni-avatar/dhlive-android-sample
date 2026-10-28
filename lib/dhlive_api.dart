import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Raised when the platform answers with a non-2xx response or an unexpected
/// payload. The message is safe to show to the operator.
class DhliveApiException implements Exception {
  DhliveApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

/// RTC credentials handed to the app by the platform session response.
class RtcCredentials {
  RtcCredentials({
    required this.provider,
    required this.appId,
    required this.channelId,
    required this.userId,
    required this.token,
  });

  factory RtcCredentials.fromJson(Map<String, dynamic> json) {
    String text(String key) => (json[key] ?? '').toString();
    return RtcCredentials(
      provider: text('provider'),
      appId: text('app_id'),
      channelId: text('channel_id'),
      userId: text('user_id'),
      token: text('token'),
    );
  }

  final String provider;
  final String appId;
  final String channelId;
  final String userId;
  final String token;
}

/// Platform session created through `POST /v1/hosts/{host_id}/sessions`.
class PlatformSession {
  PlatformSession({
    required this.id,
    required this.status,
    required this.rtc,
    this.websocketUrl,
    this.sessionToken,
  });

  factory PlatformSession.fromJson(Map<String, dynamic> json) {
    final websocket = json['websocket'];
    return PlatformSession(
      id: (json['id'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      rtc: RtcCredentials.fromJson(
        (json['rtc'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      websocketUrl: websocket is Map ? (websocket['url'] ?? '').toString() : null,
      sessionToken:
          websocket is Map ? (websocket['session_token'] ?? '').toString() : null,
    );
  }

  final String id;
  final String status;
  final RtcCredentials rtc;

  /// Only present for backend-control sessions. Production apps must keep this
  /// on their backend; the demo screen keeps it in memory for convenience.
  final String? websocketUrl;
  final String? sessionToken;

  bool get isReady => status == 'ready' || status == 'active';
  bool get isTerminal => status == 'ended' || status == 'failed';

  /// The polled status comes from `GET /v1/realtime/sessions/{id}`, which is a
  /// public view **without** RTC credentials or the control WebSocket. Keep
  /// those from the create response.
  PlatformSession withCredentialsFrom(PlatformSession source) => PlatformSession(
        id: id,
        status: status,
        rtc: source.rtc,
        websocketUrl: source.websocketUrl,
        sessionToken: source.sessionToken,
      );
}

/// Thin REST client for the public Digital Human API.
class DhliveApi {
  DhliveApi({required String baseUrl, required this.apiKey, http.Client? client})
      : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _client = client ?? http.Client();

  /// Platform origin, for example `https://dvideo.store`.
  final String baseUrl;

  /// Tenant API key. It must stay on the backend in production; this sample
  /// only uses it locally to demonstrate the flow end to end.
  final String apiKey;

  final http.Client _client;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  Future<PlatformSession> createSession({
    required String hostId,
    String? userId,
    String? timezone,
  }) async {
    final context = <String, dynamic>{};
    if (userId != null && userId.isNotEmpty) context['user_id'] = userId;
    if (timezone != null && timezone.isNotEmpty) context['timezone'] = timezone;

    final response = await _client.post(
      Uri.parse('$baseUrl/v1/hosts/${Uri.encodeComponent(hostId)}/sessions'),
      headers: _headers,
      // The demo app keeps the control WebSocket itself, so it asks for the
      // backend-control response shape. A production backend uses the same
      // endpoint and keeps this WebSocket on the server.
      body: jsonEncode({
        'control_mode': 'backend',
        if (context.isNotEmpty) 'client_context': context,
      }),
    );
    return PlatformSession.fromJson(_decode(response));
  }

  /// Returns the public session view: status and metadata only. `rtc` and
  /// `websocket` are stripped by the platform, so never join RTC from it.
  Future<PlatformSession> getSession(String sessionId) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/v1/realtime/sessions/${Uri.encodeComponent(sessionId)}'),
      headers: _headers,
    );
    return PlatformSession.fromJson(_decode(response));
  }

  /// Polls the session until it is `ready`, then returns it with the RTC and
  /// control-WebSocket credentials captured from the create response.
  Future<PlatformSession> waitUntilReady(
    PlatformSession created, {
    Duration timeout = const Duration(minutes: 2),
    void Function(PlatformSession session)? onPoll,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var delay = const Duration(milliseconds: 500);
    while (DateTime.now().isBefore(deadline)) {
      final session = await getSession(created.id);
      onPoll?.call(session);
      if (session.isReady) return session.withCredentialsFrom(created);
      if (session.isTerminal) {
        throw DhliveApiException(409, '会话进入 ${session.status}，请重新创建');
      }
      await Future<void>.delayed(delay);
      if (delay.inSeconds < 3) {
        delay = Duration(milliseconds: delay.inMilliseconds + 500);
      }
    }
    throw DhliveApiException(408, '等待会话 ready 超时，请确认主播已启动且引擎空闲');
  }

  Future<void> endSession(String sessionId) async {
    final response = await _client
        .delete(
          Uri.parse('$baseUrl/v1/realtime/sessions/${Uri.encodeComponent(sessionId)}'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw DhliveApiException(response.statusCode, _errorMessage(response));
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    final body = response.body.isEmpty ? '{}' : response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DhliveApiException(response.statusCode, _errorMessage(response));
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw DhliveApiException(response.statusCode, '平台返回了非预期的响应');
    }
    return decoded;
  }

  String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] is Map) {
        final message = (decoded['error'] as Map)['message'];
        if (message != null && message.toString().isNotEmpty) {
          return message.toString();
        }
      }
    } catch (_) {
      // Fall through to the generic message below.
    }
    return 'HTTP ${response.statusCode}';
  }

  void close() => _client.close();
}
