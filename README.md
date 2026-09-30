# SimpoDownloader

A command-line downloader for big files on unreliable internet and power. If the network drops, the server resets the connection, the download freezes, or the power goes off, run it again and it continues from where it stopped. It never starts over.

## Install

**Windows:** open PowerShell and paste this one line. No admin rights or Python needed:

```powershell
irm https://raw.githubusercontent.com/nambobi/SimpoDownloader/main/install.ps1 | iex
```

**Linux / macOS** (needs Python 3):

```bash
curl -fsSL https://raw.githubusercontent.com/nambobi/SimpoDownloader/main/install.sh | bash
```

## Use

Type `simpodl`. It asks two things:

```
Where should the file be saved?
Folder: D:\Data
Paste the download link: https://zenodo.org/records/15401632/files/PV%20Attacks.zip?download=1
```

It then downloads. Or give everything in one go:

| Command | What it does |
|---|---|
| `simpodl` | Asks for the folder, then the link |
| `simpodl "<link>"` | Downloads into the folder the terminal is in |
| `simpodl "<link>" "D:\Data"` | Downloads into `D:\Data` (created if missing) |
| `simpodl "<link>" -Name new.zip` | Saves under a different name |
| `simpodl resume` | Continues every unfinished download, for example after a power cut |
| `simpodl update` | Gets the newest version from this GitHub page |
| `simpodl help` | Shows all commands |
| `simpodl uninstall` | Removes it (Windows) |

Put links in "quotes" so symbols like `&` in some links don't confuse the terminal.

## Features

- **Auto-resume:** retries forever, asking the server only for the missing part. The wait between tries grows from 5 s up to 60 s.
- **Power-cut safe:** every 8 MB it forces the data onto the disk and records a checkpoint. After a crash it trims any damaged data at the end of the file, then resumes.
- **Stall detection:** if no data arrives for 45 s, it reconnects instead of hanging at 0 speed.
- **Remembers unfinished downloads:** the next run offers to resume them.
- **Integrity check:** fetches the official MD5 for Zenodo links automatically and verifies the file. For other sites, use `-Checksum md5:...`.
- **Plain-English messages** for every failure, for example "Connection was reset", "No internet" or "bytes missing".
- **Checks free disk space** before starting, and **keeps Windows awake** while downloading.
- **Update notice:** checks for a new version at most once a day, then `simpodl update` installs it.
- **Log** of every attempt in `~/.simpodownloader/download.log`.

While a download is in progress you will see `name.part` and `name.part.json` next to it. Don't delete them if you want to resume. They are removed automatically when the download finishes.

## Files

| File | What it is |
|---|---|
| `simpodl.ps1` | Windows version (PowerShell 5.1+, built into Windows 10/11) |
| `simpodl.py` | Linux/macOS version (Python 3, standard library only) |
| `install.ps1` / `install.sh` | Installers used by the one-line commands above |
| `SimpoDownloader.bat` | Runs it on Windows by double-click, without installing |
| `VERSION` / `CHANGELOG.md` | Used by `simpodl update` |

## Settings

These are at the top of `simpodl.ps1` / `simpodl.py`:

- `StallTimeout` / `STALL_TIMEOUT`: seconds with no data before reconnecting. Default 45.
- `CheckpointEvery` / `CHECKPOINT_EVERY`: how often data is forced to disk. Default 8 MB.
- `MaxBackoff` / `MAX_BACKOFF`: longest wait between retries. Default 60 s.

## License

MIT
