# Changelog

## 0.2.1 - 2026-10-12

- Fix: "Nothing is named parent.gf_frame" errors on node creation. The Group's knobs are now
  added before the internal nodes whose expressions reference them.
- Tests: the fake nuke module now reports unresolved `parent.` expressions.

## 0.2.0 - 2026-10-12

- `installers/`: one-click install of the current build (runs tests with Nuke's Python first,
  clean copy, build stamp, managed init.py block), dev mode, uninstall, terminal smoke test.
- Build info: Nuke prints which build loaded; GenFill > Developer > Build Info.
- GenFill > Developer > Reload GenFill: pick up a new build without restarting Nuke.
- GenFill > Developer > Run Smoke Test: builds a test setup, generates offline, renders and
  writes `test_output/report.json` plus images and a panel screenshot.
- `engine.generate(..., blocking=True)` for tests and terminal mode.

## 0.1.0 - 2026-10-12

First version.

- GenerativeFill node (Group of native nodes; renders without the plugin).
- Photoshop-style panel: contextual prompt bar, Generate, variation thumbnails, ‹ › navigation.
- Empty prompt removes the selected content (Stability Erase).
- Backends: Stability AI (inpaint/erase), OpenAI GPT Image, Offline Preview.
- Colour-managed 8-bit SDR round trip; only pixels inside the selection are replaced.
- Context crop matched to the model's aspect ratio.
- Variation history stored on the node; results cached next to the script.
- API keys from environment variables or ~/.nuke/genfill/config.json (never in scripts).
