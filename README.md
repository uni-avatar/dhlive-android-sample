# DHLive Android Flutter 集成示例

用 Flutter 在 Android 上接入 **DHLive 数字人平台** 的最小可运行示例：创建平台会话 → 等待主播准备 → 用 Agora RTC 播放数字人音视频并发布用户麦克风 → 通过控制 WebSocket 观察会话事件 → 挂断结束会话。

> 这是**示例代码**，演示平台 API 的完整链路，不追求产品级 UI。生产接入请按「[生产模式](#生产模式推荐后端持有-api-key)」把 API Key 和控制 WebSocket 放到你的后端。

## 功能

- Demo 模式：App 输入平台地址、租户 API Key、主播 ID，直接创建平台会话。
- 生产模式：粘贴后端下发的 `rtc` JSON，只加入 Agora 频道（App 不需要 API Key）。
- Agora 视频渲染（`AgoraVideoView`）、远端用户上下线、麦克风静音/恢复。
- 控制 WebSocket：`session.initialize`、`session.end`、`asr_*` / `llm_*` 等事件落到日志面板。
- 会话状态轮询（`preparing` → `ready`）、超时与错误提示、结束会话时 `DELETE /v1/realtime/sessions/{id}`。

## 架构与安全

平台推荐架构是 **后端创建会话并持有控制 WebSocket，App 只拿 RTC 凭证**：

```
App ──POST /api/session──▶ 你的后端 ──POST /v1/hosts/{id}/sessions──▶ DHLive 平台
                                     └── 控制 WebSocket（session.initialize / 事件）
App ◀── rtc {app_id, channel_id, user_id, token} ── 你的后端
App ──Agora SDK joinChannel（发布麦克风、订阅音视频）──▶ 引擎
```

本示例的 **Demo 模式** 为了单机可跑，把「创建会话 + 控制 WebSocket」也放进了 App，因此需要填租户 API Key。**不要把 API Key 写进正式 App**：它是最长期凭据，泄露后可创建/消耗你的会话。生产请只实现首页下方的「只接 RTC」模式，API Key 与控制 WS 留在后端。

## 环境要求

| 项 | 要求 |
| --- | --- |
| Flutter | 3.24+（本仓库用 3.47 验证） |
| Android | minSdk 23+，真机（需要麦克风） |
| 平台侧 | 租户 API Key、已启动的主播 `host_id`、平台分配给该租户的空闲引擎 |
| RTC | 平台当前 provider 需为 `agora`（示例只实现 Agora；TRTC/native 需换对应 SDK） |

## 快速开始

```bash
git clone https://github.com/uni-avatar/dhlive-android-sample.git
cd dhlive-android-sample
flutter pub get
flutter run -d <your-android-device>
```

运行后：

1. 「平台地址」默认 `https://dvideo.store`（可改成你的部署入口）。
2. 填租户 **API Key**（`dh_live_...`）和 **主播 ID**（`dh_01...`）。
3. 确认该主播已 `start`（控制台里为 `ready`），且所属租户有空闲引擎。
4. 点「创建会话并加入」，等待状态从 `preparing` 变成 `ready` 并加入频道。
5. 看到数字人画面后对着手机说话；日志面板会显示 `asr_final` / `llm_done` 等事件。
6. 点「结束会话」释放引擎。

首次准备通常几秒到 1 分钟（取决于主播形象/引擎预热）。

## 生产模式（推荐：后端持有 API Key）

1. 你的后端实现 3 个接口（见平台 `/docs` 第 6 节）：

```http
POST /api/session                     → {"session_id": "...", "rtc": {...}}
POST /api/session/{id}/heartbeat      → 204
POST /api/session/{id}/hangup         → 204
```

2. 后端用租户 API Key 调平台 `POST /v1/hosts/{host_id}/sessions`，持有返回的 `websocket`，只把 `rtc` 下发给 App。
3. App 把 `rtc` JSON 粘贴进首页「生产模式」输入框，或由你的代码直接构造 `RtcCredentials` 传给 `SessionPage(rtcOnly: ...)`。
4. 挂断/心跳超时后，后端调用 `DELETE /v1/realtime/sessions/{session_id}`。

## 代码结构

| 文件 | 说明 |
| --- | --- |
| `lib/main.dart` | 配置页：平台地址、API Key、主播 ID、RTC JSON 粘贴入口 |
| `lib/dhlive_api.dart` | 平台 REST 客户端：创建会话、轮询 ready、查询、结束会话；`RtcCredentials` / `PlatformSession` 模型 |
| `lib/session_page.dart` | 会话页：控制 WebSocket、Agora 初始化/入会、视频渲染、静音、挂断 |
| `docs/integration.md` | 更详细的接口、时序、错误与安全说明 |

## 常见问题

| 现象 | 排查 |
| --- | --- |
| `401` / `403` | API Key 是否租户 Key、是否复制完整；控制台 → API Key 页面确认启用 |
| `409 No free engine is available` | 租户没有空闲引擎：管理员在「引擎管理」分配引擎，或等占用主播释放 |
| `等待会话 ready 超时` | 主播未 start、引擎正忙、主播形象/音色资源同步失败；查控制台主播状态与平台日志 |
| 有画面没声音 / 没画面 | 确认 `rtc.provider=agora`、token 未过期、入会后 `onUserJoined` 是否触发；真机需要麦克风权限 |
| `加入频道失败` | token 过期或使用错误 uid；后端调 `/v1/realtime/sessions/{id}/reconnect` 换新凭证 |
| 本地 HTTP 调试被拦 | Android 9+ 默认禁止明文 HTTP；用 HTTPS 入口，或临时在 `AndroidManifest.xml` 的 `<application>` 上加 `android:usesCleartextTraffic="true"`（不要带进生产） |
| 会话创建成功、状态到 ready，但 `rtc.provider` 为空 / 没有 websocket | `GET /v1/realtime/sessions/{id}` 只返回公开视图，**不含 `rtc` 和 `websocket`**；RTC/控制 WS 凭证只出现在 `POST /v1/hosts/{id}/sessions` 的创建响应里。示例已按此修复（v0.1.1）：轮询只看 `status`，凭证从创建响应保留 |

## 相关文档

- 平台接入文档：<https://dvideo.store/docs>（`/docs/raw.md` 可直接拉 Markdown）
- 浏览器/后端完整 API 设计：DHLive 平台文档第 3–7 节
- 平台演示页：<https://dvideo.store/integration-demo>
- 控制台：<https://dvideo.store/console/login>

## License

MIT，见 [LICENSE](LICENSE)。
