# Troubleshooting

| Symptom | Check |
| --- | --- |
| Helper starts with an empty log | Reapprove Bluetooth permission after rebuilding |
| Channel 1 refuses to open, despite the Mac showing Connected | With the phone disconnected and no helper running, disconnect and reconnect only the MiniToo in macOS Bluetooth settings to clear a stale Mac-side session |
| Another client owns the channel | Close the Divoom phone app and disconnect the phone; stop an old helper with `./core/dv stop` |
| Commands are sent but the screen does not change | Confirm RFCOMM channel 1 in `/tmp/divoom-send.log`; channel 10 only echoes |
| A saved character face no longer switches | Select its custom face again in the Divoom phone app, then close the app and retry |
| Studio reports a transfer timeout | Check power and range; try `LIVE_STUDIO_SIZE=128` and restart Studio |
| Phone page is offline | Studio must be on and the relay account must have access under your Firebase rules |
| Character changes are blocked | Turn Studio off or let Pomodoro finish |

Run `./minitoo status` first. Studio logs are in `~/.clauddy/live-studio.log`.
Logs can contain private device traffic or message details. Do not commit them.

Power-cycle the device with its physical power button if it remains unresponsive.
