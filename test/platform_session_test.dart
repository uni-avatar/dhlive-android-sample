import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:dhlive_android_sample/dhlive_api.dart';

http.Response jsonResponse(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  test('waitUntilReady keeps rtc/websocket from the create response', () async {
    var getCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        return jsonResponse({
          'id': 'ses_01TEST',
          'status': 'preparing',
          'rtc': {
            'provider': 'agora',
            'app_id': 'app_1',
            'channel_id': 'ch_1',
            'user_id': '42',
            'token': 'rtc_token',
          },
          'websocket': {
            'url': 'wss://example.test/v1/realtime/connect?session_id=ses_01TEST',
            'session_token': 'st_1',
          },
        }, 201);
      }
      getCalls++;
      // Public polling view: credentials are stripped by the platform.
      return jsonResponse({'id': 'ses_01TEST', 'status': 'ready'}, 200);
    });

    final api = DhliveApi(
      baseUrl: 'https://example.test',
      apiKey: 'dh_live_test',
      client: client,
    );
    final created = await api.createSession(hostId: 'dh_01TEST');
    expect(created.rtc.token, 'rtc_token');

    final ready = await api.waitUntilReady(
      created,
      timeout: const Duration(seconds: 2),
    );
    expect(getCalls, 1);
    expect(ready.status, 'ready');
    expect(ready.rtc.provider, 'agora');
    expect(ready.rtc.token, 'rtc_token');
    expect(ready.sessionToken, 'st_1');
    expect(ready.websocketUrl, contains('ses_01TEST'));
  });
}
