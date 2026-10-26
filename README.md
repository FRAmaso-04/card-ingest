# Card Ingest

**Automatic, free memory-card importer for macOS.** Plug in an SD card, a drone card or a USB stick and a gallery opens in your browser: pick the shots you want, choose where each day goes, and Card Ingest copies them into a clean folder structure — then tells you when it's done.

*[Leggi in italiano](README.it.md)*

<!-- Add a screenshot or GIF of the gallery here: docs/gallery.png -->

## Features

- **Starts by itself** when a card is mounted (event-driven via `launchd`, no app to keep open).
- **Thumbnail gallery** grouped by shooting day. Videos play on click.
- **Per-day destination**: pick an existing project, type a new one (subfolders like `drone/fpv` work), or **browse to any folder**, even on another drive.
- **Clean layout**: `Project/YYYY-MM-DD/VIDEO|JPG|RAW` — both the date and the type subfolders can be turned off.
- **Never imports twice**: files already on the destination drive are skipped.
- **Blacklist**: files you untick are never proposed again (they are *not* deleted from the card).
- **Camera-aware**: skips Canon-style video thumbnail JPEGs (`T01.JPG`) and proxy clips (`S03.MP4`).
- **Ignores what isn't a card**: disk images (`.dmg`) of downloaded apps, installers and system volumes.
- **Safe copy**: size check on every file, the Mac doesn't sleep mid-transfer, the card can be pulled out and plugged back in at any time.
- Sound + summary dialog at the end. To stop a running copy, double-click **STOP Trasferimento** on the Desktop.

## Requirements

- macOS (tested on Apple Silicon)
- `python3` for the gallery. If it's missing, run `xcode-select --install`. Without it Card Ingest falls back to a simple list dialog.

## Install

```bash
git clone https://github.com/<your-user>/card-ingest.git
cd card-ingest
./install.sh
```

The installer asks for the destination folder (e.g. `/Volumes/MySSD/Projects`), installs the script in `~/Library/Application Support/CardIngest` and registers a LaunchAgent. Run it again any time to update.

The first time, macOS may ask for permissions (Desktop access, controlling the browser to close the gallery tab, the folder picker): allow them.

## Usage

1. Insert a card. If it contains photos/videos you haven't imported yet, the gallery opens.
2. For each day choose a project, type a new name, or click **Sfoglia…** (Browse) to pick any folder.
3. Untick what you don't want and click **Copia selezionati** (Copy selected).
4. The page closes and the copy runs in the background. A sound and a summary appear at the end.

If the destination drive isn't connected, you get a notification and the card is proposed again as soon as you connect it.

## Settings

Everything lives in `~/.card_ingest/config.sh` (see [`config.example.sh`](config.example.sh)): destination, file extensions, proxy handling, gallery timeout and port.

| File in `~/.card_ingest/` | What it is |
|---|---|
| `config.sh` | your settings |
| `blacklist.txt` | files you excluded — delete a line to get a file back |
| `recent_projects.txt` | project names shown first in the menu |
| `ingest.log` | what happened, file by file |
| `dest_index.meta` | delete it to force a rescan of the destination |

## Uninstall

```bash
./uninstall.sh           # keeps settings and blacklist
./uninstall.sh --purge   # removes everything
```

Your copied photos and videos are never touched.

## Notes

- The interface is currently in **Italian**. Translations are welcome.
- macOS only (bash + `launchd` + `qlmanage`).
- Files are matched by name + size, so a file that was renamed on the destination will be proposed again.

## Support the project

Card Ingest is free and open source. If it saves you time, you can support its development:
<!-- replace with your links -->
- GitHub Sponsors: `https://github.com/sponsors/<your-user>`
- Ko-fi: `https://ko-fi.com/<your-user>`

Bug reports and pull requests are welcome too.

## License

[MIT](LICENSE)
