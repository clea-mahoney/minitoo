# MiniToo development

This is a macOS MiniToo toolkit with character faces, Pomodoro and Live Studio.

- Read README.md and the relevant app source before changing behavior.
- Keep account details, device identifiers, logs and messages outside the repository.
- Preserve the shared device lock when adding commands.
- Live Studio streams media. It must not overwrite the three character slots.
- A media ACK confirms transfer acceptance, not visual correctness.
- Keep documentation focused on current setup and behavior.
- Validate public setup instructions end to end before presenting them as supported; name any unverified steps explicitly.
- Keep device tests short, about 20 seconds, and restore the previous face.
- Run `python3 -m unittest discover -s tests -v` after transport changes.
