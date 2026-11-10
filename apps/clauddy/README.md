# Clauddy

Three saved character faces show working, alerting and chilling. No artwork is
included: [make a character](assets/characters/README.md) first, then install
with `./minitoo setup` from the project root.

```bash
./minitoo character       # list characters
./minitoo character NAME  # upload all three faces for NAME
./minitoo face working   # select a saved face
./minitoo pause 30m       # pause automatic hooks
./minitoo resume
```

Pausing affects hooks. Explicit face commands still work. Studio and Pomodoro
use the same device lock to prevent conflicting writes.

To add a character, provide `chilling.gif`, `working.gif` and `alerting.gif` in
`assets/characters/NAME/`. Steps and a frame-to-GIF script are in
[make a character](assets/characters/README.md).

See [setup and hooks](../../docs/setup.md) for automatic status integration.
