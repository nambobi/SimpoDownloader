# SimpoDownloader: Persistent, Resumable Downloader for Large Files

**A free command-line download manager for Windows, Linux and macOS that won't give up.** SimpoDownloader downloads large files from the internet (datasets, ZIP archives, ISO images, videos, backups) over unstable connections. If your Wi-Fi drops, the server resets the connection, the download freezes at 0 KB/s, or the power goes off, SimpoDownloader **resumes from the exact byte where it stopped**. It never starts over.

```powershell
simpodl "https://zenodo.org/records/15401632/files/PV%20Attacks.zip?download=1"
```

> Built for researchers, students and anyone downloading multi-gigabyte files on unreliable internet or power.

---

## Why SimpoDownloader?

Downloading a 6 GB file on a weak connection with a browser or a plain `curl` command often ends like this:

```
curl: (18) end of response with 5833023470 bytes missing
curl: (56) Recv failure: Connection was reset
```

When that happens you have to restart by hand, watch the terminal, and hope the file isn't corrupted. SimpoDownloader handles all of this automatically:

| Problem | What SimpoDownloader does |
|---|---|
| Connection reset or dropped | Retries automatically and resumes from the last byte received |
| Download stuck at 0 speed | Detects the stall after 45 s and reconnects |
| Internet goes down for hours | Keeps waiting and retrying until the network is back |
| Power cut or PC crash | Run it again and it trims any damaged data, then continues |
| Is the file complete and intact? | Checks the exact size, and the MD5 checksum for Zenodo files |
| Computer goes to sleep | Keeps Windows awake until the download finishes |

## Features

- **Persistent downloads:** unlimited automatic retries with smart back-off (5 s → 60 s). It keeps going until the file is complete.
- **Resume interrupted downloads:** uses HTTP range requests to fetch only the missing part of the file.
- **Power-failure safe:** every 8 MB the data is written to disk and a checkpoint is saved, so a sudden shutdown costs at most a few megabytes.
- **Stall detection:** reconnects automatically when the speed stays at zero.
- **Remembers unfinished downloads:** `simpodl resume` continues all of them after a restart.
- **File integrity check:** fetches the official MD5 for Zenodo records automatically and verifies the file. You can also give any MD5, SHA-1 or SHA-256 checksum.
- **Clear messages:** progress bar, speed, average speed, time left and attempt number, plus a plain-English reason for every interruption ("Connection was reset", "No internet", "bytes missing").
- **Disk space check** before the download starts.
- **Safe partial files:** the download is saved as `name.part` and renamed only when complete, so a half-finished file is never mistaken for a finished one.
- **Detects server changes:** if the file on the server changes between attempts, it starts over instead of producing a corrupted mix.
- **Works on Windows, Linux and macOS.** On Windows it needs no Python and no admin rights, because it runs on the PowerShell built into Windows 10 and 11.
- **One-line install and `simpodl update`** for new versions.
- **Download log** in `~/.simpodownloader/download.log`.

## Install

### Windows 10 / 11

Open **PowerShell** and paste this one line:

```powershell
irm https://raw.githubusercontent.com/nambobi/SimpoDownloader/main/install.ps1 | iex
```

### Linux / macOS

Needs Python 3:

```bash
curl -fsSL https://raw.githubusercontent.com/nambobi/SimpoDownloader/main/install.sh | bash
```

## How to use

### Interactive: it asks for the folder, then the link

```
simpodl
```

```
Where should the file be saved?
  Enter      = this folder
  1 / 2 / 3  = Desktop / Documents / Downloads
  or type/paste any folder path (created if it does not exist)
Folder: D:\Datasets
Paste the download link: https://example.org/big-file.zip
```

### One command

```powershell
simpodl "<link>"                     # download into the current folder
simpodl "<link>" "D:\Datasets"       # download into a folder (created if missing)
simpodl "<link>" -Name data.zip      # save under a different name
simpodl "<link>" -Checksum sha256:…  # verify the file after download
```

### All commands

| Command | What it does |
|---|---|
| `simpodl` | Asks for the folder, then the link |
| `simpodl "<link>" ["folder"]` | Downloads the file |
| `simpodl resume` | Resumes every unfinished download, for example after a power cut |
| `simpodl update` | Updates SimpoDownloader to the latest version |
| `simpodl version` | Shows the installed version |
| `simpodl help` | Shows help |
| `simpodl uninstall` | Removes SimpoDownloader (Windows) |

Put links in "quotes" so symbols like `&` don't confuse the terminal.

## FAQ

**How do I resume a failed or interrupted download?**
Run the same `simpodl "<link>"` command again, or just `simpodl resume`. The partial file (`name.part`) is picked up automatically and only the missing bytes are downloaded.

**What happens if the power goes off in the middle of a download?**
The next time you run SimpoDownloader, it finds the unfinished download. It cuts the partial file back to the last checkpoint it knows was safely on disk, then continues. You lose at most about 8 MB, not the whole download.

**Can it download very large files (5 GB, 50 GB and more)?**
Yes. The file is streamed straight to disk in small chunks, so its size isn't limited by memory. The limit is the free space on your drive, which SimpoDownloader checks before it starts.

**Does it work with Zenodo, GitHub releases, Google Cloud Storage, S3 and similar?**
It works with any direct HTTP/HTTPS download link. Resuming requires the server to support range requests, which Zenodo, GitHub, S3 and most file servers do. SimpoDownloader tells you at the start whether resuming is supported.

**Does it need Python or administrator rights on Windows?**
No. The Windows version runs on the PowerShell built into Windows 10 and 11 and installs for your user account only.

**How is it different from curl or wget?**
curl and wget can resume downloads when given the right options. SimpoDownloader adds the rest automatically: unlimited retries, stall detection, recovery after a power cut, a list of unfinished downloads, checksum verification and plain-English messages. There are no flags to remember.

**How do I update it?**
Run `simpodl update`. SimpoDownloader also tells you when a new version is available.

## Files

| File | Purpose |
|---|---|
| `simpodl.ps1` | Windows version (PowerShell 5.1+) |
| `simpodl.py` | Linux / macOS version (Python 3, standard library only) |
| `install.ps1` / `install.sh` | One-line installers |
| `SimpoDownloader.bat` | Run on Windows by double-click, without installing |
| `VERSION` / `CHANGELOG.md` | Used by `simpodl update` |

## Settings

These are at the top of `simpodl.ps1` / `simpodl.py`:

- `StallTimeout`: seconds with no data before reconnecting. Default 45.
- `CheckpointEvery`: how often data is forced to disk. Default 8 MB.
- `MaxBackoff`: longest wait between retries. Default 60 s.

## Contributing

Bug reports and ideas are welcome. Please open an [issue](https://github.com/nambobi/SimpoDownloader/issues).

## License

[MIT](LICENSE). Free for personal, academic and commercial use.

---

*Keywords: persistent downloader, resumable download, resume interrupted download, large file downloader, download manager CLI, auto-retry download, unstable internet, power failure, Zenodo dataset download, PowerShell downloader, Windows command-line downloader, curl alternative, wget alternative.*
