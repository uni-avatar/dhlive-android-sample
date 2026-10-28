import 'dart:convert';

import 'package:flutter/material.dart';

import 'dhlive_api.dart';
import 'session_page.dart';

void main() {
  runApp(const DhliveSampleApp());
}

class DhliveSampleApp extends StatelessWidget {
  const DhliveSampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DHLive Android Sample',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// Collects the platform endpoint, API key and host id, then opens a session.
///
/// Demo mode only: a production app must not ship a tenant API key. See
/// README.md for the recommended backend-owned architecture.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _baseUrl = TextEditingController(text: 'https://dvideo.store');
  final _apiKey = TextEditingController();
  final _hostId = TextEditingController();
  final _userId = TextEditingController(text: 'android_sample_user');
  final _rtcJson = TextEditingController();
  bool _obscureKey = true;

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _hostId.dispose();
    _userId.dispose();
    _rtcJson.dispose();
    super.dispose();
  }

  void _openDemoSession() {
    final baseUrl = _baseUrl.text.trim();
    final apiKey = _apiKey.text.trim();
    final hostId = _hostId.text.trim();
    if (baseUrl.isEmpty || apiKey.isEmpty || hostId.isEmpty) {
      _snack('请填写平台地址、API Key 和主播 ID');
      return;
    }
    final api = DhliveApi(baseUrl: baseUrl, apiKey: apiKey);
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (_) => SessionPage(
            api: api,
            hostId: hostId,
            userId: _userId.text.trim(),
          ),
        ))
        .whenComplete(api.close);
  }

  void _openRtcOnly() {
    final raw = _rtcJson.text.trim();
    if (raw.isEmpty) {
      _snack('请粘贴后端下发的 rtc JSON');
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('rtc JSON 必须是对象');
      final rtc = RtcCredentials.fromJson(decoded.cast<String, dynamic>());
      if (rtc.appId.isEmpty || rtc.channelId.isEmpty || rtc.token.isEmpty) {
        throw const FormatException('缺少 app_id / channel_id / token');
      }
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SessionPage(rtcOnly: rtc),
      ));
    } catch (error) {
      _snack('RTC JSON 解析失败：$error');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DHLive · Android Flutter 集成示例')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Demo 模式', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'App 直接创建平台会话并持有控制 WS，仅用于本地联调；生产环境请把 API Key 与控制 WS 放在后端，App 只拿 rtc。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _baseUrl,
                    decoration: const InputDecoration(
                      labelText: '平台地址',
                      hintText: 'https://dvideo.store',
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _apiKey,
                    obscureText: _obscureKey,
                    decoration: InputDecoration(
                      labelText: '租户 API Key',
                      hintText: 'dh_live_...',
                      suffixIcon: IconButton(
                        icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscureKey = !_obscureKey),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _hostId,
                    decoration: const InputDecoration(
                      labelText: '主播 ID',
                      hintText: 'dh_01...',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _userId,
                    decoration: const InputDecoration(
                      labelText: '业务用户 ID（可选）',
                      hintText: 'u_123',
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _openDemoSession,
                      icon: const Icon(Icons.play_circle),
                      label: const Text('创建会话并加入'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('生产模式：只接 RTC', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '把后端 /api/session 返回的 rtc 对象原样粘贴到下面，App 只加入 Agora 频道并发布麦克风。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _rtcJson,
                    minLines: 4,
                    maxLines: 8,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: 'rtc JSON',
                      hintText: '{"provider":"agora","app_id":"...","channel_id":"...","user_id":"...","token":"..."}',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _openRtcOnly,
                      icon: const Icon(Icons.videocam),
                      label: const Text('用 RTC 凭证加入'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
