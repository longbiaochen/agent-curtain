# AgentCurtain v1.1.0

This release adds a one-screen remote mode for multi-display Macs.

## What changed

- Disconnects all external displays while the curtain is drawn, leaving the built-in display as the active desktop.
- Restores surviving windows to their original display and frame when the curtain opens.
- Identifies displays by UUID when macOS assigns a different runtime Display ID.
- Restores display topology, brightness, and window frames after an unexpected app exit.
- Uses the macOS display SPI first and BetterDisplay Pro only as a fallback.

## Requirements

- Apple Silicon
- macOS 26 or newer
- BetterDisplay with `betterdisplaycli`; the Pro license is optional when the system display SPI is available

The display connection API is private and may change in a future macOS release. Run the hardware acceptance checks again after a system upgrade.

See the [README](../README.md) for installation and the [implementation record](PLAN-display-disconnect-backend.md) for verified behavior and remaining physical-device checks.
