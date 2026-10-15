# macinto.sh

A computer use tunnel for macOS. `Macinto.app` is a menu bar app that holds the
Accessibility and Screen Recording permissions. `macinto.sh` is a plain bash CLI
that asks the app to click, type, press keys, read the UI tree, take screenshots
and record the screen.

Agents and scripts call `macinto.sh`; only the app needs to be trusted by macOS.
The app does nothing until you enable it from the menu bar, and enabling is
time-limited.

```
$ macinto.sh status
enabled: yes
remaining: 1712
accessibility: granted
screen_recording: granted
...
$ macinto.sh open TextEdit
$ macinto.sh key cmd+n
$ macinto.sh type "Hello from macinto 🍎"
$ macinto.sh screenshot -o /tmp/screen.png
/tmp/screen.png 1800x1169
```

Requires macOS 15 or later.

## Install

1. Download `Macinto-<version>.dmg`, open it, and drag Macinto to Applications.
2. Open Macinto. It is not notarized yet, so macOS blocks the first launch.
   Go to System Settings > Privacy & Security, scroll down, and click
   **Open Anyway** next to the Macinto message. (Or right-click the app >
   Open.)
3. Click the 🍎 in the menu bar and use the **Grant…** buttons:
   - **Accessibility**: needed for `click`, `move`, `drag`, `scroll`, `type`,
     `key`, `ui`, `press`, `focus`, `setvalue`.
   - **Screen Recording**: needed for `screenshot` and `record`. macOS applies
     this grant only after Macinto restarts, so quit and reopen it.
4. Click **Install command line tool…** to link `macinto.sh` into
   `/opt/homebrew/bin` (if it exists and is writable) or `/usr/local/bin`
   (asks for an admin password).

If your menu bar is full, macOS hides new menu bar icons without telling the
app. When that happens Macinto opens a small window with the same controls.
Run `open -a Macinto` at any time to bring that window back.

## Enabling, the timer, and the red apple

Macinto starts **disabled** every time it launches. While disabled, every CLI
request except `status` is refused:

```
macinto.sh: macinto is disabled — enable it from the menu bar
```

To enable it, pick a duration on the slider (5 min to 8 h, default 30 min) and
click **Enable**. When the timer runs out, Macinto disables itself and stops any
recording in progress. The last notch on the slider is ∞, which stays on until
you turn it off.

There is no CLI command to enable Macinto. Turning it on needs a person at the
menu.

While enabled:

- The menu bar icon is a full-color 🍎. When disabled it is a dimmed, gray 🍎.
- A big red apple flashes in the top-right corner of the main screen, just
  below the menu bar. It ignores the mouse, shows on every Space, and is left
  out of Macinto's own screenshots and recordings.

The menu also shows the time remaining, the last 10 requests (time, calling
process and pid, command), and whether each permission is granted.

## CLI reference

```
macinto.sh <command> [args]
```

Coordinates are global points with the origin at the top-left of the main
display (the CGEvent convention). Screenshots are scaled to points by default,
so a pixel at (x, y) in a screenshot of display 0 is clicked with
`macinto.sh click x y`.

| Command | What it does |
|---|---|
| `status` | Enabled?, seconds remaining (or ∞), permissions, version, displays (origin and size in points) |
| `apps` | Running apps: `*` marks the frontmost; pid, bundle id, name |
| `location` | Current mouse position |
| `click X Y [--right] [--double]` | Click at a point |
| `move X Y` | Move the pointer |
| `drag X1 Y1 X2 Y2` | Left-button drag |
| `scroll DX DY` | Scroll by lines; positive DY scrolls up, negative scrolls down |
| `type TEXT` | Type any Unicode text. Newlines press Return, tabs press Tab |
| `key COMBO [COMBO ...]` | Key presses such as `cmd+shift+g`, `return`, `escape`, `tab`, `f5`, `left`, `cmd+plus` |
| `keys` | List accepted key names |
| `open APP` | Activate an app by name, bundle id or path, launching it if needed |
| `ui [--app NAME] [--depth N]` | Dump the accessibility tree of the app's focused window (default: frontmost app) |
| `press ID [--app NAME]` | Perform AXPress on an element |
| `focus ID [--app NAME]` | Focus an element |
| `setvalue ID TEXT [--app NAME]` | Set an element's value (e.g. a text field) |
| `screenshot [-o FILE] [--force] [--display N] [--app NAME] [--native]` | PNG of a display. Default file `./macinto-YYYYmmdd-HHMMSS.png`. `--app` keeps only that app's windows. `--native` keeps full Retina resolution |
| `record start [-o FILE.mov] [--force] [--display N]` | Start a screen recording |
| `record stop` | Stop and move the movie to the `-o` path |
| `record status` | Is a recording running? |
| `wait SECONDS` | Sleep (runs in the CLI) |
| `help`, `--version` | |

Exit codes: `0` ok, `1` error, `2` usage error.

Output files are never overwritten unless you pass `--force`.

### UI tree

`ui` prints one line per element: an id, role, title, description, value and
frame in points.

```
$ macinto.sh ui --app TextEdit --depth 3
app: TextEdit (com.apple.TextEdit, pid 4121)
0 AXWindow/AXStandardWindow "Untitled" @310,120 800x600 focused
  0.0 AXScrollArea @310,172 800x548
    0.0.0 AXTextArea value="Hello from macinto 🍎" @310,172 785x548 focused
  0.1 AXButton/AXCloseButton @318,129 14x16
...
$ macinto.sh press 0.1 --app TextEdit
```

Ids are index paths from the window (`0`), resolved again on every call. If the
UI changes between `ui` and `press`, run `ui` again.

### Examples

```bash
# Open Spotlight, launch Calculator, compute something
macinto.sh key cmd+space
macinto.sh wait 0.5
macinto.sh type "Calculator"
macinto.sh key return
macinto.sh wait 1
macinto.sh type "12*34="

# Screenshot just one app
macinto.sh screenshot --app Safari -o safari.png

# Record ten seconds
macinto.sh record start -o demo.mov
macinto.sh wait 10
macinto.sh record stop
```

## Security model

- The CLI talks to the app over a Unix socket at
  `~/Library/Application Support/macinto/macinto.sock`. The directory is mode
  0700 and the socket is mode 0600, so only your user can connect. The app also
  checks the peer's uid on every connection.
- **Anything running as your user can drive this Mac while Macinto is
  enabled.** That includes scripts, agents and anything else on your account.
  This is why enabling needs a click at the menu, expires on a timer, and shows
  a flashing apple for as long as it lasts.
- Every request is appended to `~/Library/Logs/macinto.log` (mode 0600) with a
  timestamp, the caller's pid and process chain as reported by the kernel
  (`LOCAL_PEERPID`, e.g. `nc[812] <- macinto.sh[810] <- claude[700]`), the
  command (arguments truncated to 80 characters), and the result. Text sent
  with `type` appears in the log, truncated, so avoid typing secrets through
  macinto.
- Screenshots and recordings are written to
  `~/Library/Application Support/macinto/captures/`, then the CLI moves them to
  their destination. This way the app never writes into your folders, and
  doesn't trigger extra macOS folder-access prompts.
- macOS ties the privacy grants to the app's code signature. Rebuilding with a
  different signature makes macOS forget them; see Signing below.

## Wire protocol

One request per connection, which keeps it usable from bash with the built-in
`nc -U`:

```
request:  <command> <base64 arg> <base64 arg> ...\n     ("-" is an empty argument)
response: ok\n<payload lines>   or   error <message>\n
```

```bash
printf 'status\n' | nc -U ~/Library/Application\ Support/macinto/macinto.sock
printf 'type %s\n' "$(printf 'hi' | base64)" | nc -U ~/Library/Application\ Support/macinto/macinto.sock
```

## Build from source

Requires Xcode 16 or later (Swift 6) and macOS 15 or later. No Xcode project;
SwiftPM builds the binary and the Makefile assembles the bundle.

```bash
make cert       # once: create a self-signed "macinto local signing" certificate
make app        # build/Macinto.app (universal, release)
make dmg        # build/Macinto-<version>.dmg
make run        # build and open
```

The version lives in `VERSION`.

### Signing

macOS keeps Accessibility and Screen Recording grants per code signature.
An ad-hoc signature (`-`) changes on every build, so macOS forgets the grants
after each rebuild. `make cert` creates a self-signed code signing certificate
in your login keychain. Builds signed with it keep the same designated
requirement, so grants survive rebuilds. `spctl` still rejects it, because it
is not a Developer ID.

`SIGN_IDENTITY` picks the identity. The default is `macinto local signing` if it
exists, otherwise ad-hoc:

```bash
make app SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
make dmg SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
make notarize SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   # needs a 'macinto-notary' notarytool profile
```

### Dev builds

`make dev-app` builds `build/debug/Macinto.app` in the debug configuration. Dev
builds only accept a launch argument that enables Macinto for testing without
clicking the menu:

```bash
open build/debug/Macinto.app --args --enable-for-testing 60   # seconds, max 3600
```

This code is compiled out of release builds (`#if DEBUG`). Don't distribute
dev builds.

## Layout

```
macinto.sh               CLI (also bundled in Macinto.app/Contents/Resources)
Sources/Macinto/         app: socket server, commands, input, AX tree, capture, menu, overlay
Resources/Info.plist     bundle Info.plist template
scripts/                 icon renderer, signing certificate helper
Makefile, VERSION
```

## License

MIT. Copyright (c) 2026 Kyle Wild.
