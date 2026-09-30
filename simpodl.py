#!/usr/bin/env python3
"""
SimpoDownloader - a resumable, never-give-up file downloader.

Works on Windows, Linux and macOS (detects the OS automatically).
Uses only the Python standard library - nothing to pip install.

Survives:
  * network drops, "connection was reset", "end of response with N bytes missing"
  * stalled downloads (speed stuck at 0) - detected and restarted
  * power cuts / PC crashes / closing the window - just run it again and
    it offers to resume where it stopped

Usage:
  Interactive:      python simpodl.py
  One-liner:        python simpodl.py "<url>" -o "D:\\Data" -n file.zip
  Resume leftovers: python simpodl.py --resume
"""

import argparse
import hashlib
import http.client
import json
import os
import platform
import re
import shutil
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque

VERSION = "1.3"
REPO_RAW = "https://raw.githubusercontent.com/nambobi/SimpoDownloader/main"
CHUNK = 1024 * 256                 # bytes read per loop
CHECKPOINT_EVERY = 8 * 1024 ** 2   # force data to disk every 8 MB (power-cut safety)
STALL_TIMEOUT = 45                 # seconds with no data before we give up on a connection
MAX_BACKOFF = 60                   # longest wait between retries (seconds)
USER_AGENT = f"SimpoDownloader/{VERSION} (+python urllib)"

OS_NAME = {"Windows": "Windows", "Darwin": "macOS", "Linux": "Linux"}.get(platform.system(), platform.system())
STATE_DIR = os.path.join(os.path.expanduser("~"), ".simpodownloader")
PENDING_FILE = os.path.join(STATE_DIR, "pending.json")
LOG_FILE = os.path.join(STATE_DIR, "download.log")


# ----------------------------------------------------------------- colours / output
if OS_NAME == "Windows":
    os.system("")  # turns on ANSI colour support in Windows 10/11 consoles
try:
    sys.stdout.reconfigure(errors="replace")
except Exception:
    pass

C = {"cyan": "\033[96m", "yellow": "\033[93m", "green": "\033[92m", "red": "\033[91m",
     "grey": "\033[90m", "bold": "\033[1m", "end": "\033[0m"}
if not sys.stdout.isatty():
    C = {k: "" for k in C}


def say(msg, colour=None, end="\n"):
    clear_line()
    print(f"{C[colour]}{msg}{C['end']}" if colour else msg, end=end, flush=True)


def clear_line():
    width = shutil.get_terminal_size((100, 20)).columns
    print("\r" + " " * (width - 1) + "\r", end="", flush=True)


def log(msg):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except Exception:
        pass


def human(n):
    if n is None:
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.2f} {unit}"
        n /= 1024


def hms(seconds):
    if seconds is None or seconds < 0 or seconds > 99 * 3600:
        return "--:--:--"
    s = int(seconds)
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}"


# ----------------------------------------------------------------- OS folders
def known_folders():
    """Return real Desktop / Documents / Downloads paths for this OS (handles OneDrive redirection)."""
    home = os.path.expanduser("~")
    folders = {"Desktop": os.path.join(home, "Desktop"),
               "Documents": os.path.join(home, "Documents"),
               "Downloads": os.path.join(home, "Downloads")}
    if OS_NAME == "Windows":
        try:
            import winreg
            key = winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                                 r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
            for name, reg in (("Desktop", "Desktop"), ("Documents", "Personal"),
                              ("Downloads", "{374DE290-123F-4565-9164-39C4925E467B}")):
                try:
                    val, _ = winreg.QueryValueEx(key, reg)
                    folders[name] = os.path.expandvars(val)
                except OSError:
                    pass
        except Exception:
            pass
    elif OS_NAME == "Linux":
        for name, xdg in (("Desktop", "DESKTOP"), ("Documents", "DOCUMENTS"), ("Downloads", "DOWNLOAD")):
            try:
                out = subprocess.run(["xdg-user-dir", xdg], capture_output=True, text=True, timeout=3).stdout.strip()
                if out and out != home:
                    folders[name] = out
            except Exception:
                pass
    return folders


def clean_path(p):
    p = p.strip().strip('"').strip("'")          # "Copy as path" on Windows adds quotes
    return os.path.abspath(os.path.expandvars(os.path.expanduser(p)))


def safe_filename(name):
    name = urllib.parse.unquote(name).strip()
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).rstrip(". ")
    return name or "download.bin"


# ----------------------------------------------------------------- keep the PC awake
class KeepAwake:
    """Stops the computer going to sleep mid-download (it does NOT help with power cuts)."""
    def __enter__(self):
        self.proc = None
        try:
            if OS_NAME == "Windows":
                import ctypes
                ctypes.windll.kernel32.SetThreadExecutionState(0x80000000 | 0x00000001)
            elif OS_NAME == "macOS":
                self.proc = subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())])
            elif shutil.which("systemd-inhibit"):
                self.proc = subprocess.Popen(
                    ["systemd-inhibit", "--what=sleep", "--why=SimpoDownloader", "--mode=block",
                     "sleep", "infinity"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
        return self

    def __exit__(self, *a):
        try:
            if OS_NAME == "Windows":
                import ctypes
                ctypes.windll.kernel32.SetThreadExecutionState(0x80000000)
            if self.proc:
                self.proc.terminate()
        except Exception:
            pass


# ----------------------------------------------------------------- pending-download registry
def load_pending():
    try:
        with open(PENDING_FILE, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            data = [data] if "dest" in data else [dict(v, dest=k) for k, v in data.items()]
        return {d["dest"]: d for d in data if isinstance(d, dict) and d.get("dest")}
    except Exception:
        return {}


def save_pending(data):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = PENDING_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, PENDING_FILE)
    except Exception:
        pass


def mark_pending(dest, job):
    p = load_pending()
    p[dest] = {"url": job["url"], "checksum": job.get("checksum"), "added": time.strftime("%Y-%m-%d %H:%M")}
    save_pending(p)


def unmark_pending(dest):
    p = load_pending()
    if p.pop(dest, None) is not None:
        save_pending(p)


# ----------------------------------------------------------------- network helpers
class FatalError(Exception):
    """Errors where retrying is pointless (404, 403, disk full...)."""


def open_url(url, headers=None, timeout=STALL_TIMEOUT):
    h = {"User-Agent": USER_AGENT, "Accept-Encoding": "identity"}
    h.update(headers or {})
    return urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=timeout)


def explain(exc):
    """Turn a Python/network exception into a plain-English reason + suggested wait."""
    if isinstance(exc, urllib.error.HTTPError):
        code = exc.code
        if code in (400, 401, 403, 404, 410):
            raise FatalError(f"Server says HTTP {code} {exc.reason} - the link is wrong, private or expired.")
        wait = None
        ra = exc.headers.get("Retry-After") if exc.headers else None
        if ra and ra.isdigit():
            wait = int(ra)
        if code == 429:
            return "Server says too many requests (HTTP 429) - slowing down", wait or 60
        return f"Server error HTTP {code} {exc.reason}", wait
    if isinstance(exc, urllib.error.URLError):
        exc = exc.reason if isinstance(exc.reason, Exception) else exc
    if isinstance(exc, socket.gaierror):
        return "No internet (cannot resolve the server name) - waiting for the network to come back", None
    if isinstance(exc, (socket.timeout, TimeoutError)):
        return f"Download stalled - no data for {STALL_TIMEOUT}s", None
    if isinstance(exc, ConnectionResetError):
        return "Connection was reset by the server/network", None
    if isinstance(exc, ConnectionRefusedError):
        return "Connection refused", None
    if isinstance(exc, http.client.IncompleteRead):
        return "Server closed the connection early (bytes missing)", None
    if isinstance(exc, ssl.SSLError):
        return f"Secure connection (SSL) error: {exc}", None
    if isinstance(exc, OSError) and getattr(exc, "errno", None) == 28:
        raise FatalError("Disk is full! Free some space and run again to resume.")
    return f"{type(exc).__name__}: {exc}", None


def filename_from_headers(headers):
    cd = headers.get("Content-Disposition") or ""
    m = re.search(r"filename\*\s*=\s*[^']*''([^;]+)", cd, re.I)
    if m:
        return urllib.parse.unquote(m.group(1).strip().strip('"'))
    m = re.search(r'filename\s*=\s*"?([^";]+)"?', cd, re.I)
    return m.group(1).strip() if m else None


def probe(url):
    """Ask the server for file size, resume support and a suggested name (retries until it answers)."""
    wait = 5
    while True:
        try:
            with open_url(url, {"Range": "bytes=0-0"}, timeout=30) as r:
                h = r.headers
                info = {"url": r.geturl(), "ranges": False, "total": None,
                        "etag": h.get("ETag"), "lastmod": h.get("Last-Modified"),
                        "name": filename_from_headers(h)}
                if r.status == 206:
                    m = re.search(r"/(\d+)\s*$", h.get("Content-Range", ""))
                    info["total"] = int(m.group(1)) if m else None
                    info["ranges"] = True
                else:
                    cl = h.get("Content-Length")
                    info["total"] = int(cl) if cl and cl.isdigit() else None
                    info["ranges"] = h.get("Accept-Ranges", "").lower() == "bytes"
                return info
        except FatalError:
            raise
        except Exception as e:
            reason, _ = explain(e)
            say(f"Could not reach the server: {reason}. Trying again in {wait}s...", "yellow")
            time.sleep(wait)
            wait = min(wait * 2, MAX_BACKOFF)


def zenodo_checksum(url, filename):
    """Zenodo publishes an MD5 for every file - fetch it so we can verify the download."""
    m = re.search(r"zenodo\.org/(?:api/)?records?/(\d+)/files/([^/?#]+)", url)
    if not m:
        return None
    try:
        with open_url(f"https://zenodo.org/api/records/{m.group(1)}", {"Accept": "application/json"}, 20) as r:
            data = json.load(r)
        want = urllib.parse.unquote(m.group(2))
        for f in data.get("files", []):
            if f.get("key") in (want, filename):
                return f.get("checksum")
    except Exception:
        return None
    return None


# ----------------------------------------------------------------- checksum
def parse_checksum(text):
    if not text:
        return None
    text = text.strip().lower()
    if ":" in text:
        algo, value = text.split(":", 1)
    else:
        value = text
        algo = {32: "md5", 40: "sha1", 64: "sha256", 128: "sha512"}.get(len(text))
    if algo not in hashlib.algorithms_available or not re.fullmatch(r"[0-9a-f]+", value):
        return None
    return algo, value


def verify_file(path, checksum):
    algo, expected = checksum
    h = hashlib.new(algo)
    total = os.path.getsize(path)
    done = 0
    last = 0
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(4 * 1024 * 1024), b""):
            h.update(block)
            done += len(block)
            if time.time() - last > 0.5:
                last = time.time()
                print(f"\r  Verifying {algo.upper()}... {done * 100 // max(total, 1)}%", end="", flush=True)
    clear_line()
    return h.hexdigest() == expected, h.hexdigest()


# ----------------------------------------------------------------- progress display
class Progress:
    def __init__(self, total):
        self.total = total
        self.samples = deque()
        self.last_draw = 0
        self.session_start = time.time()
        self.session_bytes = 0

    def update(self, done, attempt, force=False):
        now = time.time()
        self.samples.append((now, done))
        while len(self.samples) > 2 and now - self.samples[0][0] > 8:
            self.samples.popleft()
        if not force and now - self.last_draw < 0.5:
            return
        self.last_draw = now
        t0, b0 = self.samples[0]
        speed = (done - b0) / (now - t0) if now > t0 else 0
        avg = self.session_bytes / (now - self.session_start) if now > self.session_start else 0
        if self.total:
            pct = done * 100 / self.total
            eta = (self.total - done) / speed if speed > 0 else None
            bar_w = 20
            fill = int(bar_w * done / self.total)
            line = (f"  [{'#' * fill}{'.' * (bar_w - fill)}] {pct:5.1f}%  {human(done)} / {human(self.total)}"
                    f"  | {human(speed)}/s (avg {human(avg)}/s)  | ETA {hms(eta)}  | try #{attempt}")
        else:
            line = f"  {human(done)} downloaded  | {human(speed)}/s  | try #{attempt}"
        width = shutil.get_terminal_size((100, 20)).columns
        print("\r" + line[:width - 1].ljust(width - 1), end="", flush=True)


# ----------------------------------------------------------------- the core download loop
def write_meta(meta_path, meta):
    tmp = meta_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(meta, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, meta_path)


def download(job):
    url, dest = job["url"], job["dest"]
    part, meta_path = dest + ".part", dest + ".part.json"
    info = job["info"]
    total = info["total"]

    # --- recover from a previous run (including a power cut) ---
    meta = {}
    if os.path.exists(meta_path):
        try:
            with open(meta_path, encoding="utf-8") as f:
                meta = json.load(f)
        except Exception:
            meta = {}
    if os.path.exists(part):
        size = os.path.getsize(part)
        if meta.get("url") and meta["url"] != url:
            say("A partial file from a DIFFERENT link exists - starting fresh.", "yellow")
            os.replace(part, part + ".old")
            meta = {}
        elif "checkpoint" in meta and meta["checkpoint"] < size:
            # after a power cut the file may end in garbage/zeros that never really got written;
            # trim back to the last point we KNOW was safely on disk.
            with open(part, "r+b") as f:
                f.truncate(meta["checkpoint"])
            say(f"Recovered after unexpected shutdown - trimmed {human(size - meta['checkpoint'])} of unsafe data.",
                "yellow")
        if meta.get("etag") and info.get("etag") and meta["etag"] != info["etag"]:
            say("The file on the server has changed since last time - starting over.", "yellow")
            with open(part, "wb"):
                pass

    meta.update({"url": url, "etag": info.get("etag"), "lastmod": info.get("lastmod"), "total": total})
    if not os.path.exists(part):
        open(part, "wb").close()
        meta["checkpoint"] = 0
    write_meta(meta_path, meta)
    mark_pending(dest, job)

    attempt = 0
    wait = 5
    progress = Progress(total)

    while True:
        have = os.path.getsize(part)
        if total is not None and have >= total:
            break
        attempt += 1
        progress.samples.clear()
        headers = {}
        if have > 0:
            headers["Range"] = f"bytes={have}-"
            validator = info.get("etag") or info.get("lastmod")
            if validator:
                headers["If-Range"] = validator
        say(f"--- Attempt #{attempt}: " + (f"resuming {os.path.basename(dest)} from {human(have)} ---" if have
                                            else f"downloading {os.path.basename(dest)} ---"), "cyan")
        log(f"attempt {attempt} {dest} from byte {have}")
        progress_before = have
        try:
            with open_url(url, headers) as r:
                if have > 0 and r.status == 200:
                    say("Server ignored the resume request - it will restart from 0 (it does not support resuming).",
                        "yellow")
                    have = 0
                    mode = "wb"
                elif r.status == 206:
                    m = re.match(r"bytes\s+(\d+)-", r.headers.get("Content-Range", ""))
                    if m and int(m.group(1)) != have:
                        raise ConnectionError("Server resumed from the wrong position")
                    mode = "r+b"
                else:
                    mode = "wb"
                if total is None:
                    cl = r.headers.get("Content-Length")
                    if cl and cl.isdigit():
                        total = have + int(cl) if r.status == 206 else int(cl)
                        progress.total = total

                with open(part, mode) as f:
                    f.seek(have)
                    f.truncate()
                    since_ckpt = 0
                    try:
                        while True:
                            block = r.read(CHUNK)
                            if not block:
                                break
                            f.write(block)
                            have += len(block)
                            since_ckpt += len(block)
                            progress.session_bytes += len(block)
                            if since_ckpt >= CHECKPOINT_EVERY:
                                f.flush()
                                os.fsync(f.fileno())
                                meta["checkpoint"] = have
                                write_meta(meta_path, meta)
                                since_ckpt = 0
                            progress.update(have, attempt)
                    finally:
                        f.flush()
                        os.fsync(f.fileno())
                        meta["checkpoint"] = have
                        write_meta(meta_path, meta)
                progress.update(have, attempt, force=True)
                print()

            if total is not None and have < total:
                raise http.client.IncompleteRead(b"", total - have)
            if total is None:
                break  # unknown size + clean end of stream = done
        except FatalError:
            raise
        except urllib.error.HTTPError as e:
            if e.code == 416 and total is not None and os.path.getsize(part) >= total:
                break  # "range not satisfiable" = we already have everything
            reason, hint = explain(e)
            wait = retry_wait(reason, have, total, hint or wait)
            continue
        except KeyboardInterrupt:
            raise
        except Exception as e:
            reason, hint = explain(e)
            if have > progress_before:
                wait = 5  # we made progress, so reset the back-off
            wait = retry_wait(reason, have, total, hint or wait)
            continue

    # --- finished: sanity checks, rename, verify ---
    final_size = os.path.getsize(part)
    if total is not None and final_size != total:
        raise FatalError(f"Size mismatch: got {final_size} bytes, expected {total}.")
    if os.path.exists(dest):
        os.replace(dest, dest + ".previous")
    os.replace(part, dest)
    try:
        os.remove(meta_path)
    except OSError:
        pass
    unmark_pending(dest)
    log(f"done {dest} {final_size} bytes")
    say(f"Downloaded {human(final_size)} -> {dest}", "green")

    checksum = parse_checksum(job.get("checksum"))
    if checksum:
        ok, got = verify_file(dest, checksum)
        if ok:
            say(f"Checksum OK ({checksum[0].upper()} matches) - the file is intact.", "green")
        else:
            say(f"CHECKSUM MISMATCH! expected {checksum[1]}\n                     got      {got}", "red")
            say("The file is corrupted. Delete it and download again.", "red")
            log(f"checksum mismatch {dest}")
            return False
    return True


def retry_wait(reason, have, total, wait):
    print()
    pct = f" ({have * 100 / total:.1f}% saved)" if total else f" ({human(have)} saved)"
    say(f"Download interrupted: {reason}{pct}", "yellow")
    log(f"interrupted: {reason} at {have}")
    for s in range(int(wait), 0, -1):
        print(f"\r{C['yellow']}  Retrying in {s:>2}s...  (Ctrl+C to pause - you can resume later){C['end']}",
              end="", flush=True)
        time.sleep(1)
    clear_line()
    return min(wait * 2, MAX_BACKOFF)


# ----------------------------------------------------------------- interactive prompts
def ask(prompt, default=None):
    suffix = f" [{default}]" if default else ""
    ans = input(f"{C['bold']}{prompt}{suffix}: {C['end']}").strip()
    return ans or (default or "")


def choose_folder():
    folders = known_folders()
    say("\nWhere do you want to save the file?", "cyan")
    say(f"  1) Desktop     {C['grey']}{folders['Desktop']}{C['end']}")
    say(f"  2) Documents   {C['grey']}{folders['Documents']}{C['end']}")
    say(f"  3) Downloads   {C['grey']}{folders['Downloads']}{C['end']}")
    say("  4) Type / paste a folder path")
    while True:
        c = ask("Choose 1-4", "1")
        if c in ("1", "2", "3"):
            path = folders[["Desktop", "Documents", "Downloads"][int(c) - 1]]
        elif c == "4":
            raw = ask("Folder path")
            if not raw:
                continue
            path = clean_path(raw)
        else:
            say("Please type 1, 2, 3 or 4.", "yellow")
            continue
        if os.path.isdir(path):
            say(f"Folder exists: {path}", "green")
            return path
        if os.path.exists(path):
            say("That path is a file, not a folder. Try again.", "red")
            continue
        try:
            os.makedirs(path, exist_ok=True)
            say(f"Folder did not exist - created it: {path}", "green")
            return path
        except OSError as e:
            say(f"Could not create folder: {e}", "red")


def ask_url():
    while True:
        url = ask("\nPaste the download link").strip().strip('"').strip("'")
        if re.match(r"^https?://\S+$", url, re.I):
            return url
        say("That does not look like a web link (must start with http:// or https://).", "yellow")


def check_disk(folder, need):
    if not need:
        return True
    free = shutil.disk_usage(folder).free
    if free < need:
        say(f"Not enough disk space: need {human(need)}, only {human(free)} free on that drive.", "red")
        return ask("Continue anyway? (y/n)", "n").lower().startswith("y")
    say(f"Disk space OK: {human(free)} free, file needs {human(need)}.", "grey")
    return True


def prepare_job(url, folder=None, name=None, checksum=None, interactive=True):
    say("Checking the link...", "grey")
    info = probe(url)
    suggested = safe_filename(name or info["name"] or os.path.basename(urllib.parse.urlparse(info["url"]).path))
    say(f"  Size: {human(info['total']) if info['total'] else 'unknown'}   "
        f"Resume supported: {'yes' if info['ranges'] else 'NO (a drop means starting over)'}",
        "green" if info["ranges"] else "yellow")
    if interactive and not name:
        suggested = safe_filename(ask("File name", suggested))
    if folder is None:
        folder = choose_folder() if interactive else os.getcwd()
    os.makedirs(folder, exist_ok=True)
    dest = os.path.join(folder, suggested)

    if os.path.exists(dest) and info["total"] and os.path.getsize(dest) == info["total"] and interactive:
        say("A file with that name and the same size already exists.", "yellow")
        if not ask("Download again anyway? (y/n)", "n").lower().startswith("y"):
            return None

    if not checksum:
        checksum = zenodo_checksum(url, suggested)
        if checksum:
            say(f"  Found official checksum on Zenodo: {checksum}", "green")
        elif interactive:
            checksum = ask("Expected checksum, if the site lists one (MD5/SHA256) - Enter to skip", "") or None
    have = os.path.getsize(dest + ".part") if os.path.exists(dest + ".part") else 0
    if not check_disk(folder, (info["total"] or 0) - have):
        return None
    return {"url": url, "dest": dest, "info": info, "checksum": checksum}


def resume_menu(auto=False):
    pending = {d: v for d, v in load_pending().items() if os.path.exists(d + ".part")}
    save_pending(pending)
    if not pending:
        if auto:
            say("Nothing to resume.", "grey")
        return []
    say("\nUnfinished downloads found (from a power cut, network loss or Ctrl+C):", "yellow")
    items = list(pending.items())
    for i, (dest, v) in enumerate(items, 1):
        say(f"  {i}) {os.path.basename(dest)}  - {human(os.path.getsize(dest + '.part'))} saved  "
            f"{C['grey']}{os.path.dirname(dest)}{C['end']}")
    ans = "a" if auto else ask("Resume which? (number, 'a' = all, Enter = skip)", "")
    if ans.lower() == "a":
        chosen = items
    elif ans.isdigit() and 1 <= int(ans) <= len(items):
        chosen = [items[int(ans) - 1]]
    else:
        return []
    jobs = []
    for dest, v in chosen:
        info = probe(v["url"])
        jobs.append({"url": v["url"], "dest": dest, "info": info, "checksum": v.get("checksum")})
    return jobs


def run_jobs(jobs):
    results = []
    with KeepAwake():
        for job in jobs:
            try:
                results.append((job["dest"], download(job)))
            except FatalError as e:
                print()
                say(f"STOPPED: {e}", "red")
                log(f"fatal {job['dest']}: {e}")
                results.append((job["dest"], False))
    if OS_NAME == "Windows":
        try:
            import winsound
            winsound.MessageBeep()
        except Exception:
            pass
    else:
        print("\a", end="")
    return results


def self_update():
    say("Checking GitHub for a newer version...", "grey")
    try:
        with open_url(REPO_RAW + "/VERSION", timeout=15) as r:
            latest = r.read().decode().strip()
        newer = tuple(map(int, latest.split("."))) > tuple(map(int, VERSION.split(".")))
    except Exception as e:
        say(f"Could not reach GitHub: {e}", "red")
        return False
    if not newer:
        say(f"You already have the latest version ({VERSION}).", "green")
        return True
    target = os.path.realpath(__file__)
    try:
        with open_url(REPO_RAW + "/simpodl.py", timeout=60) as r:
            code = r.read()
        compile(code, "simpodl.py", "exec")   # refuse a damaged download
        shutil.copy2(target, target + ".bak")
        with open(target + ".new", "wb") as f:
            f.write(code)
        os.chmod(target + ".new", 0o755)
        os.replace(target + ".new", target)
    except Exception as e:
        say(f"Update failed: {e}. Your current version still works.", "red")
        return False
    say(f"Updated SimpoDownloader {VERSION} -> {latest}", "green")
    return True


def main():
    ap = argparse.ArgumentParser(description="Resumable, auto-retrying downloader")
    ap.add_argument("url", nargs="?", help="link to download (omit for interactive mode)")
    ap.add_argument("folder", nargs="?", help="folder to save into (default: current folder)")
    ap.add_argument("-o", "--out", help="folder to save into (created if missing)")
    ap.add_argument("-n", "--name", help="file name to save as")
    ap.add_argument("-c", "--checksum", help="expected checksum e.g. md5:abc... or a bare sha256")
    ap.add_argument("--resume", action="store_true", help="resume all unfinished downloads and exit")
    args = ap.parse_args()
    if args.url == "help":
        ap.print_help()
        return
    if args.url == "update":
        sys.exit(0 if self_update() else 1)
    if args.url in ("resume",):
        args.resume, args.url = True, None
    elif args.url in ("version",):
        print(f"SimpoDownloader {VERSION}")
        return
    elif args.url and not re.match(r"^https?://", args.url, re.I):
        ap.error(f"not a web link: {args.url}")
    args.out = args.out or args.folder

    say(f"=== SimpoDownloader {VERSION} === running on {OS_NAME}", "cyan")
    try:
        if args.resume:
            run_jobs(resume_menu(auto=True))
            return
        if args.url:
            job = prepare_job(args.url, clean_path(args.out) if args.out else None, args.name,
                              args.checksum, interactive=False)
            ok = run_jobs([job])[0][1] if job else False
            sys.exit(0 if ok else 1)

        jobs = resume_menu()
        if jobs:
            run_jobs(jobs)
        while True:
            job = prepare_job(ask_url())
            if job:
                results = run_jobs([job])
                if results and results[0][1]:
                    say("SUCCESS! The file is fully downloaded.", "green")
            if not ask("\nDownload another file? (y/n)", "n").lower().startswith("y"):
                break
    except KeyboardInterrupt:
        print()
        say("Paused. Progress is saved - run SimpoDownloader again and choose to resume.", "yellow")
        sys.exit(130)
    except EOFError:
        print()


if __name__ == "__main__":
    main()
