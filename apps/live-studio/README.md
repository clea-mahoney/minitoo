# Live Studio

Send colored text and emoji to the MiniToo from a browser.

```bash
./minitoo studio on
```

Open `http://127.0.0.1:8765` on the Mac. Typing sends updates after a short pause.
The same colors used by the phone controller are available: Mint Mist
(`#E2F6EF`), Seafoam (`#3CC9A4`) and Apricot (`#F7B8A0`). Changing the selected
color affects newly typed characters. Sender names are kept in the private
message log and never drawn on the device.

```bash
./minitoo studio status
./minitoo studio off
```

Studio keeps one Bluetooth connection open, streams the rendered image, and
waits for the device's transfer ACK. It does not borrow or overwrite a character
slot. Turning it off selects the previous face and restores the previous hook
pause. It can stay running after the launching terminal closes.

Use [remote setup](../../docs/remote-studio.md) for the verified Netlify-hosted
frontend and Firebase relay flow. The local URL is available only on the Mac.
A fresh deployment of the packaged password-login page is not yet verified
end to end.

`./minitoo studio back` and `forward` replay locally recorded remote messages.
Messages live under `~/.clauddy/live-studio/`, outside this repository. Remote
messages are also recorded in your own Firebase database.

The default media layout is 160x128. Set `LIVE_STUDIO_SIZE=128` in `personal.env`
to test the community-tested square format if your firmware rejects full-width
media. A transfer ACK still needs a visual check on the physical display.
