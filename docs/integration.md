# 集成说明（Android / Flutter）

本文补充 README 的接口细节，便于把示例代码移到你的 App 或后端。

## 1. 前置条件

1. 平台侧存在一个可用主播：控制台「主播管理」中 `start` 后为 `ready`。
2. 租户有可用引擎：管理员在「引擎管理」把某个 worker 分配给该租户；主播 start 时自动绑定。
3. 拿到租户 API Key（`dh_live_...`）。**只放在后端**。
4. 平台 `GET /v1/runtime` 返回的 `rtc_provider` 为 `agora`（示例实现 Agora，TRTC/native 需替换 RTC 层）。

## 2. 时序

```
App/后端                         DHLive 平台                     engine
  │ POST /v1/hosts/{id}/sessions   │                              │
  │──────────────────────────────▶│ 创建会话，分配引擎            │
  │◀── session(id, status=preparing, rtc, websocket) ─────────────│
  │ GET /v1/realtime/sessions/{id} │                              │
  │──────────────────────────────▶│ preparing → ready            │
  │◀── status=ready ──────────────│                              │
  │ WS connect(websocket.url,     │                              │
  │   Authorization: session_token)│                             │
  │── session.initialize ────────▶│                              │
  │                               │── 驱动引擎 ────────────────▶│
  │ Agora joinChannel(rtc) ─────────────────────────────────────▶│ 发布音视频
  │◀──────────────────── 数字人音视频/用户麦克风 ────────────────│
  │◀── asr_partial/asr_final/llm_delta/llm_done/session.* ───────│
  │ DELETE /v1/realtime/sessions/{id}                             │
  │──────────────────────────────▶│ 结束会话，释放引擎            │
```

`preparing` 阶段主要在做主播形象/音色资源同步和引擎预热，通常几秒到 1 分钟；轮询间隔建议 0.5–3 秒，总超时 2 分钟。

## 3. REST 接口

### 创建会话

```http
POST {base}/v1/hosts/{host_id}/sessions
Authorization: Bearer dh_live_xxx
Content-Type: application/json

{"control_mode":"backend","client_context":{"user_id":"u_123","timezone":"Asia/Shanghai"}}
```

响应关键字段：

```json
{
  "id": "ses_01...",
  "status": "preparing",
  "rtc": {"provider":"agora","app_id":"...","channel_id":"...","user_id":"...","token":"..."},
  "websocket": {"url":"wss://.../v1/realtime/connect?session_id=ses_01...","session_token":"st_...","token_expires_at":"..."}
}
```

- `control_mode=client` 用于浏览器直连（需要 `client_allow_origin`）；Android App 不要用。
- 支持 `Idempotency-Key` 请求头，重试复用同一个 Key。
- 只把 `rtc` 下发给 App，`websocket` 与 API Key 留在后端。

### 查询 / 结束

```http
GET    {base}/v1/realtime/sessions/{id}   → 公开状态视图（不含 rtc/websocket）
DELETE {base}/v1/realtime/sessions/{id}   → 204，释放引擎
```

> **重要**：`GET` 只返回状态与元数据，平台会把 `rtc` 和 `websocket` 剥离；RTC 凭证与 `session_token` 只存在于创建响应（201）里。App/后端必须保存创建响应的 `rtc`（和 `websocket`），轮询只用 `status` 判断是否 ready。示例 v0.1.1 起按此实现。

### 重连

```http
POST {base}/v1/realtime/sessions/{id}/reconnect
```

返回新的 `websocket` token 与 `rtc`；仅 `preparing|ready|active|reconnecting` 可用。App 先 `leaveChannel` 再用新 `rtc` 加入。

## 4. 控制 WebSocket（后端）

```http
GET {websocket.url}
Authorization: Bearer {websocket.session_token}
```

连接成功后发初始化：

```json
{"type":"session.initialize","event_id":"evt_01...","session_id":"ses_01...","data":{"protocol_version":"1.0","connection_id":"web_xxx"}}
```

后端可发命令：`conversation.text_input`、`avatar.speak`、`conversation.interrupt`、`session.end`；接收事件：`session.ready`、`session.state_changed`、`session.ended`、`asr_partial`、`asr_final`、`llm_delta`、`llm_done`、`command.ack`、`command.error`。

事件可选择性转发给 App（例如字幕）；App 不直接连平台 WS（`client` 模式除外）。

## 5. Agora RTC 参数映射

| 平台字段 | Agora SDK 参数 |
| --- | --- |
| `rtc.app_id` | `RtcEngineContext(appId: ...)` |
| `rtc.channel_id` | `joinChannel(channelId: ...)` |
| `rtc.user_id` | `joinChannel(uid: int.parse(...))` |
| `rtc.token` | `joinChannel(token: ...)` |

示例用 `ClientRoleType.clientRoleBroadcaster` + `publishMicrophoneTrack: true`：数字人在同一频道发布音视频，App 发布麦克风（引擎侧识别用户说话）。如果只需要观看，把 `publishMicrophoneTrack` 设为 `false` 并静音本地采集。

数字人视频用 `AgoraVideoView(controller: VideoViewController.remote(...))` 渲染，等 `onUserJoined` 后设置远端 uid。

## 6. 错误与排查

| HTTP/错误 | 含义 | 处理 |
| --- | --- | --- |
| `401` | API Key 无效/未带 Bearer | 检查 Key |
| `403` | Key 不属于该主播的租户 | 用主播所属租户的 Key |
| `409 No free engine is available` | 租户无空闲引擎 | 管理员分配引擎/等释放 |
| `409 session_not_reconnectable` | 会话已结束 | 重新创建会话 |
| `404` | 主播/会话不存在 | 检查 host_id / session_id |
| `408`（客户端超时） | preparing 超过 2 分钟 | 检查主播状态与引擎资源同步 |

RTC 侧：token 过期（`onError`/`onJoinChannelSuccess` 未回调）→ 后端 `/reconnect`；无远端视频 → 确认 `onUserJoined` 与 `autoSubscribeVideo: true`。

## 7. 安全清单

- [ ] 租户 API Key 只在后端，不写进 APK/前端包。
- [ ] 控制 WebSocket 在后端持有；App 只拿 `rtc`。
- [ ] App 挂断/心跳超时后后端 `DELETE` 平台会话，避免引擎被占。
- [ ] 生产入口使用 HTTPS/WSS；不要开启 `usesCleartextTraffic`。
- [ ] 为每次会话生成业务侧 user_id，方便排查和计费。
