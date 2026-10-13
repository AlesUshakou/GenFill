# Changelog

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
