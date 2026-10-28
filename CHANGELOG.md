# Changelog

## 1.0.1+2 (v0.1.1) — 2026-10-28

### Fixed

- Keep `rtc` credentials and the control-WebSocket `session_token` from the
  create-session response (201). Polling `GET /v1/realtime/sessions/{id}` only
  returns a public status view without those fields, so joining could fail with
  an empty RTC provider / missing WebSocket.
- Documented the public-view behavior in `README.md` and `docs/integration.md`.

## 1.0.0+1 (v0.1.0) — 2026-10-28

### Added

- Flutter Android integration sample: demo mode (app creates the session) and
  production mode (RTC credentials from a customer backend), Agora video,
  mic publish/mute, control-WebSocket event log and hangup.
