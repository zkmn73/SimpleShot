# Security Policy

## Reporting a vulnerability

**Preferred:** [GitHub Private Vulnerability Reporting](https://github.com/zkmn73/SimpleShot/security/advisories/new).
It is private and structured, and lets us work on a fix together before anything is public.

Please don't put proof-of-concept code or exploit details in public issues, and
don't test against systems you don't own.

This is a small, volunteer-maintained project. Reports are handled on a
best-effort basis: expect an acknowledgement within about a week, and a fix or
a concrete plan for high-severity issues as soon as practical.

## Scope

SimpleShot runs locally, has no network access and no accounts, so the relevant
surface is mainly: handling of untrusted input (image files, clipboard content,
`simpleshot://` URLs), file access outside the chosen save folder, and privilege
or permission misuse (Screen Recording, Accessibility).

## Out of scope

- Misses by the Censor tool's automatic redaction patterns (best-effort by design).
- Issues that require a compromised machine or physical access.
- Vulnerabilities in macOS or third-party dependencies themselves (please report
  them upstream, and let us know so the fixed version can be picked up).
- Denial of service limited to the app's own UI.

## Supported versions

Only the latest release. Updates are delivered through Homebrew
(`brew upgrade --cask simpleshot`) and GitHub Releases; the app does not update itself.

## Credit

There is no paid bounty (this is a free GPLv3 project), but reporters are
credited in the release notes, CHANGELOG and the GitHub advisory unless they
prefer to stay anonymous.
