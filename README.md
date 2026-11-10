# MiniToo for macOS

Give a Divoom MiniToo three jobs: show what your AI is doing, run a focus timer,
and receive messages from a browser.

| Character status | Focus timer | Live Studio |
| --- | --- | --- |
| Your own character faces for working, waiting and chilling | A countdown with optional Apple Music playback | Colored text and emoji from your Mac or an authorized phone |

No character artwork is included. You make three small GIFs of your own:
[make a character](apps/clauddy/assets/characters/README.md).

## Release status

Public beta. Character status, Pomodoro and the existing Netlify/Firebase Studio
setup have been tested on the configured Mac. Two checks remain before calling
this a fully tested release:

- A fresh Mac installation without existing dependencies, Bluetooth approval or device settings.
- A new Netlify/Firebase deployment using the bundled password-login frontend, including login, database permissions and device delivery.

A fresh public clone passes all 34 tests using the existing Python environment.
That does not verify either installation path. See [verification and remaining
checks](docs/verification.md#remaining-release-checks).

## Get started

You need macOS, Python 3.9 or newer, Xcode Command Line Tools, and a MiniToo
paired in System Settings. The original apps were tested on firmware 2.4.0.

```bash
git clone https://github.com/clea-mahoney/minitoo.git
cd minitoo
./setup.sh
./minitoo character NAME   # after adding your own GIFs, see "make a character"
./minitoo setup
./minitoo face working
./minitoo codex install   # optional automatic faces in Codex
```

Allow Bluetooth access for `divoom-send` when macOS asks. Close the Divoom phone
app and disconnect the phone from the MiniToo during setup.

The face installer asks for your Divoom login in your terminal. It uses the
account to discover your three custom face IDs. Passwords and login tokens are
not saved; device settings go in `~/.clauddy/config`.

## Use it

```bash
./minitoo character NAME                # upload a character you made
./minitoo face chilling                 # switch to an already-installed face
./minitoo pomodoro 25 5 1 --no-music     # one 30-minute cycle, including the break
./minitoo studio on                     # local controller: http://127.0.0.1:8765
./minitoo studio off                    # restore the previous face
./minitoo send picture.png              # send an image or GIF
./minitoo status
```

Character changes upload three GIFs and take longer than ordinary face switches.
Studio owns the screen until it is turned off. It sends messages over the open
Bluetooth connection and leaves character artwork intact. The controller reports
transfer acknowledgement separately from the screen's visual appearance.

For music during Pomodoro, install `switchaudio-osx` and start a playlist in
Music once. Omit `--no-music` to let the timer route it to the MiniToo. Keep the
launching terminal or chat open until the timer ends. The device's physical
return button exits the countdown view.

## Guides

- [Setup and automatic status hooks](docs/setup.md)
- [Pomodoro and optional music](apps/pomodoro/README.md)
- [Live Studio and phone access](apps/live-studio/README.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Bluetooth implementation](docs/protocol.md)
- [Release verification](docs/verification.md)

`core/` handles Bluetooth and media. `apps/` contains the three applications.
Personal settings, message logs, compiled binaries and development history are
not included in this source distribution.

## Credits and license

The new media sender implements the animation format documented by
[alvinunreal/divoom-minitoo-osx](https://github.com/alvinunreal/divoom-minitoo-osx).
It reuses this project's Bluetooth helper; it does not bundle Alvin's source.

Source code is available under the [MIT license](LICENSE). No character artwork,
vendor SDK or firmware is bundled.

This project is not affiliated with Divoom.
