# Release verification

Checks below cover the clean source and the tested MiniToo on firmware 2.4.0.
Personal device settings, cloud credentials and message history stay outside
the repository.

| Check | Result |
| --- | --- |
| Automated tests | 34 passed |
| Media format | RGB round trip, frame limit, chunk ordering and compression window checked |
| Delivery reporting | Fresh ACK required; missing ACK and failed writes produce errors |
| Studio behavior | Updates queue correctly; failures do not retry endlessly |
| Session cleanup | Real Studio start/send/stop cycle passed; device lock released and previous hook pause restored |
| Pomodoro | 20-second device countdown visually confirmed and finished without an alarm. Music reported playing through the MiniToo after connection, then paused and restored Mac speakers. Cancellation released the device lock and resumed hooks. Automated checks cover two complete work/break cycles, final break, music ordering and termination |
| Source checks | Shell and JavaScript syntax passed; Swift helper type-check passed |
| Privacy | Known personal configuration values and excluded historical names absent; no Git history or message logs included |
| Device display | 160x128 text transferred in 0.912 seconds and was visually confirmed. A text-and-emoji message was acknowledged in 0.943 seconds |
| Codex adapter | Real working/waiting/finished adapter sequence passed. Codex loaded all five hooks without errors; they are trusted on the test Mac. Automatic working-state updates were observed during real tool calls |
| Remote cloud | Existing hosted page connected through its Firebase project; live heartbeat and media acknowledgement verified. New-project password rules remain examples, not deployed |

## Run the tests

After installing Python dependencies:

```bash
.venv/bin/python -m unittest discover -s tests -v
```

## Final device check

With the MiniToo powered on nearby and the phone app disconnected:

1. Run `./minitoo face chilling` and confirm the saved character appears.
2. Run `./minitoo studio on`, then open `http://127.0.0.1:8765`.
3. Send a short message with text and emoji. Check legibility and the transfer result.
4. Run `./minitoo studio off`. Confirm the previous character returns without
   re-uploading its GIFs.
5. Switch to `working` and `alerting` to check that those saved faces are intact.

Test the default 160x128 layout first. If it fails, try `LIVE_STUDIO_SIZE=128`
and restart Studio. The 160x128 layout has been verified on the tested MiniToo with firmware 2.4.0.

## Pomodoro device check

Tested on 2026-11-02 with firmware 2.4.0:

1. Turn Studio off with `./minitoo studio off`.
2. Run `./minitoo pomodoro --test-seconds 20 --no-music`. Confirm the countdown
   appears and finishes quietly. This was visually confirmed by the device owner.
3. With a Music playlist queued and the speaker paired, repeat without
   `--no-music`. Music's reported player state was `playing` while macOS output
   was the MiniToo. On completion it was `paused`, with Mac speakers restored.
4. Stop a running test with Ctrl-C. The live cancellation check used SIGTERM;
   it released the device lock and resumed status hooks. The script handles
   Ctrl-C through the same cleanup function.
5. Run `./minitoo face chilling` to return to the saved character.

Device runs used short blocks. Full work/break sequencing was checked with
simulated device and Music commands, including the final break. No full-length
25-minute session was required for these checks.
