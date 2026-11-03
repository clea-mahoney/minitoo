# Remote Studio

Netlify hosts the browser frontend. Firebase carries messages between that page
and your Mac. Live Studio on the Mac sends them to the MiniToo over Bluetooth.
The Mac must be awake, online, near the device, and running `./minitoo studio on`.
Netlify does not run the Python server or connect directly to the device.

```text
Phone or browser → Netlify page → Firebase → Studio on your Mac → MiniToo
```

Phone access is optional. The local controller at `http://127.0.0.1:8765` works
without Netlify or Firebase.

## What has been verified

An existing Netlify-hosted controller with Firebase anonymous login has been
tested through the Mac relay to the device. Two people confirmed the hosted
page worked. A repeat test on 2026-11-02 checked the hosted Send button through
to the MiniToo's transfer acknowledgement after migrating the Bluetooth helper.

**A fresh installation using the password-login frontend in this repository has
not been validated end to end.** Its example configuration and database rules
are implementation references, not a verified installation guide. The existing
hosted page and the packaged page currently use different login modes.

## Connect an existing anonymous-login page

Keep the existing Netlify deployment and Firebase project. Store the relay's
local settings in `~/.clauddy/live-studio.env`:

```bash
export FIREBASE_DB_URL="https://YOUR_PROJECT-default-rtdb.firebaseio.com"
export FIREBASE_API_KEY="YOUR_FIREBASE_WEB_API_KEY"
export FIREBASE_AUTH_MODE="anonymous"
```

Keep this file on your Mac, then run:

```bash
chmod 600 ~/.clauddy/live-studio.env
./minitoo studio on
```

Open your existing Netlify URL. Wait for the page to say it is ready, then send
a short message. The page waits for the Mac's transfer result. An acknowledgement
means the MiniToo accepted the image; check the physical screen for legibility.
Sender names appear only in logs.

Studio waits for the next remote send after startup. It does not automatically
replay the message left in Firebase. Back/forward replays history only when
requested. Turn Studio off with `./minitoo studio off` to restore the previous
character and hook pause state.

## Netlify frontend files

The frontend source is `apps/live-studio/remote-page/`. Netlify serves its
`index.html`, `log.html`, and Firebase web configuration in `config.js`.
`config.example.js` shows the required fields. The configured folder is the
static site; the rest of the repository stays on your Mac.

Netlify supports deploying that folder directly, without a ZIP or build step.
For an existing manually deployed site, updates go to that site's **Deploys**
page. See [Netlify's deployment instructions](https://docs.netlify.com/deploy/create-deploys/#drag-and-drop).
A public GitHub checkout does not contain the ignored `config.js`, so connecting
GitHub to Netlify alone does not produce a configured frontend.

Do not replace an existing anonymous-login page with the packaged password-login
page until its accounts, rules and complete send flow have been validated.
Never put the relay account's email or password in frontend files. Firebase web
configuration is visible to browsers; Firebase access rules control database
access. Personal settings remain outside Git.

## Logs

The existing hosted controller records messages in its Firebase `minitoo-log`
node. Access follows that project's rules. The packaged `log.html` uses password
login; its fresh-project access rules still need live validation.

The Mac also keeps a private log at
`~/.clauddy/live-studio/messages.jsonl` for previous/next replay. Neither message
log belongs in a public repository.
