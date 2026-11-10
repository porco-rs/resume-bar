# Threat model

Resume Bar reads files that other programs write, and it can type a command into your terminal. This page says what it guards, where hostile input can come in, how each way in is closed, and what is out of reach. To report a problem, see [SECURITY.md](SECURITY.md).

## What is worth protecting

- **Your terminal.** Resuming a session types a command into Ghostty or Terminal. Nothing but your own settings should decide what that command is.
- **Your list.** Titles, project folders and goals. A title can contain a few words of your first prompt.
- **The release signature.** Official builds are signed with the maker's Developer ID. A copy signed by anyone else is not an official build.

## Where hostile input can come in, and how it is closed

| Way in | What could go wrong | What stops it |
|---|---|---|
| Session files of Claude Code and Codex | A crafted session id, folder or title turns into shell code | Session ids must be 1 to 128 ASCII letters, digits, `.`, `_`, `:` or `-`, starting with a letter or digit; anything else is ignored. An unsafe id already stored from an older version is never put into a command. Folders become one quoted shell word. Titles are escaped before they are shown |
| The window | Injected markup runs script and uses the window's power: it can change settings, including the resume command | Text is escaped. The page allows only its own script and its own stylesheets: no inline script or style, no images, frames, forms or network. The app accepts messages only from its own page in the main frame and never navigates elsewhere. The page sends key presses and clicks; what they mean is decided in Swift |
| `rb`, the command line tool | Another program uses `rb` to read or change your list | A Unix socket readable only by you, and the kernel confirms the caller runs as your user. AI sessions get `ls`, `add` and `done` only, within their own project |
| Terminals, through Automation | The app drives a terminal it should not | Only Ghostty and Terminal: it reads their windows and working folders, opens and focuses windows, and types the resume command from your settings |
| The network | Session data leaves your Mac | The app makes no network calls. Its own code has none, the window cannot load anything from outside, and a runtime check of the app and its WebKit helpers saw no internet socket |
| Downloads | A modified copy poses as Resume Bar | Developer ID signature, hardened runtime whose only entitlement is Apple Events for the terminals, notarization. Official copies come only from the releases of this repository; `codesign -dv` shows the team |
| The repository | A contribution or workflow reaches the maker's keys | CI runs with a read-only token and no secrets. Signing and notarization happen only on the maker's Mac, never in CI, and pull requests are not accepted for now |

## Out of reach

- **Programs already running as you.** They can read the same files, talk to `rb` like you do, and pretend to be you. The `rb` limits for AI sessions are a guard rail against mistakes, not a wall.
- **Administrators, root and physical access** to your Mac.
- **Claude Code, Codex and your terminal themselves.** Resume Bar starts them; what they do afterwards is theirs.
- **Commands you write into the settings.** They run as you wrote them.

## What stays visible

Titles can show words from your first prompt on screen. The timing logs in `~/Library/Logs/ResumeBar/` hold no session content. `rb export` prints your whole list to whoever runs it as your user.
