# Workspace notes

## Background-only development

The user is often at work while development runs and does not want game windows
popping into the foreground.

- Do not launch the graphical Godot client, capture the desktop, or record video
  unless the user explicitly asks to see the game.
- Use Godot `--headless` for script parsing and startup checks.
- Verify server logic with `npm test` and the WebSocket smoke test.
- Verify extracted assets with offscreen scripts (for example Python/PIL contact
  sheets) and inspect saved images directly.
- Start servers only for a test run and stop them when the run finishes.
- Never leave a Godot window running in the background by accident.
