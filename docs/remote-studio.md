# Remote Studio

Phone access is optional. The local controller works without a cloud account.
Use your own Firebase project and web hosting. The Mac polls Firebase over HTTPS
and forwards messages to its local Studio server.

## Configure your project

1. Create a Firebase project and Realtime Database in locked mode.
2. Enable Email/Password under Firebase Authentication. This is the default
   login mode for new installations.
3. Create a sender account and a separate relay account. Copy their UIDs from
   Authentication > Users.
4. Replace `SENDER_UID` and `RELAY_UID` in
   `apps/live-studio/database.rules.example.json`, then publish those rules in
   your project's Realtime Database Rules editor. The sender and relay can read
   current messages. Only the relay can update device status. Only the sender
   can append cloud log entries. Other users cannot read or write these nodes.
5. Register a Firebase web app. Copy
   `apps/live-studio/remote-page/config.example.js` to `config.js` beside it and
   fill in your web app configuration.
6. Copy `personal.env.example` to `personal.env`. Set the database URL, web API
   key, relay email and relay password. Keep this file on the Mac. Run
   `chmod 600 personal.env`.
7. Add your hosting domain to Firebase Authentication's authorized domains.
8. Deploy the `apps/live-studio/remote-page/` folder, including your local
   `config.js`, to static HTTPS hosting such as Netlify.
9. Run `./minitoo studio on`. Open your hosted page on the phone and sign in
   with the sender account. Send a short message and check the physical screen.

The Firebase web configuration is client configuration, not a password. Database
rules restrict access to the two selected UIDs. Do not put relay credentials in
the web page. `personal.env` and `config.js` are ignored by Git.

The controller waits for a transfer result from the Mac. A successful transfer
ACK means that the device accepted the media; check the screen to confirm its
appearance. Sender names appear only in logs.

## Reuse an existing anonymous-login page

If an existing hosted controller already uses anonymous Firebase login, the relay
can connect to the same project without replacing that page. Store its local
settings in `~/.clauddy/live-studio.env`:

```bash
export FIREBASE_DB_URL="https://YOUR_PROJECT-default-rtdb.firebaseio.com"
export FIREBASE_API_KEY="YOUR_FIREBASE_WEB_API_KEY"
export FIREBASE_AUTH_MODE="anonymous"
```

Run `chmod 600 ~/.clauddy/live-studio.env`, then restart Studio. This follows the
project's existing access rules; it does not change them. Tokens are refreshed
in memory. The packaged remote page uses password login, so keep the existing
hosted page unless you are also migrating its accounts and rules.

Studio waits for the next remote send after startup. It does not automatically
replay the message left in Firebase. Back/forward still replays history when
explicitly requested.

## Logs

The phone controller appends messages to your Firebase `minitoo-log` node.
`log.html` requires an authorized account to read it. The Mac keeps a separate
private log at `~/.clauddy/live-studio/messages.jsonl` for previous/next replay.
Neither log belongs in a public repository.

Reference: [Firebase database rules](https://firebase.google.com/docs/database/security)
and [email/password REST authentication](https://firebase.google.com/docs/reference/rest/auth#section-sign-in-email-password).
