# Changelog

## 1.0.0 - 2026-10-26

First public release.

- Event-driven detection of memory cards (`launchd` WatchPaths) with a monitor that catches cards removed and re-inserted while a copy is running
- Browser gallery grouped by day, thumbnails generated on demand, videos loaded only when played
- Per-day destination: existing project, new project (nested paths allowed) or any folder via the native folder picker
- Optional date and type subfolders
- Cached index of files already on the destination, blacklist of excluded files
- Skips disk images, installers and system volumes
- Pending cards are proposed again when the destination drive is connected
- Installer and uninstaller
