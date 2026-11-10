# Security

Resume Bar reads your session files and holds macOS permissions, so security reports matter here, and thank you for sending one.

## Reporting a problem

Please report privately through [GitHub's private vulnerability reporting](https://github.com/porco-rs/resume-bar/security/advisories/new), not in a public issue.

So I can reproduce it, please include:

- the version you tested and your macOS version
- the steps, what you expected, and what happened
- what an attacker needs first, and what they gain

Reports found with AI tools are welcome if you have verified them yourself. There is no bug bounty.

This is a one-person project. I try to answer within seven days. We then agree on timing, I fix it privately, and I publish the affected and fixed versions together with credit if you want it.

## Supported versions

Only the latest release receives fixes.

## What Resume Bar protects against, and what it doesn't

- **In scope:** files, titles, session data and project folders with hostile contents must not make the app run commands or reach beyond what you asked for. Neither may web content in its window.
- **Not in scope:** malware already running under your user account. It can read the same files as you, and the app cannot stop it. The limits on `rb` for AI sessions are a guard rail against mistakes, not a security boundary.

Each way in and how it is closed: [threat model](THREAT_MODEL.md).

## Official downloads

Official releases come only from [the releases of this repository](https://github.com/porco-rs/resume-bar/releases). They are signed with Developer ID by Leon Vincent Schwahn, team `DLYUZB2S4C`, and notarized by Apple. Notarization is an automated check, not a promise that software is safe. Check any copy with:

```sh
codesign -dv /Applications/ResumeBar.app
```

It should show `TeamIdentifier=DLYUZB2S4C`. If a copy that presents itself as this Resume Bar shows another team, or a site offers it as an official download somewhere else, please don't run it, and tell me. Other people's projects with a similar name are their own work, not fakes.
