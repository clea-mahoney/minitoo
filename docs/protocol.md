# Bluetooth implementation

The MiniToo command connection uses Bluetooth Classic RFCOMM channel 1. One
client owns that channel at a time. The Swift helper keeps it open and accepts
commands through a local FIFO. macOS requires the signed app bundle built by
`core/build.sh` and Bluetooth permission for that app.

Character faces use three preloaded custom slots. Their account-specific ClockIds
come from the Divoom account during installation. Switching selects a saved ID.
It does not upload the GIF again.

Live Studio uses the separate `0x8b` animation transport. `core/media.py` renders
RGB frames, compresses them with a 128 KiB Zstandard window, and constructs the
payload. The helper sends an announcement, waits for the device's data request,
sends 256-byte chunks, and waits for a fresh final ACK. The default layout is
160x128; 128x128 is available for compatibility testing.

The new sender was implemented from
[Alvin's protocol notes](https://github.com/alvinunreal/divoom-minitoo-osx/blob/main/PROTOCOL.md).
His documented media examples use square images. Full-width media must be
verified against the receiving firmware.

The whole Studio session owns the shared device lock. Exiting selects the
previous face without re-uploading it. The sender does not disconnect Bluetooth
audio or call the device's baseband disconnect function.

An ACK confirms that the device accepted the transfer. It does not prove that
pixels rendered correctly. Saved-face selection has no equivalent application
ACK, so it needs a visual check too.
