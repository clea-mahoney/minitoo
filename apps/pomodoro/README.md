# Pomodoro

Run a focus timer on the MiniToo, with optional Apple Music during work blocks.
Turn Live Studio off before starting. Character status updates pause while the
timer owns the screen and resume when it ends.

## Start a session

From the project root:

```bash
./minitoo studio off
./minitoo pomodoro 25 5 1 --no-music
```

The numbers mean work minutes, break minutes, and cycles. This example runs
25 minutes of work followed by a 5-minute break. Every cycle includes its break,
including the final cycle. With no numbers, the defaults are `25 5 4`, or two hours.

Keep the launching terminal or chat open. In a terminal, press Ctrl-C to stop
early. To return to your installed character afterward:

```bash
./minitoo face chilling
```

The device's physical return button also exits the countdown view.

## Add music

Install the audio routing tool:

```bash
brew install switchaudio-osx
```

Pair the MiniToo as a Bluetooth speaker in macOS. Open Music, choose a playlist,
and play it once so there is a track to resume. Then omit `--no-music`:

```bash
./minitoo pomodoro 25 5 1
```

Music plays through the MiniToo during work and pauses during breaks. At the
end or on cancellation, Music pauses and the previous Mac audio output returns.
The timer does not choose tracks or change the device's volume. If the audio
routing tool or MiniToo speaker is unavailable, it continues without music.

## Try a short test

```bash
./minitoo pomodoro --test-seconds 20 --no-music
./minitoo pomodoro --test-seconds 20
```

Each command runs one 20-second block. The second also checks music routing.
The display stops about three seconds before the block ends to avoid the
MiniToo's loud built-in alarm. There is no replacement end sound.

The same quiet ending applies to work and break blocks. Advanced settings:
`POMODORO_ALARM_LEAD` sets the stop margin (default 3 seconds), and
`POMODORO_RESEND_INTERVAL` sets the countdown refresh interval (default 2 seconds).

See [release verification](../../docs/verification.md) for the checks performed.
