# Changelog

## 1.0.2+3 (v0.1.2) — 2026-10-28

### Added

- Fullscreen toggle on the video stage: immersive landscape playback with a
  second tap or the Android back button to return to the conversation layout.
- Remember the demo tenant API key and host id in the app's private
  preferences, so they no longer need to be retyped for every test.

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
