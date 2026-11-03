# Clauddy

Three saved character faces show working, alerting and chilling. Fox and dino
are included. Install with `./minitoo setup` from the project root.

```bash
./minitoo character       # list characters
./minitoo character dino  # upload all three dino faces
./minitoo face working   # select a saved face
./minitoo pause 30m       # pause automatic hooks
./minitoo resume
```

Pausing affects hooks. Explicit face commands still work. Studio and Pomodoro
use the same device lock to prevent conflicting writes.

To add a character, provide `chilling.gif`, `working.gif` and `alerting.gif` in
`assets/characters/NAME/`. Use 160x128 frames with uniform frame timing. Keep
animations short so installation stays quick.

See [setup and hooks](../../docs/setup.md) for automatic status integration.
