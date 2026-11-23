# -*- coding: utf-8 -*-
"""
Anime4K Center - one-click graphical installer (Windows).

Standard library only: tkinter, urllib.request, zipfile, os, shutil,
subprocess, threading.

What it does
------------
1. Downloads the latest sources of the project from GitHub (main.zip)
   and unpacks them into the chosen folder.
2. Downloads and unpacks the current mpv (x86_64), yt-dlp.exe, Magpie
   (optional) and the Whisper ggml-base.bin model (optional).
3. Creates a desktop shortcut "Anime4K Center" with a generated icon.
4. Offers a "Launch Anime4K Center now" button.
"""

import base64
import json
import os
import queue
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

try:
    import ctypes

    ctypes.windll.shcore.SetProcessDpiAwareness(1)
except Exception:  # noqa: BLE001 - not critical, just crisper text
    pass

# --------------------------------------------------------------------------
#  Project / sources
# --------------------------------------------------------------------------
GITHUB_OWNER = "iks5liv"
REPO = "Anime4K-Center"
REPO_ZIP = "https://github.com/{0}/{1}/archive/refs/heads/main.zip".format(
    GITHUB_OWNER, REPO)
YTDLP_URL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
MODEL_URL = ("https://huggingface.co/ggerganov/whisper.cpp/"
             "resolve/main/ggml-base.bin")
MPV_REPOS = ("shinchiro/mpv-winbuild-cmake", "zhongfly/mpv-winbuild")

DEFAULT_DIR = r"C:\Anime4K-Center"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0

# --------------------------------------------------------------------------
#  Palette (Anime4K Center UI)
# --------------------------------------------------------------------------
BG = "#18181b"
CARD = "#232327"
CARD_2 = "#27272a"
BORDER = "#3f3f46"
ACCENT = "#6366f1"
ACCENT_HOVER = "#4f46e5"
ACCENT_DIM = "#4338ca"
FG = "#f4f4f5"
MUTED = "#a1a1aa"
GREEN = "#22c55e"
GREEN_HOVER = "#16a34a"

FONT = "Segoe UI"


# --------------------------------------------------------------------------
#  Helpers: network / archives
# --------------------------------------------------------------------------
def _request(url, timeout=60):
    return urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "*/*",
    })


def download(url, destination, progress=None, timeout=90):
    """Stream a file to *destination*; *progress* gets (fraction, done, total)."""
    folder = os.path.dirname(destination)
    if folder:
        os.makedirs(folder, exist_ok=True)
    part = destination + ".part"
    with urllib.request.urlopen(_request(url), timeout=timeout) as response, \
            open(part, "wb") as handle:
        total = int(response.headers.get("Content-Length") or 0)
        done = 0
        last = 0.0
        while True:
            chunk = response.read(262144)
            if not chunk:
                break
            handle.write(chunk)
            done += len(chunk)
            now = time.time()
            if progress and (now - last > 0.15 or done == total):
                last = now
                progress((done / total) if total else 0.0, done, total)
    os.replace(part, destination)
    return destination


def _safe_members(archive):
    for member in archive.infolist():
        name = member.filename.replace("\\", "/")
        if name.startswith("/") or ".." in name.split("/"):
            continue
        yield member


def extract_zip(archive, destination):
    os.makedirs(destination, exist_ok=True)
    with zipfile.ZipFile(archive) as zf:
        for member in _safe_members(zf):
            zf.extract(member, destination)


def extract_7z(archive, destination):
    """Unpack .7z with bsdtar (Windows 10+), then try 7-Zip."""
    os.makedirs(destination, exist_ok=True)
    commands = []
    tar = shutil.which("tar")
    if tar:
        commands.append([tar, "-xf", archive, "-C", destination])
    for name in ("7z", "7za"):
        found = shutil.which(name)
        if found:
            commands.append([found, "x", "-y", "-o" + destination, archive])
    for command in commands:
        try:
            result = subprocess.run(command, capture_output=True, timeout=900,
                                    creationflags=CREATE_NO_WINDOW)
            if result.returncode == 0:
                return True
        except Exception:  # noqa: BLE001
            continue
    return False


def gh_latest_asset(repo, predicate):
    """Return (tag, download_url) for the first matching asset of the latest release."""
    api = "https://api.github.com/repos/{0}/releases/latest".format(repo)
    request = urllib.request.Request(api, headers={
        "User-Agent": UA, "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            data = json.loads(response.read().decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return "", ""
    for asset in data.get("assets", []):
        if predicate(str(asset.get("name", ""))):
            return data.get("tag_name", ""), str(
                asset.get("browser_download_url", ""))
    return data.get("tag_name", ""), ""


def gh_release_asset(repo, predicate, pages=2):
    """Search several recent releases, not only the latest one."""
    for page in range(1, max(1, pages) + 1):
        api = ("https://api.github.com/repos/{0}/releases"
               "?per_page=20&page={1}".format(repo, page))
        request = urllib.request.Request(api, headers={
            "User-Agent": UA, "Accept": "application/vnd.github+json"})
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                data = json.loads(response.read().decode("utf-8", "replace"))
        except Exception:  # noqa: BLE001
            return "", ""
        if not isinstance(data, list):
            return "", ""
        for release in data:
            for asset in release.get("assets", []):
                if predicate(str(asset.get("name", ""))):
                    return release.get("tag_name", ""), str(
                        asset.get("browser_download_url", ""))
    return "", ""


def copy_tree_contents(source, target):
    os.makedirs(target, exist_ok=True)
    for item in os.listdir(source):
        src = os.path.join(source, item)
        dst = os.path.join(target, item)
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=True)
        else:
            shutil.copy2(src, dst)


def human(size):
    value = float(size or 0)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return "{0:.1f} {1}".format(value, unit)
        value /= 1024.0
    return "{0:.1f} GB".format(value)


# --------------------------------------------------------------------------
#  Icon + shortcut
# --------------------------------------------------------------------------
def make_icon(path, size=64):
    """Generate a 32-bit .ico (indigo rounded square + white play triangle)."""
    radius = size * 0.22
    tri = ((size * 0.37, size * 0.26),
           (size * 0.37, size * 0.74),
           (size * 0.76, size * 0.50))
    sub = 4

    def inside_round(x, y):
        cx = min(max(x, radius), size - radius)
        cy = min(max(y, radius), size - radius)
        return (x - cx) ** 2 + (y - cy) ** 2 <= radius * radius

    def inside_tri(x, y):
        (x1, y1), (x2, y2), (x3, y3) = tri
        d1 = (x - x2) * (y1 - y2) - (x1 - x2) * (y - y2)
        d2 = (x - x3) * (y2 - y3) - (x2 - x3) * (y - y3)
        d3 = (x - x1) * (y3 - y1) - (x3 - x1) * (y - y1)
        neg = d1 < 0 or d2 < 0 or d3 < 0
        pos = d1 > 0 or d2 > 0 or d3 > 0
        return not (neg and pos)

    top = (0x63, 0x66, 0xf1)
    bottom = (0x43, 0x38, 0xca)
    rows = []
    samples = sub * sub
    for py in range(size):
        row = bytearray()
        t = py / float(size - 1)
        base = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for px in range(size):
            covered = 0
            filled = 0
            for sy in range(sub):
                for sx in range(sub):
                    x = px + (sx + 0.5) / sub
                    y = py + (sy + 0.5) / sub
                    if inside_round(x, y):
                        covered += 1
                        if inside_tri(x, y):
                            filled += 1
            if not covered:
                row += b"\x00\x00\x00\x00"
                continue
            blend = filled / float(samples)
            red = int(base[0] * (1 - blend) + 255 * blend)
            green = int(base[1] * (1 - blend) + 255 * blend)
            blue = int(base[2] * (1 - blend) + 255 * blend)
            alpha = int(255 * covered / float(samples))
            row += bytes((blue, green, red, alpha))
        rows.append(bytes(row))

    pixels = b"".join(reversed(rows))
    mask = b"\x00" * (((size + 31) // 32) * 4) * size
    header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0,
                         len(pixels), 0, 0, 0, 0)
    image = header + pixels + mask
    directory = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32,
                        len(image), 22)
    with open(path, "wb") as handle:
        handle.write(directory + entry + image)
    return path


def create_shortcut(target_dir, icon_path):
    """Create 'Anime4K Center.lnk' on the real desktop via WScript.Shell."""
    script = """
$ErrorActionPreference = 'Stop'
$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'Anime4K Center.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnk)
$shortcut.TargetPath = '{0}'
$shortcut.WorkingDirectory = '{1}'
$shortcut.IconLocation = '{2},0'
$shortcut.Description = 'Anime4K Center - 4K media player and launcher'
$shortcut.WindowStyle = 1
$shortcut.Save()
Write-Output $lnk
""".format(os.path.join(target_dir, "Anime4K_Center.vbs"),
           target_dir, icon_path)
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    result = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy",
         "Bypass", "-EncodedCommand", encoded],
        capture_output=True, timeout=180, creationflags=CREATE_NO_WINDOW)
    output = (result.stdout or b"").decode("utf-8", "replace").strip()
    if output and os.path.isfile(output):
        return output
    return ""


def pick_install_dir(desired):
    """Use the requested folder, fall back to %LOCALAPPDATA% if not writable."""
    try:
        os.makedirs(desired, exist_ok=True)
        probe = os.path.join(desired, ".write_test")
        with open(probe, "w", encoding="utf-8") as handle:
            handle.write("ok")
        os.remove(probe)
        return desired, ""
    except OSError as exc:  # noqa: BLE001
        fallback = os.path.join(
            os.environ.get("LOCALAPPDATA") or tempfile.gettempdir(),
            "Anime4K-Center")
        os.makedirs(fallback, exist_ok=True)
        return fallback, "Нет прав на запись в {0} ({1}). Устанавливаю в {2}".format(
            desired, exc.__class__.__name__, fallback)


# --------------------------------------------------------------------------
#  Installer window
# --------------------------------------------------------------------------
class Installer(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Anime4K Center — установка")
        self.configure(bg=BG)
        self.resizable(False, False)
        self.geometry("680x600")
        self._center()

        self.messages = queue.Queue()
        self.installed_dir = ""
        self.busy = False

        self.var_path = tk.StringVar(value=DEFAULT_DIR)
        self.var_shortcut = tk.BooleanVar(value=True)
        self.var_magpie = tk.BooleanVar(value=True)
        self.var_whisper = tk.BooleanVar(value=True)
        self.var_status = tk.StringVar(value="Готов к установке")

        self._build_ui()
        self.after(120, self._pump)
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(250, self._dark_titlebar)

    def _dark_titlebar(self):
        """Ask DWM for a dark title bar (Windows 10 1809+)."""
        try:
            import ctypes

            frame = self.wm_frame()
            hwnd = int(frame, 16) if frame else 0
            if not hwnd:
                return
            value = ctypes.c_int(1)
            for attribute in (20, 19):
                if ctypes.windll.dwmapi.DwmSetWindowAttribute(
                        hwnd, attribute, ctypes.byref(value),
                        ctypes.sizeof(value)) == 0:
                    break
            ctypes.windll.user32.SetWindowPos(
                hwnd, 0, 0, 0, 0, 0,
                0x0001 | 0x0002 | 0x0020 | 0x0010)  # nosize|nomove|frame|noactivate
        except Exception:  # noqa: BLE001 - purely cosmetic
            pass

    # -- layout ----------------------------------------------------------
    def _center(self):
        self.update_idletasks()
        width, height = 680, 600
        x = (self.winfo_screenwidth() - width) // 2
        y = max(0, (self.winfo_screenheight() - height) // 2 - 40)
        self.geometry("{0}x{1}+{2}+{3}".format(width, height, x, y))

    def _build_ui(self):
        header = tk.Frame(self, bg=BG)
        header.pack(fill="x", padx=28, pady=(24, 6))
        badge = tk.Frame(header, bg=ACCENT, width=46, height=46)
        badge.pack_propagate(False)
        badge.pack(side="left", padx=(0, 12))
        tk.Label(badge, text="\u25b6", font=(FONT, 18, "bold"), bg=ACCENT,
                 fg="#ffffff").pack(expand=True)
        titles = tk.Frame(header, bg=BG)
        titles.pack(side="left", anchor="w")
        tk.Label(titles, text="Anime4K Center", font=(FONT, 19, "bold"),
                 bg=BG, fg=FG).pack(anchor="w")
        tk.Label(titles, text="Установка в один клик · AI 4K медиаплеер",
                 font=(FONT, 10), bg=BG, fg=MUTED).pack(anchor="w")

        body = tk.Frame(self, bg=BG)
        body.pack(fill="both", expand=True, padx=28, pady=(6, 0))

        # --- folder ---
        card = tk.Frame(body, bg=CARD, highlightbackground=BORDER,
                        highlightthickness=1)
        card.pack(fill="x", pady=(6, 12))
        tk.Label(card, text="Папка установки", font=(FONT, 10, "bold"),
                 bg=CARD, fg=FG).pack(anchor="w", padx=16, pady=(12, 4))
        row = tk.Frame(card, bg=CARD)
        row.pack(fill="x", padx=16, pady=(0, 14))
        entry = tk.Entry(row, textvariable=self.var_path, font=(FONT, 10),
                         bg=CARD_2, fg=FG, insertbackground=FG,
                         relief="flat", highlightthickness=1,
                         highlightbackground=BORDER,
                         highlightcolor=ACCENT)
        entry.pack(side="left", fill="x", expand=True, ipady=6)
        tk.Button(row, text="Изменить папку", command=self._choose_dir,
                  font=(FONT, 9), bg=CARD_2, fg=FG, activebackground=BORDER,
                  activeforeground=FG, relief="flat", cursor="hand2",
                  padx=12, pady=6).pack(side="left", padx=(8, 0))

        # --- options ---
        opts = tk.Frame(body, bg=CARD, highlightbackground=BORDER,
                        highlightthickness=1)
        opts.pack(fill="x", pady=(0, 12))
        tk.Label(opts, text="Параметры", font=(FONT, 10, "bold"),
                 bg=CARD, fg=FG).pack(anchor="w", padx=16, pady=(12, 2))
        self._check(opts, "Создать ярлык на Рабочем столе",
                    self.var_shortcut)
        self._check(opts, "Установить Magpie (4K поверх браузера)",
                    self.var_magpie)
        self._check(opts, "Скачать модель ИИ-субтитров (Whisper, ~142 МБ)",
                    self.var_whisper)

        # --- action ---
        self.btn_install = tk.Button(
            body, text="Установить в один клик", command=self._start,
            font=(FONT, 12, "bold"), bg=ACCENT, fg="#ffffff",
            activebackground=ACCENT_HOVER, activeforeground="#ffffff",
            relief="flat", cursor="hand2", pady=12)
        self.btn_install.pack(fill="x", pady=(0, 12))

        self.btn_launch = tk.Button(
            body, text="Запустить Anime4K Center сейчас",
            command=self._launch, font=(FONT, 11, "bold"), bg=GREEN,
            fg="#0b1220", activebackground=GREEN_HOVER,
            activeforeground="#0b1220", relief="flat", cursor="hand2",
            pady=11)

        # --- progress ---
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Accent.Horizontal.TProgressbar",
                        troughcolor=CARD_2, background=ACCENT,
                        bordercolor=CARD_2, lightcolor=ACCENT,
                        darkcolor=ACCENT, thickness=10)
        self.bar = ttk.Progressbar(body, style="Accent.Horizontal.TProgressbar",
                                   mode="determinate", maximum=100)
        self.bar.pack(fill="x", pady=(0, 8))

        self.lbl_status = tk.Label(body, textvariable=self.var_status,
                                   font=(FONT, 9), bg=BG, fg=MUTED,
                                   anchor="w", justify="left")
        self.lbl_status.pack(fill="x")

        self.log = tk.Text(body, height=7, font=("Consolas", 8), bg=CARD,
                           fg=MUTED, relief="flat", highlightthickness=1,
                           highlightbackground=BORDER, wrap="word",
                           state="disabled")
        self.log.pack(fill="both", expand=True, pady=(10, 0))

    def _check(self, parent, text, variable):
        row = tk.Frame(parent, bg=CARD)
        row.pack(fill="x", padx=12, pady=2)
        tk.Checkbutton(row, text=text, variable=variable, font=(FONT, 10),
                       bg=CARD, fg=FG, activebackground=CARD,
                       activeforeground=FG, selectcolor=CARD_2,
                       highlightthickness=0, bd=0, anchor="w",
                       cursor="hand2").pack(anchor="w")

    # -- small utils -----------------------------------------------------
    def _log(self, text):
        self.messages.put(("log", text))

    def _status(self, text):
        self.messages.put(("status", text))

    def _progress(self, percent):
        self.messages.put(("progress", max(0.0, min(100.0, percent))))

    def _pump(self):
        try:
            while True:
                kind, payload = self.messages.get_nowait()
                if kind == "log":
                    self.log.configure(state="normal")
                    self.log.insert("end", payload + "\n")
                    self.log.see("end")
                    self.log.configure(state="disabled")
                elif kind == "status":
                    self.var_status.set(payload)
                elif kind == "progress":
                    self.bar["value"] = payload
                elif kind == "done":
                    self._finish(payload)
                elif kind == "fail":
                    self._fail(payload)
        except queue.Empty:
            pass
        self.after(120, self._pump)

    def _choose_dir(self):
        if self.busy:
            return
        chosen = filedialog.askdirectory(title="Куда установить Anime4K Center",
                                         initialdir=self.var_path.get() or "C:\\")
        if chosen:
            self.var_path.set(os.path.normpath(chosen))

    def _on_close(self):
        if self.busy and not messagebox.askyesno(
                "Установка идёт",
                "Установка ещё не завершена. Прервать и выйти?"):
            return
        self.destroy()

    # -- install flow ----------------------------------------------------
    def _start(self):
        if self.busy:
            return
        self.busy = True
        self.btn_install.configure(state="disabled", bg=CARD_2,
                                   text="Установка…")
        self.btn_launch.pack_forget()
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        self.bar["value"] = 0
        thread = threading.Thread(target=self._install, daemon=True)
        thread.start()

    def _install(self):
        try:
            self._run()
        except Exception as exc:  # noqa: BLE001
            self.messages.put(("fail", "{0}: {1}".format(
                exc.__class__.__name__, exc)))

    def _run(self):
        wanted = (self.var_path.get() or DEFAULT_DIR).strip().strip('"')
        target, warning = pick_install_dir(wanted)
        if warning:
            self._status(warning)
            self._log(warning)
            self.var_path.set(target)

        use_shortcut = bool(self.var_shortcut.get())
        use_magpie = bool(self.var_magpie.get())
        use_whisper = bool(self.var_whisper.get())

        weights = {"repo": 20.0, "unpack": 6.0, "mpv": 26.0, "ytdlp": 6.0,
                   "magpie": 12.0, "whisper": 22.0, "finish": 8.0}
        order = ["repo", "unpack", "mpv", "ytdlp"]
        if use_magpie:
            order.append("magpie")
        if use_whisper:
            order.append("whisper")
        order.append("finish")
        total_weight = sum(weights[name] for name in order)
        state = {"done": 0.0, "index": 0}

        def task_progress(fraction):
            fraction = max(0.0, min(1.0, fraction))
            weight = weights[order[state["index"]]]
            self._progress(100.0 * (state["done"] + weight * fraction)
                           / total_weight)

        def advance(_name=None):
            weight = weights[order[state["index"]]]
            state["done"] += weight
            if state["index"] < len(order) - 1:
                state["index"] += 1
            self._progress(100.0 * state["done"] / total_weight)
        whisper_dir = os.path.join(target, "portable_config", "whisper")
        os.makedirs(whisper_dir, exist_ok=True)

        with tempfile.TemporaryDirectory(prefix="anime4k_setup_") as tmp:
            # --- 1. project sources -------------------------------------
            self._status("Скачиваю исходники проекта с GitHub…")
            self._log("GET " + REPO_ZIP)
            archive = os.path.join(tmp, "main.zip")
            download(REPO_ZIP, archive,
                     lambda f, d, t: (task_progress(f * 0.75),
                                      self._status("Исходники: {0} из {1}".format(
                                          human(d), human(t)))),
                     timeout=120)
            task_progress(1.0)
            advance("unpack")

            self._status("Распаковываю исходники…")
            unpacked = os.path.join(tmp, "src")
            extract_zip(archive, unpacked)
            roots = [name for name in os.listdir(unpacked)
                     if os.path.isdir(os.path.join(unpacked, name))]
            source = (os.path.join(unpacked, roots[0]) if roots else unpacked)
            copy_tree_contents(source, target)
            os.makedirs(whisper_dir, exist_ok=True)
            self._log("Исходники распакованы в " + target)
            advance("mpv")

            # --- 2. mpv -------------------------------------------------
            self._status("Ищу свежую сборку mpv (x86_64)…")
            mpv_url, mpv_tag = "", ""
            for repo in MPV_REPOS:
                mpv_tag, candidate = gh_latest_asset(
                    repo, lambda n: (n.lower().startswith("mpv-x86_64-")
                                     and n.lower().endswith(".7z")
                                     and "dev" not in n.lower()
                                     and "v3" not in n.lower()
                                     and "debug" not in n.lower()))
                if candidate:
                    mpv_url = candidate
                    self._log("mpv: {0} · {1}".format(repo, mpv_tag))
                    break
            if not mpv_url:
                raise RuntimeError("не найден mpv x86_64 на GitHub")
            mpv_archive = os.path.join(tmp, "mpv.7z")
            download(mpv_url, mpv_archive,
                     lambda f, d, t: (task_progress(f * 0.7),
                                      self._status("mpv: {0} из {1}".format(
                                          human(d), human(t)))),
                     timeout=180)
            self._status("Распаковываю mpv…")
            mpv_dir = os.path.join(tmp, "mpv")
            if not extract_7z(mpv_archive, mpv_dir):
                raise RuntimeError("не удалось распаковать mpv (.7z)")
            copied = 0
            for root, _dirs, files in os.walk(mpv_dir):
                depth = os.path.relpath(root, mpv_dir).count(os.sep)
                if depth > 1:
                    continue
                for name in files:
                    low = name.lower()
                    if low in ("mpv.exe", "mpv.com") or low.endswith(".dll"):
                        shutil.copy2(os.path.join(root, name),
                                     os.path.join(target, name))
                        copied += 1
            if not os.path.isfile(os.path.join(target, "mpv.exe")):
                raise RuntimeError("в архиве mpv нет mpv.exe")
            task_progress(1.0)
            self._log("mpv установлен ({0} файлов)".format(copied))
            advance("ytdlp")

            # --- 3. yt-dlp ----------------------------------------------
            self._status("Скачиваю yt-dlp.exe…")
            download(YTDLP_URL, os.path.join(target, "yt-dlp.exe"),
                     lambda f, d, t: (task_progress(f),
                                      self._status("yt-dlp: {0} из {1}".format(
                                          human(d), human(t)))))
            task_progress(1.0)
            self._log("yt-dlp.exe скачан")
            advance()

            # --- 4. Magpie ----------------------------------------------
            if use_magpie:
                self._status("Ищу свежий Magpie…")
                magpie_tag, magpie_url = gh_latest_asset(
                    "Blinue/Magpie",
                    lambda n: (n.lower().endswith(".zip")
                               and "x64" in n.lower()
                               and "arm" not in n.lower()))
                if not magpie_url:
                    self._log("[!] Magpie не найден — пропускаю шаг")
                    task_progress(1.0)
                else:
                    self._log("Magpie: " + magpie_tag)
                    magpie_archive = os.path.join(tmp, "magpie.zip")
                    download(magpie_url, magpie_archive,
                             lambda f, d, t: (task_progress(f * 0.75),
                                              self._status("Magpie: {0} из {1}".format(
                                                  human(d), human(t)))))
                    magpie_dir = os.path.join(tmp, "magpie")
                    extract_zip(magpie_archive, magpie_dir)
                    exe = None
                    for root, _dirs, files in os.walk(magpie_dir):
                        if "Magpie.exe" in files:
                            exe = os.path.join(root, "Magpie.exe")
                            break
                    if exe:
                        copy_tree_contents(os.path.dirname(exe),
                                           os.path.join(target, "Magpie"))
                        self._log("Magpie установлен")
                    else:
                        self._log("[!] в архиве Magpie нет Magpie.exe")
                    task_progress(1.0)
                advance()

            # --- 5. Whisper ---------------------------------------------
            if use_whisper:
                self._status("Скачиваю whisper.cpp (x64)…")
                wtag, wurl = gh_release_asset(
                    "ggml-org/whisper.cpp",
                    lambda n: n.lower() == "whisper-bin-x64.zip", pages=2)
                if wurl:
                    warchive = os.path.join(tmp, "whisper.zip")
                    download(wurl, warchive,
                             lambda f, d, t: (task_progress(f * 0.3),
                                              self._status("whisper.cpp: {0} из {1}".format(
                                                  human(d), human(t)))))
                    wdir = os.path.join(tmp, "whisper")
                    extract_zip(warchive, wdir)
                    exe = None
                    for root, _dirs, files in os.walk(wdir):
                        if "whisper-cli.exe" in files:
                            exe = os.path.join(root, "whisper-cli.exe")
                            break
                    if exe:
                        copy_tree_contents(os.path.dirname(exe), whisper_dir)
                        self._log("whisper-cli.exe установлен ({0})".format(wtag))
                    else:
                        self._log("[!] whisper-cli.exe не найден в архиве")
                else:
                    self._log("[!] сборка whisper.cpp не найдена — только модель")

                self._status("Скачиваю модель ggml-base.bin (~142 МБ)…")
                download(MODEL_URL, os.path.join(whisper_dir, "ggml-base.bin"),
                         lambda f, d, t: (task_progress(0.3 + f * 0.7),
                                          self._status("Модель: {0} из {1}".format(
                                              human(d), human(t)))),
                         timeout=300)
                task_progress(1.0)
                self._log("Модель ggml-base.bin скачана")
                advance()

            # --- 6. icon + shortcut -------------------------------------
            self._status("Создаю иконку и ярлык…")
            icon = os.path.join(target, "Anime4K_Center.ico")
            try:
                make_icon(icon)
            except Exception as exc:  # noqa: BLE001
                self._log("[!] иконка не создана: " + str(exc))
                icon = os.path.join(target, "mpv.exe")
            if use_shortcut:
                lnk = create_shortcut(target, icon)
                self._log("Ярлык: " + (lnk or "не создан"))
            task_progress(1.0)
            advance()

        self.installed_dir = target
        self._progress(100.0)
        self._status("Готово! Anime4K Center установлен в " + target)
        self.messages.put(("done", target))

    # -- final states ----------------------------------------------------
    def _finish(self, target):
        self.busy = False
        self.btn_install.configure(state="disabled", bg=CARD_2,
                                   text="Установлено ✓")
        self.btn_launch.pack(fill="x", pady=(0, 10), before=self.bar)
        self._log("Установка завершена: " + target)

    def _fail(self, message):
        self.busy = False
        self.btn_install.configure(state="normal", bg=ACCENT,
                                   text="Повторить установку")
        self.var_status.set("Ошибка: " + message)
        self._log("[X] " + message)
        messagebox.showerror(
            "Anime4K Center",
            "Установка не завершена.\n\n{0}\n\nПроверьте подключение к интернету "
            "и повторите попытку.".format(message))

    def _launch(self):
        target = self.installed_dir
        if not target or not os.path.isdir(target):
            return
        starter = os.path.join(target, "Anime4K_Center.vbs")
        if not os.path.isfile(starter):
            starter = os.path.join(target, "Start_Windows.bat")
        try:
            os.startfile(starter)  # noqa: S606 - Windows shell launch
        except Exception as exc:  # noqa: BLE001
            messagebox.showerror("Anime4K Center",
                                 "Не удалось запустить: {0}".format(exc))
            return
        self.after(600, self.destroy)


def main():
    app = Installer()
    app.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
