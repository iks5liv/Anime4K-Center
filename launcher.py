#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Anime4K Center — кроссплатформенный графический лаунчер.

Полностью повторяет дизайн и логику launcher.ps1 (Windows), но работает
на Windows, Linux и macOS на стандартной библиотеке Python + tkinter.

Запуск:
    python launcher.py
    python3 launcher.py --config-dir=./portable_config

Зависимости: только Python 3.8+ и tkinter (python3-tk в Linux).
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import tkinter as tk
import tkinter.font as tkfont
from tkinter import filedialog, messagebox

# --------------------------------------------------------------------------
#  Платформа и константы
# --------------------------------------------------------------------------
APP_NAME = "Anime4K Center"
IS_WINDOWS = sys.platform.startswith("win")
IS_MAC = sys.platform == "darwin"
IS_LINUX = sys.platform.startswith("linux")
# macOS: Homebrew ставит бинарники в /opt/homebrew/bin (Apple Silicon M1–M4)
# или /usr/local/bin (Intel). Finder и .command запускают скрипт с урезанным
# PATH, поэтому добавляем оба каталога явно — mpv и yt-dlp находятся всегда.
if IS_MAC:
    for _brew_bin in ("/opt/homebrew/bin", "/usr/local/bin"):
        _path_parts = os.environ.get("PATH", "").split(os.pathsep)
        if _brew_bin not in _path_parts:
            os.environ["PATH"] = (_brew_bin + os.pathsep
                                  + os.environ.get("PATH", ""))
CREATE_NO_WINDOW = 0x08000000 if IS_WINDOWS else 0

COL = {
    "bg": "#18181b",
    "card": "#27272a",
    "field": "#3f3f46",
    "field_hi": "#52525b",
    "accent": "#6366f1",
    "accent_hi": "#4f46e5",
    "text": "#ffffff",
    "muted": "#a1a1aa",
    "subtle": "#71717a",
    "green": "#4ade80",
}

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
HTTP_HEADERS = {
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
    "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
    "Accept-Encoding": "identity",
}

MODES: List[Dict[str, Any]] = [
    {
        "title": "Аниме: Стандарт 4K (Mode A HQ)",
        "desc": "Для большинства современных аниме. Делает контуры четкими.",
        "files": [
            "Anime4K_Clamp_Highlights.glsl", "Anime4K_Restore_CNN_VL.glsl",
            "Anime4K_Upscale_CNN_x2_VL.glsl", "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl", "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        "files_lite": [
            "Anime4K_Clamp_Highlights.glsl", "Anime4K_Restore_CNN_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl", "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl", "Anime4K_Upscale_CNN_x2_S.glsl",
        ],
    },
    {
        "title": "Аниме: Против мыла 4K (Mode B HQ)",
        "desc": "Для серий в плохом качестве и низком битрейте.",
        "files": [
            "Anime4K_Clamp_Highlights.glsl", "Anime4K_Restore_CNN_Soft_VL.glsl",
            "Anime4K_Upscale_CNN_x2_VL.glsl", "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl", "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        "files_lite": [
            "Anime4K_Clamp_Highlights.glsl", "Anime4K_Restore_CNN_Soft_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl", "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl", "Anime4K_Upscale_CNN_x2_S.glsl",
        ],
    },
    {
        "title": "Аниме: Старое / Шумное 4K (Mode C HQ)",
        "desc": "Для аниме 90-х и 2000-х. Убирает зерно и сжатие.",
        "files": [
            "Anime4K_Clamp_Highlights.glsl", "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl", "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        "files_lite": [
            "Anime4K_Clamp_Highlights.glsl", "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl", "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_S.glsl",
        ],
    },
    {
        "title": "Кино и сериалы 4K (FSRCNNX)",
        "desc": "Для фильмов с живыми актерами. Без мультяшного эффекта.",
        "files": ["FSRCNNX_x2_16-0-4-1.glsl"],
    },
    {
        "title": "Старое кино / Сериалы 4K (Реставрация)",
        "desc": "Для старых фильмов и сериалов. Убирает зерно, шум и мыло",
        "files": [
            "Anime4K_Clamp_Highlights.glsl", "Anime4K_Denoise_Bilateral_Mean.glsl",
            "FSRCNNX_x2_16-0-4-1.glsl",
        ],
        "vf": "lavfi=[hqdn3d=luma_spatial=2.0:chroma_spatial=1.5:luma_tmp=3.0:chroma_tmp=2.5]",
    },
    {
        "title": "Оригинал (Без улучшений)",
        "desc": "Чистое видео без нейросетей и шейдеров.",
        "files": [],
    },
]

DIRECT_HOSTS = {
    "youtube.com", "youtu.be", "vk.com", "vk.ru", "vkvideo.ru", "rutube.ru",
    "kick.com", "twitch.tv", "sibnet.ru",
}
ANIME_HOSTS = (
    "jut.su", "yummyani", "animego", "anilibria", "aniliberty", "animedia",
    "anime365", "smotret-anime", "animelib", "animevost",
)

RX_HTTP = re.compile(r"^https?://", re.I)
RX_DIRECT_EXT = re.compile(r"\.(m3u8|mp4|mkv|webm)(\?|#|$)", re.I)
RX_SXXEXX = re.compile(r"^S\d+E\d+", re.I)
RX_EP_NUMBER = re.compile(
    r"(?:серия|серии|серию|эпизод|episode|ep\.?|e)\s*[№#]?\s*(\d{1,4})", re.I)
RX_EP_PLAIN = re.compile(r"^(?:серия|эпизод)\s*[№#]?\s*\d+\s*$", re.I)
RX_SXXEXX_END = re.compile(r"^S\d+E\d+$", re.I)
RX_EP_PATTERNS = [
    re.compile(r"(?:серия|серии|серию|эпизод|episode|ep\.?|e)\s*[№#]?\s*(\d{1,4})", re.I),
    re.compile(r"(\d{1,4})\s*(?:серия|серии|эпизод)", re.I),
    re.compile(r"\bS\d{1,2}E(\d{1,4})\b", re.I),
]
RX_JUNK = re.compile(
    r"трейлер|trailer|тизер|teaser|обзор|review|реакция|reaction|фрагмент|клип|"
    r"музык|саундтрек|soundtrack|\bost\b|ambient|оркестр|концерт|кавер|cover|"
    r"разбор|реценз|сцен[аы]|момент|theory|analysis|explained|shorts|asmr|стрим|"
    r"stream|летсплей|let'?s\s*play|прохожд|геймплей|gameplay|walkthrough|"
    r"майнкрафт|minecraft|roblox|\bgta\b|скайрим|skyrim|nioh|once\s+human|"
    r"fortnite|dota|valorant|подкаст|podcast|аудиокниг|аудиоспектакл|"
    r"радиоспектакл|исцелен|звуком|медитац|аффирмац|нарезк|подборк|топ\s*\d",
    re.I,
)
RX_JUNK_AUTHOR = re.compile(
    r"asmr|гар\s*яев|гаряев|wavegenetics|softradio|релакс|relax|медитац|"
    r"аффирмац|исцелен|частот|биоакустик|психея|аудиокниг|аудиоспектакл|"
    r"радиоспектакл|\bстрим|stream|летсплей|прохожд|подкаст|podcast",
    re.I,
)
RX_ANTIBOT_MARKERS = (
    "cf-chl", "cf_chl_opt", "challenge-platform", "just a moment",
    "checking your browser", "ddos-guard", "access denied", "доступ ограничен",
    "проверка браузера", "подтвердите, что вы не робот", "verify you are human",
    "enable javascript and cookies to continue", "sso.kinopoisk.ru/install",
    "passport.yandex.ru", "showcaptcha",
)
RX_DRM_MARKERS = (
    "widevine", "playready", "clearkey", "drmtoday", "encryptedmedia",
    "digital rights management",
)

STOP_WORDS = {
    "смотреть", "онлайн", "сериал", "сериала", "фильм", "фильма", "аниме",
    "мультфильм", "сезон", "серия", "серии", "эпизод", "все", "всех", "новый",
    "новая", "the", "and", "movie", "series", "full",
}


# --------------------------------------------------------------------------
#  Мелкие утилиты
# --------------------------------------------------------------------------
def is_direct_url(text: str) -> bool:
    """Обычная видеоссылка: хостинг или прямой поток — без парсера сезонов."""
    if not RX_HTTP.match(text):
        return False
    if RX_DIRECT_EXT.search(text):
        return True
    try:
        host = (urllib.parse.urlparse(text).hostname or "").lower()
    except ValueError:
        return False
    if not host:
        return False
    if host in DIRECT_HOSTS:
        return True
    return any(host.endswith("." + d) for d in DIRECT_HOSTS)


def format_duration_text(sec: int) -> str:
    if not sec or sec <= 0:
        return ""
    minutes = int(round(sec / 60.0))
    if minutes < 60:
        return f"{minutes} мин"
    hours, mins = divmod(minutes, 60)
    return f"{hours} ч" if mins == 0 else f"{hours} ч {mins} мин"


def norm_url(url: str) -> str:
    url = (url or "").strip().replace("\\/", "/")
    if url.startswith("//"):
        url = "https:" + url
    return url


def clean_title(text: str) -> str:
    if not text:
        return ""
    import html as _html
    text = _html.unescape(text)
    text = re.sub(r"\\[nrt]", " ", text)
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"\s*[—–-]\s*(?:Кинопоиск|Kinopoisk).*$", "", text, flags=re.I)
    text = re.sub(r"\s*[|•·]\s*(?:Кинопоиск|Kinopoisk).*$", "", text, flags=re.I)
    text = re.sub(r"^\s*(?:смотреть\s+)?(?:онлайн|бесплатно)\s+", "", text, flags=re.I)
    text = re.sub(r"\s+(?:смотреть\s+)?онлайн\s*$", "", text, flags=re.I)
    text = re.sub(r"\s+(?:бесплатно|в\s+хорошем\s+качестве)\s*$", "", text, flags=re.I)
    text = re.sub(r"\s*\(\s*(?:фильм|сериал|мультфильм|аниме|тв)\s*\)\s*$", "", text, flags=re.I)
    return text.strip(" -—–|:")


_TITLE_KEY_CACHE: Dict[str, str] = {}
_TITLE_TOK_CACHE: Dict[str, List[str]] = {}


def title_key(text: str) -> str:
    if not text:
        return ""
    if text in _TITLE_KEY_CACHE:
        return _TITLE_KEY_CACHE[text]
    value = text.lower().replace("_", " ")
    value = re.sub(r"[^\w]+", " ", value, flags=re.U)
    value = re.sub(r"\s+", " ", value).strip()
    if len(_TITLE_KEY_CACHE) > 4000:
        _TITLE_KEY_CACHE.clear()
    _TITLE_KEY_CACHE[text] = value
    return value


def title_tokens(text: str) -> List[str]:
    if not text:
        return []
    if text in _TITLE_TOK_CACHE:
        return _TITLE_TOK_CACHE[text]
    tokens = [t for t in title_key(text).split(" ") if len(t) >= 3 and t not in STOP_WORDS]
    if len(_TITLE_TOK_CACHE) > 4000:
        _TITLE_TOK_CACHE.clear()
    _TITLE_TOK_CACHE[text] = tokens
    return tokens


def title_score(a: str, b: str) -> int:
    ka, kb = title_key(a), title_key(b)
    if not ka or not kb:
        return 0
    if ka == kb:
        return 100
    if kb in ka or ka in kb:
        return 72
    ta, tb = title_tokens(a), title_tokens(b)
    if not ta or not tb:
        return 0
    hits = sum(1 for t in tb if t in ta)
    return int(60 * hits / max(1, len(tb)))


def ep_number(text: str) -> int:
    if not text:
        return 0
    for pattern in RX_EP_PATTERNS:
        match = pattern.search(text)
        if match:
            try:
                value = int(match.group(1))
            except (ValueError, IndexError):
                value = 0
            if value > 0:
                return value
    return 0


def episode_label(ep: Dict[str, Any], number: int, season_no: int = 0) -> str:
    text = re.sub(r"[\r\n]+", " ", str(ep.get("title") or ""))
    text = re.sub(r"\s+", " ", text).strip()
    if RX_SXXEXX.match(text):
        return text
    num = ep_number(text)
    if season_no > 0:
        label = f"S{season_no:02d}E{number:02d}"
        text = re.sub(
            r"^(?:серия|эпизод)\s*[№#]?\s*\d+\s*[·:\-–—]?\s*", "", text, flags=re.I)
    elif num > 0:
        label = f"Серия {num}"
    else:
        label = f"Серия {number}"
    if text and not RX_EP_PLAIN.match(text) and not RX_SXXEXX_END.match(text):
        label = f"{label} · {text}"
    return label


def format_episodes(eps: List[Dict[str, Any]], season_no: int = 0) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for index, ep in enumerate(eps, 1):
        if not ep:
            continue
        text = re.sub(r"[\r\n]+", " ", str(ep.get("title") or ""))
        text = re.sub(r"\s+", " ", text).strip()
        num = ep_number(text)
        if season_no > 0:
            label = f"S{season_no:02d}E{index:02d}"
            text = re.sub(
                r"^(?:серия|эпизод)\s*[№#]?\s*\d+\s*[·:\-–—]?\s*", "", text, flags=re.I)
        elif num > 0:
            label = f"Серия {num}"
        else:
            label = f"Серия {index}"
        if text and not RX_EP_PLAIN.match(text) and not RX_SXXEXX.match(text):
            label = f"{label} · {text}"
        item: Dict[str, Any] = {"title": label, "url": ep.get("url", "")}
        if ep.get("qualities"):
            item["qualities"] = ep["qualities"]
        if ep.get("duration"):
            item["duration"] = int(ep["duration"])
        out.append(item)
    return out


def _decode(data: bytes, content_type: str = "") -> str:
    charset = "utf-8"
    match = re.search(r"charset=([\w\-]+)", content_type or "", re.I)
    if match:
        charset = match.group(1)
    try:
        return data.decode(charset, "replace")
    except LookupError:
        return data.decode("utf-8", "replace")


def http_get(url: str, referer: str = "", timeout: int = 25,
             accept: str = "") -> Tuple[str, int]:
    headers = dict(HTTP_HEADERS)
    if referer:
        headers["Referer"] = referer
    if accept:
        headers["Accept"] = accept
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            code = getattr(response, "status", 200)
            text = _decode(response.read(), response.headers.get("Content-Type", ""))
            return text, code
    except urllib.error.HTTPError as exc:
        try:
            text = _decode(exc.read(), exc.headers.get("Content-Type", ""))
        except Exception:
            text = ""
        return text, exc.code
    except Exception:
        return "", 0


def http_json(url: str, referer: str = "", timeout: int = 25) -> Any:
    text, code = http_get(url, referer, timeout, "application/json")
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        return None


def is_antibot(text: str, code: int) -> bool:
    if code in (401, 403, 429, 503):
        return True
    low = (text or "").lower()
    return any(marker in low for marker in RX_ANTIBOT_MARKERS)


def is_drm(text: str) -> bool:
    low = (text or "").lower()
    return any(marker in low for marker in RX_DRM_MARKERS)


def page_title(html: str) -> str:
    import html as _html
    if not html:
        return ""
    match = re.search(r"<title[^>]*>(.*?)</title>", html, re.I | re.S)
    if match:
        return clean_title(re.sub(r"\s+", " ", _html.unescape(match.group(1))))
    match = re.search(
        r"property\s*=\s*['\"]og:title['\"]\s+content\s*=\s*['\"]([^'\"]+)", html, re.I)
    if match:
        return clean_title(_html.unescape(match.group(1)))
    return ""


def find_json_in_stdout(text: str) -> Optional[Any]:
    if not text:
        return None
    stripped = text.strip()
    if not stripped:
        return None
    try:
        return json.loads(stripped)
    except Exception:
        pass
    start, end = stripped.find("{"), stripped.rfind("}")
    if start >= 0 and end > start:
        try:
            return json.loads(stripped[start:end + 1])
        except Exception:
            return None
    return None


# --------------------------------------------------------------------------
#  Binaries / GPU
# --------------------------------------------------------------------------
def exe_name(name: str) -> List[str]:
    if IS_WINDOWS:
        return [name + ".exe", name] if not name.lower().endswith(".exe") else [name, name[:-4]]
    return [name]


def find_tool(name: str, root: Path, extra_dirs: Optional[List[Path]] = None) -> Optional[str]:
    """Windows: локальные .exe рядом с проектом, затем PATH.
    Linux/macOS: исполняемый локальный бинарник в корне, затем PATH."""
    dirs: List[Path] = [root]
    if extra_dirs:
        dirs.extend(extra_dirs)
    for directory in dirs:
        for candidate_name in exe_name(name):
            candidate = directory / candidate_name
            try:
                if candidate.is_file() and (IS_WINDOWS or os.access(candidate, os.X_OK)):
                    return str(candidate)
            except OSError:
                continue
    found = shutil.which(name)
    if found:
        return found
    if IS_WINDOWS:
        found = shutil.which(name + ".exe")
    return found


def _gpu_is_high(name: str, vram_bytes: int) -> bool:
    if not name:
        return False
    n = name.lower()
    if re.search(r"microsoft basic|remote display|virtual|vmware|virtualbox|parsec|citrix|sunshine|meta virtual", n):
        return False
    if re.search(r"nvidia|geforce|quadro|tesla|titan", n):
        return bool(re.search(r"rtx|gtx|quadro|tesla|titan", n))
    if re.search(r"amd|radeon|firepro", n):
        if re.search(r"radeon\s*rx|rx\s*\d|firepro|radeon\s*pro|radeon\s*vii|radeon\s*r9|radeon\s*r7", n):
            if vram_bytes >= 3500 * 1024 * 1024:
                return True
            if re.search(r"rx\s*[567]\d{3}", n):
                return True
        return False
    if "intel" in n:
        if "arc" in n and (re.search(r"[ab]\d{3}", n) or "arc" in n and "pro" in n):
            return True
        return False
    if "apple" in n:
        # Apple Silicon (M1/M2/M3/M4...) — единая память + быстрый Metal.
        return bool(re.search(r"apple\s*m\d", n))
    return False


def _parse_size_to_bytes(value: str, unit: str) -> int:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0
    unit = (unit or "").lower()
    if unit.startswith("g"):
        return int(number * 1024 ** 3)
    if unit.startswith("m"):
        return int(number * 1024 ** 2)
    if unit.startswith("k"):
        return int(number * 1024)
    return int(number)


def detect_gpu() -> Tuple[str, str]:
    """Возвращает (tier, name). Windows — WMI, Linux — lspci/glxinfo,
    macOS — system_profiler. Без внешних библиотек."""
    names: List[str] = []
    high = False
    entries: List[Any] = []

    def add(name: str, vram: int = 0) -> None:
        nonlocal high
        name = re.sub(r"\s+", " ", name or "").strip()
        if not name:
            return
        names.append(name)
        try:
            if _gpu_is_high(name, int(vram or 0)):
                high = True
        except Exception:
            pass

    if IS_WINDOWS:
        command = (
            "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; "
            "(Get-CimInstance Win32_VideoController | ForEach-Object { "
            "$_.Name + '|' + [string]([int64]$_.AdapterRAM) }) -join [char]10"
        )
        try:
            result = subprocess.run(
                ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive",
                 "-ExecutionPolicy", "Bypass", "-Command", command],
                capture_output=True, text=True, timeout=25,
                creationflags=CREATE_NO_WINDOW, encoding="utf-8", errors="replace")
            for line in (result.stdout or "").splitlines():
                if not line.strip():
                    continue
                name, _, ram = line.partition("|")
                try:
                    vram = int(ram.strip() or 0)
                except ValueError:
                    vram = 0
                if vram < 0:
                    vram = 0
                add(name, vram)
        except Exception:
            pass
    elif IS_MAC:
        try:
            result = subprocess.run(
                ["system_profiler", "SPDisplaysDataType"],
                capture_output=True, text=True, timeout=25,
                encoding="utf-8", errors="replace")
            current = None
            for line in (result.stdout or "").splitlines():
                chip = re.search(r"Chipset Model:\s*(.+)$", line)
                if chip:
                    current = [chip.group(1).strip(), 0]
                    entries.append(current)
                vram = re.search(r"VRAM\s*\([^)]*\):\s*([\d.]+)\s*(\w+)", line)
                if vram:
                    size = _parse_size_to_bytes(vram.group(1), vram.group(2))
                    if current:
                        current[1] = size
            for name, vram in entries:
                add(name, vram)
        except Exception:
            pass
    else:
        try:
            result = subprocess.run(
                ["sh", "-c",
                 '(command -v lspci >/dev/null 2>&1 && lspci -nn 2>/dev/null | '
                 'grep -Ei "VGA|3D|Display"); echo "---"; '
                 '(command -v glxinfo >/dev/null 2>&1 && glxinfo -B 2>/dev/null | '
                 'grep -Ei "OpenGL renderer|Device|Video memory")'],
                capture_output=True, text=True, timeout=25,
                encoding="utf-8", errors="replace")
            current = None
            for line in (result.stdout or "").splitlines():
                if "VGA compatible controller" in line or "3D controller" in line \
                        or "Display controller" in line:
                    name = line.split(":", 1)[-1].strip()
                    name = re.sub(r"\s*\(rev[^)]*\).*$", "", name)
                    current = [name, 0]
                    entries.append(current)
                else:
                    match = re.search(r"(?:OpenGL renderer string|Device):\s*(.+)$", line)
                    if match:
                        current = [match.group(1).strip(), 0]
                        entries.append(current)
                    vram = re.search(r"Video memory:\s*(\d+)\s*MB", line)
                    if vram and current:
                        current[1] = int(vram.group(1)) * 1024 ** 2
            for name, vram in entries:
                add(name, vram)
        except Exception:
            pass

    tier = "hq" if high else "lite"
    name = " + ".join(dict.fromkeys(names)) if names else "не определена"
    return tier, name


# --------------------------------------------------------------------------
#  Онлайн-поиск: AniLiberty / RuTube / yt-dlp / HTML
# --------------------------------------------------------------------------
def aniliberty_search(query: str) -> List[Dict[str, Any]]:
    if not query:
        return []
    url = ("https://aniliberty.top/api/v1/app/search/releases?query="
           + urllib.parse.quote(query))
    data = http_json(url, "https://aniliberty.top/")
    if isinstance(data, dict):
        for key in ("data", "content", "results"):
            if isinstance(data.get(key), list):
                data = data[key]
                break
    return data if isinstance(data, list) else []


def aniliberty_release(id_or_alias: Any) -> Optional[Dict[str, Any]]:
    if not id_or_alias:
        return None
    url = ("https://aniliberty.top/api/v1/anime/releases/"
           + urllib.parse.quote(str(id_or_alias)))
    data = http_json(url, "https://aniliberty.top/")
    return data if isinstance(data, dict) else None


def aniliberty_franchise(release_id: int) -> List[Dict[str, Any]]:
    if not release_id or release_id <= 0:
        return []
    url = f"https://aniliberty.top/api/v1/anime/franchises/release/{release_id}"
    data = http_json(url, "https://aniliberty.top/")
    return data if isinstance(data, list) else []


def convert_aniliberty(release: Dict[str, Any], short_name: str,
                       season_no: int = 0) -> Optional[Dict[str, Any]]:
    if not release or not release.get("episodes"):
        return None
    indexed = []
    for index, ep in enumerate(release.get("episodes") or [], 1):
        if not ep:
            continue
        try:
            ordinal = int(ep.get("ordinal") or 0)
        except (TypeError, ValueError):
            ordinal = 0
        indexed.append((ordinal if ordinal > 0 else index, index, ep))
    indexed.sort(key=lambda item: (item[0], item[1]))

    eps: List[Dict[str, Any]] = []
    seen = set()
    for number, _index, ep in indexed:
        qualities: Dict[str, str] = {}
        for quality in ("1080", "720", "480"):
            value = ep.get("hls_" + quality)
            if value:
                qualities[quality] = norm_url(str(value))
        link = ""
        for quality in ("1080", "720", "480"):
            if quality in qualities:
                link = qualities[quality]
                break
        if not link:
            link = norm_url(str(ep.get("hls") or ""))
        if not link:
            continue
        if link in seen:
            continue
        seen.add(link)
        title = str(ep.get("name") or "")
        title = f"Серия {number} · {title}" if title else f"Серия {number}"
        item: Dict[str, Any] = {"title": title, "url": link}
        if qualities:
            item["qualities"] = qualities
        eps.append(item)
    if not eps:
        return None

    main = ""
    name_obj = release.get("name")
    if isinstance(name_obj, dict):
        main = str(name_obj.get("main") or "")
    if not main:
        main = "AniLiberty"
    year = str(release.get("year") or "")
    label = main + (f" ({year})" if year else "")
    if short_name:
        label = f"{short_name} · {label}"

    return {
        "name": label,
        "base": main + (f" ({year})" if year else ""),
        "short": short_name or "Сезон 1",
        "year": year,
        "source": "AniLiberty",
        "release": int(release.get("id") or 0),
        "voices": [{
            "name": "AniLiberty · HLS",
            "episodes": format_episodes(eps, season_no),
            "source": "AniLiberty",
        }],
    }


def find_aniliberty_seasons(query: str) -> List[Dict[str, Any]]:
    releases = aniliberty_search(query)
    if not releases and " " in query:
        short_query = query.split()[0]
        if len(short_query) >= 3:
            releases = aniliberty_search(short_query)
    best = None
    best_score = 0
    for release in releases:
        if not isinstance(release, dict) or not release.get("id"):
            continue
        names: List[str] = []
        name_obj = release.get("name")
        if isinstance(name_obj, dict):
            for key in ("main", "english"):
                if name_obj.get(key):
                    names.append(str(name_obj[key]))
        alias = str(release.get("alias") or "")
        if alias:
            names.append(alias.replace("-", " "))
        score = max([title_score(n, query) for n in names] or [0])
        try:
            if release.get("year"):
                score += 2
        except Exception:
            pass
        if score > best_score:
            best_score, best = score, release
    if not best or best_score < 40:
        return []
    detail = aniliberty_release(best.get("alias")) or aniliberty_release(best.get("id"))
    if not detail:
        return []

    items: List[Dict[str, Any]] = []
    seen_ids = set()
    for franchise in aniliberty_franchise(int(detail.get("id") or 0)):
        releases = ((franchise.get("franchise_releases") or [])
                    if isinstance(franchise, dict) else [])
        for item in releases:
            if not item or not item.get("release_id"):
                continue
            rid = int(item["release_id"])
            if rid in seen_ids:
                continue
            seen_ids.add(rid)
            rel = item.get("release") or {}
            items.append({
                "id": rid,
                "year": int(rel.get("year") or 0),
                "sort": int(item.get("sort_order") or 0),
            })
    if not items:
        items.append({
            "id": int(detail.get("id") or 0),
            "year": int(detail.get("year") or 0),
            "sort": 0,
        })
    items.sort(key=lambda x: (x["sort"], x["year"]))

    seasons: List[Dict[str, Any]] = []
    tv = movies = 0
    for item in items:
        if len(seasons) >= 12:
            break
        release = detail if item["id"] == int(detail.get("id") or 0) \
            else aniliberty_release(item["id"])
        if not release:
            continue
        type_value = ""
        type_obj = release.get("type")
        if isinstance(type_obj, dict):
            type_value = str(type_obj.get("value") or "")
        if re.search(r"movie|film", type_value, re.I):
            movies += 1
            short, number = f"Фильм {movies}", 0
        else:
            tv += 1
            short, number = f"Сезон {tv}", tv
        season = convert_aniliberty(release, short, number)
        if season:
            seasons.append(season)
    return seasons


def rutube_search(query: str) -> Tuple[List[Dict[str, Any]], int]:
    """Возвращает (варианты, максимальная релевантность)."""
    if not query:
        return [], 0
    url = ("https://rutube.ru/api/search/video/?query="
           + urllib.parse.quote(query) + "&limit=30")
    data = http_json(url, "https://rutube.ru/")
    results = data.get("results") if isinstance(data, dict) else None
    if not results:
        return [], 0

    query_tokens = title_tokens(query)
    groups: Dict[str, List[Dict[str, Any]]] = {}
    authors: Dict[str, Dict[str, Any]] = {}
    top_rel = 0

    for item in results:
        if not item or not item.get("id"):
            continue
        if item.get("is_deleted") or item.get("is_locked") or item.get("is_adult"):
            continue
        title = str(item.get("title") or "")
        try:
            duration = int(item.get("duration") or 0)
        except (TypeError, ValueError):
            duration = 0
        if duration < 1200:
            continue
        author_obj = item.get("author")
        author = str(author_obj.get("name") or "") if isinstance(author_obj, dict) else ""
        if not author:
            author = "RuTube"
        if RX_JUNK.search(title) or RX_JUNK_AUTHOR.search(author):
            continue
        rel = title_score(title, query)
        if rel < 15:
            continue
        episodic = bool(re.search(
            r"(?:серия|серии|серию|эпизод|episode)\s*[№#]?\s*\d|\bS\d{1,2}E\d{1,4}\b|\b\d{1,2}\s*сезон\b",
            title, re.I))
        has_year = bool(re.search(r"(?:19|20)\d{2}", title))
        has_marker = bool(re.search(
            r"\bфильм|сериал|полный|полная версия|HD|4K|1080|смотреть|онлайн|премьера",
            title, re.I))
        exactish = title_key(title) == title_key(query)
        if not (episodic or has_year or has_marker or exactish):
            continue
        if rel < 40 and not exactish:
            continue
        top_rel = max(top_rel, rel)

        bonus = 0
        if has_year:
            bonus += 1200
        if has_marker:
            bonus += 400
        extra = len(title_tokens(title)) - len(query_tokens)
        if extra <= 0:
            bonus += 2000
        elif extra == 1:
            bonus += 1200
        elif extra == 2:
            bonus += 400
        elif extra >= 6:
            bonus -= 800

        akey = author.lower()
        key = (akey + "|series") if episodic else (akey + "|" + title_key(title))
        if key not in groups:
            groups[key] = []
            authors[key] = {"author": author, "episodic": episodic}
        groups[key].append({
            "title": title,
            "url": "https://rutube.ru/video/" + str(item["id"]) + "/",
            "duration": duration,
            "ep": ep_number(title),
            "rel": rel,
            "bonus": bonus,
        })

    candidates = []
    for key, items in groups.items():
        seen = set()
        eps: List[Dict[str, Any]] = []
        total = best_rel = best_bonus = 0
        for entry in sorted(items, key=lambda x: (
                x["ep"] if x["ep"] > 0 else 9999, -x["duration"])):
            if entry["url"] in seen:
                continue
            seen.add(entry["url"])
            total += int(entry["duration"])
            best_rel = max(best_rel, int(entry["rel"]))
            best_bonus = max(best_bonus, int(entry["bonus"]))
            eps.append({
                "title": entry["title"],
                "url": entry["url"],
                "duration": int(entry["duration"]),
            })
        if not eps:
            continue
        score = (best_rel * 1_000_000 + best_bonus * 100
                 + len(eps) * 1000 + min(total, 200_000))
        candidates.append({
            "score": score,
            "voice": {
                "name": authors[key]["author"] + " · RuTube",
                "episodes": eps,
                "source": "RuTube",
                "duration": total,
            },
        })
    candidates.sort(key=lambda x: x["score"], reverse=True)
    return [c["voice"] for c in candidates[:8]], top_rel


def rutube_seasons(query: str) -> Tuple[List[Dict[str, Any]], int]:
    voices: List[Dict[str, Any]] = []
    top_rel = 0
    for sub_query in (query, query + " фильм", query + " сериал"):
        found, rel = rutube_search(sub_query)
        top_rel = max(top_rel, rel)
        for voice in found:
            if not any(v.get("name") == voice.get("name") for v in voices):
                voices.append(voice)
        if len(voices) >= 8:
            break
    if not voices:
        return [], top_rel
    return [{
        "name": query,
        "base": query,
        "short": "",
        "year": "",
        "source": "RuTube",
        "release": 0,
        "voices": voices[:8],
    }], top_rel


def run_ytdlp_json(target: str, ytdlp: Optional[str], timeout: int = 90) -> Optional[Any]:
    if not ytdlp:
        return None
    args = [
        ytdlp, "--flat-playlist", "-J", "--no-warnings", "--ignore-config",
        "--socket-timeout", "20", "--retries", "1", "--user-agent", UA,
        "--add-header", "Accept-Language: ru-RU,ru;q=0.9,en;q=0.8",
    ]
    cookie_file = None
    try:
        cookie_file = Path(tempfile_path("cookies.txt"))
        if cookie_file.is_file():
            args += ["--cookies", str(cookie_file)]
    except Exception:
        cookie_file = None
    args.append(target)
    try:
        result = subprocess.run(
            args, capture_output=True, text=True, timeout=timeout,
            creationflags=CREATE_NO_WINDOW, encoding="utf-8", errors="replace")
        data = find_json_in_stdout(result.stdout or "")
        return data
    except (subprocess.TimeoutExpired, OSError):
        return None


def tempfile_path(name: str) -> str:
    # cookies.txt лежит в корне проекта (как в Windows-версии).
    root = RUNTIME.get("root")
    return str(Path(root) / name) if root else name


def convert_ytdlp(yt: Any, fallback_url: str = "") -> Optional[Dict[str, Any]]:
    if not isinstance(yt, dict):
        return None
    eps: List[Dict[str, Any]] = []
    seen = set()
    title = clean_title(str(yt.get("title") or ""))
    entries = yt.get("entries")
    if isinstance(entries, list):
        for index, entry in enumerate(entries, 1):
            if not isinstance(entry, dict):
                continue
            url = str(entry.get("webpage_url") or entry.get("url") or "")
            if url and not re.match(r"^[a-zA-Z][a-zA-Z0-9+.\-]*://", url):
                entry_id = str(entry.get("id") or "")
                ie_key = str(entry.get("ie_key") or yt.get("extractor_key") or "")
                if entry_id and "youtube" in ie_key.lower():
                    url = "https://www.youtube.com/watch?v=" + entry_id
                elif entry_id and "rutube" in ie_key.lower():
                    url = "https://rutube.ru/video/" + entry_id + "/"
                else:
                    url = ""
            url = norm_url(url)
            if not url or url in seen:
                continue
            seen.add(url)
            ep_title = str(entry.get("title") or f"Серия {index}")
            eps.append({"title": ep_title, "url": url})
    else:
        url = norm_url(str(yt.get("webpage_url") or fallback_url or ""))
        if url:
            eps.append({"title": title or "Онлайн-видео", "url": url})
    if not eps:
        return None
    if not title:
        title = "Онлайн-видео"
    return {"title": title, "voices": [{"name": "Оригинал", "episodes": eps}]}


def yt_search_seasons(query: str, ytdlp: Optional[str]) -> List[Dict[str, Any]]:
    if not ytdlp:
        return []
    eps: List[Dict[str, Any]] = []
    seen = set()
    total_duration = 0
    for sub_query in (query + " фильм смотреть онлайн",
                      query + " сериал смотреть онлайн"):
        data = run_ytdlp_json("ytsearch15:" + sub_query, ytdlp, timeout=90)
        if not isinstance(data, dict):
            continue
        for entry in data.get("entries") or []:
            if not isinstance(entry, dict) or not entry.get("id"):
                continue
            title = str(entry.get("title") or "")
            channel = str(entry.get("channel") or entry.get("uploader") or "")
            if RX_JUNK.search(title) or (channel and RX_JUNK_AUTHOR.search(channel)):
                continue
            try:
                duration = int(entry.get("duration") or 0)
            except (TypeError, ValueError):
                duration = 0
            if duration and duration < 1200:
                continue
            if title_score(title, query) < 15:
                continue
            url = "https://www.youtube.com/watch?v=" + str(entry["id"])
            if url in seen:
                continue
            seen.add(url)
            item: Dict[str, Any] = {"title": title, "url": url}
            if duration:
                item["duration"] = duration
                total_duration += duration
            eps.append(item)
        if len(eps) >= 15:
            break
    if not eps:
        return []
    return [{
        "name": query,
        "base": query,
        "short": "",
        "year": "",
        "source": "YouTube",
        "release": 0,
        "voices": [{
            "name": "YouTube · открытый поиск",
            "episodes": format_episodes(eps, 0),
            "source": "YouTube",
            "duration": total_duration,
        }],
    }]


def _media_links(text: str, base_url: str) -> List[Dict[str, str]]:
    found: List[Dict[str, str]] = []
    seen = set()
    patterns = [
        r"(?:https?:)?//[^\s\"'<>\\]+?\.(?:m3u8|mp4)(?:\?[^\s\"'<>\\]*)?",
        r"(?:src|href|file)\s*=\s*\"([^\"]+?\.(?:m3u8|mp4)[^\"]*)\"",
        r"\"(?:src|file|url|link)\"\s*:\s*\"([^\"]+?\.(?:m3u8|mp4)[^\"]*)\"",
    ]
    for pattern in patterns:
        for match in re.finditer(pattern, text or "", re.I):
            raw = match.group(1) if match.groups() else match.group(0)
            url = norm_url(urllib.parse.urljoin(base_url, raw))
            if not RX_HTTP.match(url) or url in seen:
                continue
            seen.add(url)
            found.append({"title": "", "url": url})
    return found


def _iframes(text: str, base_url: str) -> List[str]:
    out: List[str] = []
    for match in re.finditer(
            r"<iframe[^>]+(?:data-)?src\s*=\s*[\"']([^\"']+)[\"']", text or "", re.I | re.S):
        url = norm_url(urllib.parse.urljoin(base_url, match.group(1)))
        if RX_HTTP.match(url) and url not in out:
            out.append(url)
    return out


def html_fallback(url: str) -> Optional[Dict[str, Any]]:
    html, code = http_get(url, url)
    if not html:
        return None
    if is_drm(html) or is_antibot(html, code):
        return None
    title = page_title(html) or "Онлайн-тайтл"
    voices: List[Dict[str, Any]] = []
    direct = _media_links(html, url)
    if direct:
        voices.append({"name": "Оригинал", "episodes": direct})
    for index, iframe in enumerate(_iframes(html, url)[:8], 1):
        sub_html, _sub_code = http_get(iframe, url)
        if not sub_html:
            continue
        links = _media_links(sub_html, iframe)
        if links:
            voices.append({"name": f"Озвучка {index}", "episodes": links})
    if not voices:
        return None
    return {
        "name": title,
        "base": title,
        "short": "",
        "year": "",
        "source": url,
        "release": 0,
        "voices": voices,
    }


RUNTIME: Dict[str, Any] = {}


def search_online(raw_query: str, ytdlp: Optional[str]) -> Dict[str, Any]:
    """Возвращает {title, seasons, kind} либо {error|protected, message}."""
    text = (raw_query or "").strip()
    is_url = bool(RX_HTTP.match(text))
    query = clean_title(text)

    if is_url:
        low = text.lower()
        if "kinopoisk" in low:
            match = re.search(r"/(film|series)/(\d+)", text)
            if not match:
                return {"protected": True,
                        "message": "Не удалось найти номер фильма в ссылке Кинопоиска. "
                                   "Скопируйте ссылку вида kinopoisk.ru/film/12345/."}
            html, code = http_get(text, text)
            title = page_title(html) if html else ""
            if not title:
                return {"protected": True,
                        "message": "Кинопоиск закрыл страницу (SSO/DRM). "
                                   "Откройте фильм в браузере или введите его название."}
            query = title

        if RX_DIRECT_EXT.search(text):
            return {
                "title": "Прямой поток",
                "kind": "direct",
                "seasons": [{
                    "name": "Прямой поток", "base": "Прямой поток", "short": "",
                    "year": "", "source": "direct", "release": 0,
                    "voices": [{"name": "Прямой поток",
                                "episodes": [{"title": "Прямой поток", "url": text}],
                                "source": "direct"}],
                }],
            }

        # Аниме-каталог: название со страницы ищем через официальное API.
        if any(host in low for host in ANIME_HOSTS):
            html, code = http_get(text, text)
            if html and not is_antibot(html, code) and not is_drm(html):
                title = page_title(html)
                if title:
                    seasons = find_aniliberty_seasons(title)
                    if seasons:
                        return {"title": seasons[0].get("base") or seasons[0]["name"],
                                "kind": "anime", "seasons": seasons}
                    query = title

        # Прямая ссылка через yt-dlp (YouTube, VK, RuTube, playlists).
        data = run_ytdlp_json(text, ytdlp)
        converted = convert_ytdlp(data, text)
        if converted:
            return {
                "title": converted["title"], "kind": "video",
                "seasons": [{
                    "name": converted["title"], "base": converted["title"],
                    "short": "", "year": "", "source": "yt-dlp", "release": 0,
                    "voices": converted["voices"],
                }],
            }

        html, code = http_get(text, text)
        if is_drm(html) or is_antibot(html, code):
            return {"protected": True,
                    "message": "Прямой поток защищён (Cloudflare/DRM). "
                               "Откройте видео в браузере и включите системный апскейл."}
        if html:
            title = page_title(html)
            if title:
                query = title
            fallback = html_fallback(text)
            if fallback:
                fallback["kind"] = "video"
                return {"title": fallback["name"], "kind": "video",
                        "seasons": [fallback]}

        if not query:
            return {"error": "Не удалось разобрать ссылку.",
                    "fallback_direct": text}

    if not query:
        return {"error": "Введите ссылку или название аниме, фильма, сериала."}

    # 1. Аниме: AniLiberty.
    seasons = find_aniliberty_seasons(query)
    if seasons:
        return {"title": seasons[0].get("base") or seasons[0]["name"],
                "kind": "anime", "seasons": seasons}

    # 2. Фильмы и сериалы: RuTube, при нехватке вариантов — YouTube.
    movie_seasons, top_rel = rutube_seasons(query)
    voices = movie_seasons[0]["voices"] if movie_seasons else []
    if len(voices) < 3 or top_rel < 60:
        yt_seasons = yt_search_seasons(query, ytdlp)
        if yt_seasons:
            yt_seasons[0]["voices"] = voices + yt_seasons[0]["voices"]
            movie_seasons = yt_seasons
    if movie_seasons:
        return {"title": movie_seasons[0].get("base") or movie_seasons[0]["name"],
                "kind": "movie", "seasons": movie_seasons}

    if is_url:
        return {"error": "Не удалось найти серии по этой ссылке.",
                "fallback_direct": text}
    return {"error": "Не удалось найти видео по названию. Проверьте написание "
                     "или откройте фильм в браузере."}


# --------------------------------------------------------------------------
#  Запись плейлистов, манифеста и метаданных
# --------------------------------------------------------------------------
def write_playlist(episodes: List[Dict[str, Any]], path: Path,
                   season_no: int = 0) -> None:
    lines = ["#EXTM3U"]
    for index, ep in enumerate(episodes, 1):
        lines.append("#EXTINF:-1," + episode_label(ep, index, season_no))
        lines.append(str(ep.get("url") or ""))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_season_files(root: Path, info: Dict[str, Any],
                       seasons: List[Dict[str, Any]], picked_season: int,
                       picked_voice: str,
                       config_dir: Optional[Path] = None) -> Optional[Path]:
    manifest_path = ((config_dir or (root / "portable_config"))
                     / "season_manifest.json")
    meta_path = root / "temp_playlist_meta.json"
    multi = len(seasons) >= 2
    manifest_seasons: List[Dict[str, Any]] = []
    meta_episodes: List[Dict[str, Any]] = []
    meta_seen = set()
    picked_path: Optional[Path] = None

    for index, season in enumerate(seasons):
        voices = [v for v in (season.get("voices") or []) if v]
        if not voices:
            continue
        voice = None
        if picked_voice:
            voice = next((v for v in voices if str(v.get("name")) == picked_voice), None)
        if not voice:
            voice = voices[0]
        eps = [e for e in (voice.get("episodes") or []) if e]
        if not eps:
            continue

        season_no = index + 1
        path = root / (f"temp_playlist_s{season_no}.m3u8" if multi
                       else "temp_playlist.m3u8")
        write_playlist(eps, path, season_no)
        if season_no == picked_season:
            picked_path = path

        for ep_no, ep in enumerate(eps, 1):
            url = str(ep.get("url") or "")
            if not url or url in meta_seen:
                continue
            qualities = ep.get("qualities")
            if not isinstance(qualities, dict) or not qualities:
                continue
            clean_q = {str(k): str(v) for k, v in qualities.items() if v}
            if not clean_q:
                continue
            meta_seen.add(url)
            item: Dict[str, Any] = {
                "title": episode_label(ep, ep_no, season_no),
                "url": url,
                "qualities": clean_q,
            }
            if ep.get("duration"):
                item["duration"] = int(ep["duration"])
            meta_episodes.append(item)

        manifest_seasons.append({
            "name": str(season.get("name") or ""),
            "short": str(season.get("short") or f"Сезон {season_no}"),
            "year": str(season.get("year") or ""),
            "source": str(season.get("source") or ""),
            "playlist": str(path),
            "count": len(eps),
            "first": str(eps[0].get("url") or ""),
        })

    if multi and len(manifest_seasons) >= 2:
        manifest = {
            "title": str(info.get("title") or ""),
            "kp_url": str(info.get("kp_url") or ""),
            "generated": _dt.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
            "active": int(picked_season),
            "seasons": manifest_seasons,
        }
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    else:
        try:
            manifest_path.unlink()
        except OSError:
            pass
        for old in root.glob("temp_playlist_s*.m3u8"):
            try:
                old.unlink()
            except OSError:
                pass

    if meta_episodes:
        meta = {
            "title": str(info.get("title") or ""),
            "generated": _dt.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
            "episodes": meta_episodes,
        }
        meta_path.write_text(
            json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    else:
        try:
            meta_path.unlink()
        except OSError:
            pass

    if not picked_path and manifest_seasons:
        picked_path = Path(manifest_seasons[0]["playlist"])
    return picked_path


# --------------------------------------------------------------------------
#  UI-компоненты
# --------------------------------------------------------------------------
def pick_font_family(root: tk.Misc) -> str:
    try:
        families = set(tkfont.families(root))
    except Exception:
        families = set()
    for family in ("Segoe UI", "Inter", "SF Pro Display", "Helvetica Neue",
                   "Ubuntu", "Noto Sans", "DejaVu Sans", "Arial"):
        if family in families:
            return family
    return "TkDefaultFont"


class FlatButton(tk.Frame):
    """Плоская кнопка в стиле лаунчера: заливка, тонкая рамка, hover."""

    def __init__(self, master: tk.Misc, text: str, command=None,
                 bg: str = COL["field"], hover: str = COL["field_hi"],
                 fg: str = COL["text"], font=None, border: str = COL["field_hi"],
                 height: int = 42, padx: int = 8, **kwargs):
        super().__init__(master, bg=border, padx=1, pady=1,
                         highlightthickness=0, **kwargs)
        self._bg, self._hover, self._fg = bg, hover, fg
        self._command = command
        self._enabled = True
        self.configure(height=height)
        self.pack_propagate(False)
        self.grid_propagate(False)
        self._inner = tk.Frame(self, bg=bg, cursor="hand2")
        self._inner.pack(fill="both", expand=True)
        self._label = tk.Label(self._inner, text=text, bg=bg, fg=fg,
                               font=font, cursor="hand2", anchor="center")
        self._label.pack(fill="both", expand=True, padx=padx)
        for widget in (self, self._inner, self._label):
            widget.bind("<Enter>", self._on_enter)
            widget.bind("<Leave>", self._on_leave)
            widget.bind("<Button-1>", self._on_click)

    def _paint(self, color: str) -> None:
        self._inner.configure(bg=color)
        self._label.configure(bg=color)

    def _on_enter(self, _event=None) -> None:
        if self._enabled:
            self._paint(self._hover)

    def _on_leave(self, _event=None) -> None:
        if self._enabled:
            self._paint(self._bg)

    def _on_click(self, _event=None) -> None:
        if self._enabled and self._command:
            self._command()

    def set_text(self, text: str) -> None:
        self._label.configure(text=text)

    def set_enabled(self, enabled: bool) -> None:
        self._enabled = bool(enabled)
        self._label.configure(fg=self._fg if enabled else COL["subtle"])
        self._paint(self._bg if enabled else COL["card"])
        self.configure(cursor="" if enabled else "arrow")
        for widget in (self, self._inner, self._label):
            widget.configure(cursor="hand2" if enabled else "")


class PlaceholderEntry(tk.Entry):
    def __init__(self, master: tk.Misc, placeholder: str, **kwargs):
        super().__init__(master, **kwargs)
        self._placeholder = placeholder
        self._showing = False
        self._fg = kwargs.get("fg", COL["text"])
        self._muted = COL["muted"]
        self.bind("<FocusIn>", self._focus_in)
        self.bind("<FocusOut>", self._focus_out)
        self._show_placeholder()

    def _show_placeholder(self) -> None:
        if not super().get():
            self._showing = True
            self.configure(fg=self._muted)
            self.insert(0, self._placeholder)

    def _focus_in(self, _event=None) -> None:
        if self._showing:
            self.delete(0, "end")
            self.configure(fg=self._fg)
            self._showing = False

    def _focus_out(self, _event=None) -> None:
        if not super().get():
            self._show_placeholder()

    def get(self) -> str:
        if self._showing:
            return ""
        return super().get()

    def set_text(self, text: str) -> None:
        self._showing = False
        self.delete(0, "end")
        self.configure(fg=self._fg)
        if text:
            self.insert(0, text)
        else:
            self._show_placeholder()


class ModeRow(tk.Frame):
    def __init__(self, master: tk.Misc, mode: Dict[str, Any],
                 font_title, font_desc, command):
        super().__init__(master, bg=COL["card"], cursor="hand2",
                         height=48)
        self._selected = False
        self._command = command
        self.pack_propagate(False)
        self._dot = tk.Canvas(self, width=18, height=18, bg=COL["card"],
                              highlightthickness=0, cursor="hand2")
        self._dot.pack(side="left", padx=(10, 8))
        self._ring = self._dot.create_oval(2, 2, 16, 16, outline=COL["muted"], width=2)
        self._fill = self._dot.create_oval(6, 6, 12, 12, fill=COL["card"], outline="")

        text_box = tk.Frame(self, bg=COL["card"], cursor="hand2")
        text_box.pack(side="left", fill="both", expand=True, pady=3)
        self._title = tk.Label(text_box, text=mode["title"], bg=COL["card"],
                               fg=COL["text"], font=font_title, anchor="w",
                               cursor="hand2")
        self._title.pack(fill="x", anchor="w")
        self._desc = tk.Label(text_box, text=mode["desc"], bg=COL["card"],
                              fg=COL["muted"], font=font_desc, anchor="w",
                              cursor="hand2")
        self._desc.pack(fill="x", anchor="w")

        for widget in (self, self._dot, text_box, self._title, self._desc):
            widget.bind("<Button-1>", self._click)

    def _click(self, _event=None) -> None:
        self._command()

    def set_selected(self, selected: bool) -> None:
        self._selected = selected
        if selected:
            self._dot.itemconfigure(self._ring, outline=COL["accent"])
            self._dot.itemconfigure(self._fill, fill=COL["accent"])
        else:
            self._dot.itemconfigure(self._ring, outline=COL["muted"])
            self._dot.itemconfigure(self._fill, fill=COL["card"])


class VariantDialog(tk.Toplevel):
    def __init__(self, parent: tk.Misc, title: str,
                 variants: List[Dict[str, Any]], subtitle: str = ""):
        super().__init__(parent)
        self.result: Optional[Dict[str, Any]] = None
        self._variants = variants
        self.title(APP_NAME)
        self.configure(bg=COL["bg"])
        self.resizable(False, False)
        self.transient(parent)
        self.protocol("WM_DELETE_WINDOW", self._cancel)
        self._font = pick_font_family(parent)

        tk.Label(self, text="Выберите вариант / озвучку", bg=COL["bg"],
                 fg=COL["text"], font=(self._font, 13, "bold"),
                 anchor="w").pack(fill="x", padx=20, pady=(18, 2))
        sub_text = "Найдено вариантов: " + str(len(variants))
        if subtitle:
            sub_text = subtitle + " · " + sub_text
        elif title:
            sub_text = title + " · " + sub_text
        tk.Label(self, text=sub_text, bg=COL["bg"], fg=COL["muted"],
                 font=(self._font, 9), anchor="w").pack(fill="x", padx=21, pady=(0, 10))

        list_frame = tk.Frame(self, bg=COL["bg"])
        list_frame.pack(fill="both", expand=True, padx=20)
        self._list = tk.Listbox(
            list_frame, bg=COL["card"], fg=COL["text"],
            selectbackground=COL["accent"], selectforeground=COL["text"],
            font=(self._font, 10), height=9, activestyle="none",
            selectmode=tk.SINGLE, exportselection=False, bd=0,
            highlightthickness=1, highlightbackground=COL["field"],
            highlightcolor=COL["accent"])
        scrollbar = tk.Scrollbar(list_frame, orient="vertical",
                                 command=self._list.yview, width=12,
                                 bg=COL["card"], troughcolor=COL["bg"],
                                 activebackground=COL["field_hi"],
                                 highlightthickness=0, bd=0)
        self._list.configure(yscrollcommand=scrollbar.set)
        self._list.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")

        for variant in variants:
            self._list.insert("end", self._label_for(variant))
        if variants:
            self._list.selection_set(0)
            self._list.activate(0)

        buttons = tk.Frame(self, bg=COL["bg"])
        buttons.pack(fill="x", padx=20, pady=(14, 18))
        self._start = FlatButton(
            buttons, "Запустить выбранный вариант", self._ok,
            bg=COL["accent"], hover=COL["accent_hi"],
            font=(self._font, 10), border=COL["accent"], height=44)
        self._start.pack(side="left", fill="x", expand=True)
        cancel = FlatButton(
            buttons, "Отмена", self._cancel, bg=COL["field"],
            hover=COL["field_hi"], font=(self._font, 10), height=44, width=122)
        cancel.pack(side="left", padx=(12, 0))
        cancel.pack_propagate(False)

        self._list.bind("<Double-Button-1>", lambda _e: self._ok())
        self.bind("<Return>", lambda _e: self._ok())
        self.bind("<Escape>", lambda _e: self._cancel())
        self.update_idletasks()
        width, height = 520, 470
        px, py = parent.winfo_rootx(), parent.winfo_rooty()
        pw, ph = parent.winfo_width(), parent.winfo_height()
        x = px + max(0, (pw - width) // 2)
        y = py + max(0, (ph - height) // 2)
        self.geometry(f"{width}x{height}+{x}+{y}")
        self.grab_set()
        self._list.focus_set()

    @staticmethod
    def _label_for(variant: Dict[str, Any]) -> str:
        name = str(variant.get("name") or "")
        episodes = variant.get("episodes") or []
        count = len(episodes)
        label = str(variant.get("label") or "")
        if label:
            return label
        return f"{name}  ·  {count} сер."

    def _ok(self) -> None:
        selection = self._list.curselection()
        if not selection:
            return
        self.result = self._variants[selection[0]]
        self.destroy()

    def _cancel(self) -> None:
        self.result = None
        self.destroy()

    def show(self) -> Optional[Dict[str, Any]]:
        self.wait_window(self)
        return self.result


# --------------------------------------------------------------------------
#  Главное окно
# --------------------------------------------------------------------------
class LauncherApp:
    def __init__(self, root_dir: Path, config_dir: Path):
        self.root_dir = root_dir
        self.config_dir = config_dir
        self.shader_dir = config_dir / "shaders"
        self.whisper_dir = config_dir / "whisper"
        self.manifest = config_dir / "season_manifest.json"
        self.meta = root_dir / "temp_playlist_meta.json"

        self.mpv = find_tool("mpv", root_dir, [config_dir / "whisper"])
        self.ytdlp = find_tool("yt-dlp", root_dir, [config_dir / "whisper"])
        self.gpu_tier, self.gpu_name = detect_gpu()
        self._write_gpu_profile()

        RUNTIME["root"] = str(root_dir)

        self.tk = tk.Tk()
        self.tk.title(APP_NAME)
        self.tk.configure(bg=COL["bg"])
        self.tk.geometry("960x952")
        self.tk.resizable(False, False)
        self.tk.protocol("WM_DELETE_WINDOW", self.tk.destroy)
        self.font = pick_font_family(self.tk)
        self._try_icon()

        self.mode_index = 0
        self.mode_rows: List[ModeRow] = []
        self._online_busy = False
        self._search_queue: "queue.Queue[Tuple[str, Dict[str, Any]]]" = queue.Queue()
        self._build_ui()
        self._check_tools()

    # ------------------------------------------------------------------ UI
    def _font(self, size: int, bold: bool = False):
        return (self.font, size, "bold") if bold else (self.font, size)

    def _try_icon(self) -> None:
        # Иконка не критична; на Linux/macOS .ico может отсутствовать.
        candidates = [self.root_dir / "icon.ico", self.config_dir / "icon.ico"]
        for path in candidates:
            try:
                if path.is_file():
                    self.tk.iconbitmap(default=str(path))
                    return
            except Exception:
                continue

    def _card(self, parent: tk.Misc, height: Optional[int] = None) -> tk.Frame:
        card = tk.Frame(parent, bg=COL["card"], height=height or 0)
        card.pack(fill="x", pady=(0, 14))
        if height:
            card.pack_propagate(False)
        return card

    def _build_ui(self) -> None:
        footer = tk.Frame(self.tk, bg=COL["bg"], height=44)
        footer.pack(side="bottom", fill="x")
        footer.pack_propagate(False)
        self.footer_label = tk.Label(
            footer,
            text=("Во время просмотра можно менять режимы на лету: Ctrl+1 (Mode A)  |  "
                  "Ctrl+2 (Mode B)  |  Ctrl+3 (Mode C)  |  Ctrl+4 (Кино)  |  "
                  "Ctrl+5 (Старое кино)  |  Ctrl+0 (Оригинал)"),
            bg=COL["bg"], fg=COL["subtle"], font=self._font(8),
            anchor="w", justify="left")
        self.footer_label.pack(fill="both", expand=True, padx=26, pady=(0, 2))

        body = tk.Frame(self.tk, bg=COL["bg"])
        body.pack(side="top", fill="both", expand=True)

        self.canvas = tk.Canvas(body, bg=COL["bg"], highlightthickness=0, bd=0)
        scrollbar = tk.Scrollbar(
            body, orient="vertical", command=self.canvas.yview, width=12,
            bg=COL["card"], troughcolor=COL["bg"],
            activebackground=COL["field_hi"], highlightthickness=0, bd=0)
        self.canvas.configure(yscrollcommand=scrollbar.set)
        self.canvas.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")

        self.content = tk.Frame(self.canvas, bg=COL["bg"])
        self._content_window = self.canvas.create_window(
            (0, 0), window=self.content, anchor="nw")
        self.content.bind(
            "<Configure>",
            lambda _e: self.canvas.configure(scrollregion=self.canvas.bbox("all")))
        self.canvas.bind(
            "<Configure>",
            lambda e: self.canvas.itemconfigure(self._content_window, width=e.width))

        self.canvas.bind_all("<MouseWheel>", self._on_mousewheel)
        self.canvas.bind_all("<Button-4>", self._on_mousewheel_linux)
        self.canvas.bind_all("<Button-5>", self._on_mousewheel_linux)

        pad = tk.Frame(self.content, bg=COL["bg"])
        pad.pack(fill="both", expand=True, padx=24, pady=(16, 4))

        # ---------------- header ----------------
        header = tk.Frame(pad, bg=COL["bg"], height=72)
        header.pack(fill="x", pady=(0, 6))
        header.pack_propagate(False)
        tk.Label(header, text=APP_NAME, bg=COL["bg"], fg=COL["text"],
                 font=self._font(22, True), anchor="w").pack(
            fill="x", anchor="w")
        tk.Label(header,
                 text="Домашний 4K-кинотеатр: аниме, фильмы и сериалы — "
                      "с нейросетевым апскейлом",
                 bg=COL["bg"], fg=COL["muted"], font=self._font(9),
                 anchor="w").pack(fill="x", anchor="w", padx=3)

        # ---------------- card 1: modes ----------------
        card1 = self._card(pad)
        tk.Label(card1, text="Режим улучшения", bg=COL["card"],
                 fg=COL["text"], font=self._font(11, True), anchor="w").pack(
            fill="x", padx=18, pady=(14, 8))
        rows = tk.Frame(card1, bg=COL["card"])
        rows.pack(fill="x", padx=12, pady=(0, 10))
        for index, mode in enumerate(MODES):
            row = ModeRow(rows, mode, self._font(9, True), self._font(8, False),
                          lambda i=index: self._select_mode(i))
            row.pack(fill="x", pady=1)
            self.mode_rows.append(row)
        self._select_mode(0, initial=True)

        # ---------------- card 2: online ----------------
        card2 = self._card(pad)
        tk.Label(card2, text="Смотреть онлайн по ссылке или названию",
                 bg=COL["card"], fg=COL["text"],
                 font=self._font(11, True), anchor="w").pack(
            fill="x", padx=18, pady=(14, 2))
        tk.Label(card2,
                 text="Вставьте ссылку (YouTube, VK, RuTube, Кинопоиск и др.) "
                      "или введите название аниме, фильма, сериала:",
                 bg=COL["card"], fg=COL["muted"], font=self._font(8),
                 anchor="w", justify="left").pack(fill="x", padx=18, pady=(0, 8))

        row2 = tk.Frame(card2, bg=COL["card"])
        row2.pack(fill="x", padx=18)
        self.url_entry = PlaceholderEntry(
            row2, "https://... или название (например, Гуррен-Лаганн)",
            bg=COL["field"], fg=COL["text"], insertbackground=COL["text"],
            relief="flat", bd=0, highlightthickness=1,
            highlightbackground=COL["field_hi"], highlightcolor=COL["accent"],
            font=self._font(10))
        self.url_entry.configure(width=1)
        self.url_entry.pack(side="left", fill="x", expand=True, ipady=5)
        self.btn_paste = FlatButton(
            row2, "Вставить из буфера", self._paste_clipboard,
            bg=COL["field"], hover=COL["field_hi"], font=self._font(10),
            height=30, width=210)
        self.btn_paste.pack(side="left", padx=(8, 0))
        self.btn_paste.pack_propagate(False)

        self.btn_online = FlatButton(
            card2, "Смотреть онлайн в 4K", self._on_online,
            bg=COL["accent"], hover=COL["accent_hi"], font=self._font(11, True),
            border=COL["accent"], height=44)
        self.btn_online.pack(fill="x", padx=18, pady=(10, 16))

        self.url_entry.bind("<Return>", lambda _e: self._on_online())
        self.tk.bind("<Control-v>", self._on_ctrl_v)
        self.tk.bind("<Control-V>", self._on_ctrl_v)

        # ---------------- card 3: local files ----------------
        card3 = self._card(pad)
        tk.Label(card3, text="Файлы с компьютера", bg=COL["card"],
                 fg=COL["text"], font=self._font(11, True), anchor="w").pack(
            fill="x", padx=18, pady=(14, 8))
        row3 = tk.Frame(card3, bg=COL["card"])
        row3.pack(fill="x", padx=18, pady=(0, 16))
        btn_file = FlatButton(row3, "Открыть серию или фильм с ПК",
                              self._open_file, bg=COL["field"],
                              hover=COL["field_hi"], font=self._font(10),
                              height=42)
        btn_file.pack(side="left", fill="x", expand=True)
        btn_folder = FlatButton(row3, "Открыть папку с сезоном",
                                self._open_folder, bg=COL["field"],
                                hover=COL["field_hi"], font=self._font(10),
                                height=42)
        btn_folder.pack(side="left", fill="x", expand=True, padx=(14, 0))

        # ---------------- card 4: browser / system upscale ----------------
        if IS_WINDOWS:
            self._build_windows_card(pad)
        else:
            self._build_system_upscale_card(pad)

    def _build_windows_card(self, parent: tk.Misc) -> None:
        card4 = self._card(parent)
        tk.Label(card4, text="4K прямо в браузере (Magpie и NVIDIA VSR)",
                 bg=COL["card"], fg=COL["text"],
                 font=self._font(11, True), anchor="w").pack(
            fill="x", padx=18, pady=(14, 8))
        row = tk.Frame(card4, bg=COL["card"])
        row.pack(fill="x", padx=18)
        btn_magpie = FlatButton(row, "Включить 4K поверх браузера",
                                self._start_magpie, bg=COL["field"],
                                hover=COL["field_hi"], font=self._font(10),
                                height=42)
        btn_magpie.pack(side="left", fill="x", expand=True)
        btn_vsr = FlatButton(row, "Настройки NVIDIA VSR (Суперразрешение)",
                             self._open_nvidia_vsr, bg=COL["field"],
                             hover=COL["field_hi"], font=self._font(10),
                             height=42)
        btn_vsr.pack(side="left", fill="x", expand=True, padx=(14, 0))
        tk.Label(card4,
                 text="Для Magpie: откройте видео в браузере в обычном окне "
                      "и нажмите Win + Shift + A",
                 bg=COL["card"], fg=COL["muted"], font=self._font(8),
                 anchor="w").pack(fill="x", padx=18, pady=(8, 14))

    def _build_system_upscale_card(self, parent: tk.Misc) -> None:
        system = "macOS" if IS_MAC else "Linux"
        card4 = self._card(parent)
        tk.Label(card4, text=f"4K и системный апскейл ({system})",
                 bg=COL["card"], fg=COL["text"],
                 font=self._font(11, True), anchor="w").pack(
            fill="x", padx=18, pady=(14, 4))
        if IS_MAC:
            hint = ("mpv использует Metal и VideoToolbox: нейросетевой апскейл "
                    "Anime4K/FSRCNNX работает внутри плеера. Системный масштаб "
                    "настраивается в System Settings → Displays.")
        else:
            hint = ("mpv использует Vulkan/OpenGL и VA-API/NVDEC: нейросетевой "
                    "апскейл Anime4K/FSRCNNX работает внутри плеера. Системный "
                    "масштаб окон — в настройках дисплея KDE/GNOME.")
        tk.Label(card4, text=hint, bg=COL["card"], fg=COL["muted"],
                 font=self._font(8), anchor="w", justify="left",
                 wraplength=820).pack(fill="x", padx=18)
        btn = FlatButton(card4, "Как включить системный апскейл",
                         self._system_upscale_help, bg=COL["field"],
                         hover=COL["field_hi"], font=self._font(10), height=42)
        btn.pack(fill="x", padx=18, pady=(12, 16))

    def _on_mousewheel(self, event) -> None:
        try:
            if IS_MAC:
                delta = -1 * int(event.delta)
            elif IS_WINDOWS:
                delta = -1 * int(event.delta / 120)
            else:
                delta = -1 * int(event.delta)
            if delta:
                self.canvas.yview_scroll(delta, "units")
        except Exception:
            pass

    def _on_mousewheel_linux(self, event) -> None:
        try:
            self.canvas.yview_scroll(-1 if event.num == 4 else 1, "units")
        except Exception:
            pass

    # ------------------------------------------------------------- actions
    def _select_mode(self, index: int, initial: bool = False) -> None:
        self.mode_index = max(0, min(index, len(self.mode_rows) - 1))
        for row_index, row in enumerate(self.mode_rows):
            row.set_selected(row_index == self.mode_index)

    def _paste_clipboard(self) -> None:
        try:
            text = self.tk.clipboard_get()
        except Exception:
            text = ""
        if text:
            self.url_entry.set_text(text.strip())
            self.url_entry.focus_set()

    def _on_ctrl_v(self, event=None):
        # В поле ввода Ctrl+V обрабатывает сам tk.Entry; в остальных местах
        # окна — вставляем ссылку в поле, как в Windows-лаунчере.
        if event is not None and event.widget is self.url_entry:
            return None
        self._paste_clipboard()
        return "break"

    def _set_online_busy(self, busy: bool, text: str = "") -> None:
        self._online_busy = busy
        self.btn_online.set_enabled(not busy)
        self.btn_online.set_text(
            text if busy else "Смотреть онлайн в 4K")
        self.tk.configure(cursor="watch" if busy else "")

    def _check_tools(self) -> None:
        missing = []
        if not self.mpv:
            missing.append("mpv")
        if not self.ytdlp:
            missing.append("yt-dlp")
        if missing:
            self.footer_label.configure(
                text=("Не найдено: " + ", ".join(missing)
                      + ". Запустите «python setup.py» или установите "
                        "компоненты в PATH.   |   "
                      + self.footer_label.cget("text")),
                fg="#fbbf24")

    # ------------------------------------------------------------ online
    def _on_online(self) -> None:
        if self._online_busy:
            return
        query = self.url_entry.get().strip()
        if not query:
            self._error("Введите ссылку или название аниме, фильма, сериала.")
            return
        if self.mpv is None:
            self._error("Не найден mpv. Запустите «python setup.py» или "
                        "установите mpv в PATH.")
            return
        if is_direct_url(query):
            try:
                self._launch_mpv(target=query)
            except Exception as exc:
                self._error(str(exc))
            return

        self._set_online_busy(True, "Поиск по названию, сезонам и озвучкам...")
        thread = threading.Thread(
            target=self._search_worker, args=(query,), daemon=True)
        thread.start()
        self.tk.after(100, self._poll_search)

    def _search_worker(self, query: str) -> None:
        try:
            result = search_online(query, self.ytdlp)
        except Exception as exc:  # noqa: BLE001 - показываем пользователю текст
            result = {"error": f"Ошибка поиска: {exc}"}
        # Tkinter нельзя вызывать из фонового потока: результат забирает
        # главный цикл через очередь в _poll_search.
        self._search_queue.put((query, result))

    def _poll_search(self) -> None:
        try:
            query, result = self._search_queue.get_nowait()
        except queue.Empty:
            if self._online_busy:
                self.tk.after(100, self._poll_search)
            return
        self._on_search_done(query, result)

    def _on_search_done(self, query: str, result: Dict[str, Any]) -> None:
        self._set_online_busy(False)
        if result.get("protected"):
            self._info(str(result.get("message") or "Источник защищён."))
            return
        if result.get("error"):
            fallback = result.get("fallback_direct")
            if fallback and is_direct_url(query):
                try:
                    self._launch_mpv(target=query)
                    return
                except Exception as exc:
                    self._error(str(exc))
                    return
            self._error(str(result["error"]))
            return

        seasons = [s for s in (result.get("seasons") or []) if s]
        variants: List[Dict[str, Any]] = []
        for season_index, season in enumerate(seasons):
            for voice in season.get("voices") or []:
                if not voice or not voice.get("episodes"):
                    continue
                count = len(voice["episodes"])
                if count == 0:
                    continue
                label = f"{voice.get('name') or 'Озвучка'}  ·  {count} сер."
                if voice.get("duration"):
                    duration = format_duration_text(int(voice["duration"]))
                    first_ep = str(voice["episodes"][0].get("title") or "")
                    pieces = [p for p in (first_ep, str(voice.get("name") or ""),
                                          duration) if p]
                    if count > 1:
                        pieces.append(f"{count} сер.")
                    label = "  ·  ".join(pieces)
                if len(seasons) > 1:
                    prefix = str(season.get("short") or season.get("name") or "")
                    if prefix:
                        label = prefix + "  ·  " + label
                elif season.get("name") and season.get("name") != result.get("title"):
                    label = str(season["name"]) + "  ·  " + label
                variants.append({
                    "name": str(voice.get("name") or ""),
                    "episodes": voice["episodes"],
                    "label": label,
                    "season": season_index + 1,
                    "source": voice.get("source") or season.get("source") or "",
                })

        if not variants:
            self._error("У найденных вариантов нет серий.")
            return

        pick = variants[0]
        if len(variants) > 1:
            subtitle = ""
            if result.get("kp_id"):
                subtitle = "Кинопоиск · ID " + str(result["kp_id"])
            dialog = VariantDialog(self.tk, str(result.get("title") or ""),
                                   variants, subtitle)
            picked = dialog.show()
            if picked is None:
                return
            pick = picked

        picked_season = int(pick.get("season") or 1)
        if picked_season < 1 or picked_season > len(seasons):
            picked_season = 1
        try:
            playlist = write_season_files(
                self.root_dir, result, seasons, picked_season,
                str(pick.get("name") or ""), self.config_dir)
        except Exception as exc:
            self._error("Не удалось подготовить плейлист серий: " + str(exc))
            return
        if not playlist or not Path(playlist).is_file():
            self._error("Не удалось подготовить плейлист серий.")
            return
        try:
            self._launch_mpv(playlist=playlist)
        except Exception as exc:
            self._error(str(exc))

    # ------------------------------------------------------------- local
    def _open_file(self) -> None:
        path = filedialog.askopenfilename(
            title="Выберите серию или фильм",
            filetypes=[
                ("Видео", "*.mkv *.mp4 *.avi *.webm *.m4v *.mov *.ts"),
                ("Все файлы", "*.*"),
            ])
        if path:
            try:
                self._launch_mpv(target=path)
            except Exception as exc:
                self._error(str(exc))

    def _open_folder(self) -> None:
        path = filedialog.askdirectory(
            title="Выберите папку с сезоном (серии пойдут подряд)")
        if path:
            try:
                self._launch_mpv(target=path)
            except Exception as exc:
                self._error(str(exc))

    # ------------------------------------------------------------ mpv run
    def _mode_shaders(self) -> List[Path]:
        mode = MODES[self.mode_index]
        names = list(mode.get("files") or [])
        if self.gpu_tier == "lite" and mode.get("files_lite"):
            names = list(mode["files_lite"])
        paths = [self.shader_dir / name for name in names]
        missing = [str(path) for path in paths if not path.is_file()]
        if missing:
            raise FileNotFoundError(
                "Не найдены файлы шейдеров: " + ", ".join(missing))
        return paths

    def _mpv_args(self, target: Optional[str] = None,
                  playlist: Optional[Path] = None) -> List[str]:
        if not self.mpv:
            raise FileNotFoundError(
                "Не найден mpv. Запустите «python setup.py» или установите mpv.")
        shaders = self._mode_shaders()
        args = [self.mpv]
        args.append("--glsl-shaders=" + ";".join(str(p) for p in shaders)
                    if shaders else "--glsl-shaders=")
        vf = MODES[self.mode_index].get("vf") or ""
        args.append("--vf=" + vf)
        args.append("--script-opts-append=yummy_ui-gpu_tier=" + self.gpu_tier)
        if self.ytdlp:
            args.append("--script-opts-append=ytdl_hook-ytdl_path=" + self.ytdlp)
        # ВАЖНО: на Linux/macOS portable_config не подхватывается автоматически,
        # поэтому --config-dir передаём всегда (на Windows это тоже безвредно).
        if self.config_dir.is_dir():
            args.append("--config-dir=" + str(self.config_dir))
        if playlist is not None:
            args.append("--playlist=" + str(playlist))
        elif target:
            args.append(str(target))
        return args

    def _launch_mpv(self, target: Optional[str] = None,
                    playlist: Optional[Path] = None) -> None:
        args = self._mpv_args(target=target, playlist=playlist)
        kwargs: Dict[str, Any] = {
            "cwd": str(self.root_dir),
            "close_fds": True,
        }
        if IS_WINDOWS:
            kwargs["creationflags"] = 0
        else:
            kwargs["start_new_session"] = True
        subprocess.Popen(args, **kwargs)

    # --------------------------------------------------------- GPU profile
    def _write_gpu_profile(self) -> None:
        try:
            path = self.config_dir / "gpu_profile.txt"
            text = (f"tier={self.gpu_tier}\nname={self.gpu_name}\n"
                    f"generated={_dt.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')}\n")
            path.write_text(text, encoding="utf-8")
        except OSError:
            pass
        os.environ["FILMS4K_GPU_TIER"] = self.gpu_tier
        os.environ["FILMS4K_GPU_NAME"] = self.gpu_name

    # ------------------------------------------------- windows-only actions
    def _start_magpie(self) -> None:
        if not IS_WINDOWS:
            self._system_upscale_help()
            return
        magpie = self.root_dir / "Magpie" / "Magpie.exe"
        if not magpie.is_file():
            self._error("Не найден Magpie.exe в папке Magpie.")
            return
        try:
            result = subprocess.run(
                ["tasklist", "/FI", "IMAGENAME eq Magpie.exe"],
                capture_output=True, text=True, timeout=10,
                creationflags=CREATE_NO_WINDOW, encoding="utf-8", errors="replace")
            if "Magpie.exe" in (result.stdout or ""):
                self._error("Magpie уже запущен. Переключите окно браузера "
                            "и нажмите Win + Shift + A.")
                return
            subprocess.Popen([str(magpie)], cwd=str(magpie.parent))
        except Exception as exc:
            self._error(str(exc))

    def _open_nvidia_vsr(self) -> None:
        if not IS_WINDOWS:
            self._system_upscale_help()
            return
        local = os.environ.get("LOCALAPPDATA", "")
        candidates = [
            r"C:\Program Files\NVIDIA Corporation\NVIDIA app\CEF\NVIDIA app.exe",
            r"C:\Program Files\NVIDIA Corporation\NVIDIA App\NVIDIA App.exe",
            os.path.join(local, r"NVIDIA Corporation\NVIDIA app\CEF\NVIDIA app.exe")
            if local else "",
            r"C:\Program Files\NVIDIA Corporation\NVIDIA Control Panel\nvcplui.exe",
        ]
        started = False
        for candidate in candidates:
            if candidate and Path(candidate).is_file():
                try:
                    subprocess.Popen([candidate])
                    started = True
                    break
                except OSError:
                    continue
        if not started:
            try:
                subprocess.Popen(["nvcplui.exe"])
                started = True
            except OSError:
                pass
        message = ("Откройте раздел Видео -> Регулировка параметров изображения "
                   "для видео -> включите Суперразрешение (качество 4) "
                   "и нажмите Применить.")
        if not started:
            message = ("Не удалось автоматически открыть панель NVIDIA "
                       "(nvcplui.exe / NVIDIA app).\n\n" + message)
        messagebox.showinfo("NVIDIA VSR", message, parent=self.tk)

    def _system_upscale_help(self) -> None:
        if IS_MAC:
            text = ("Нейросетевой апскейл Anime4K и FSRCNNX уже работает внутри "
                    "mpv (Metal/VideoToolbox).\n\n"
                    "Системный масштаб интерфейса и видео:\n"
                    "• System Settings → Displays → выберите разрешение 4K "
                    "или «More Space»;\n"
                    "• для HDR включите High Dynamic Range в том же разделе.\n\n"
                    "Внешние апскейлеры (например, Motion) не требуются.")
        else:
            text = ("Нейросетевой апскейл Anime4K и FSRCNNX уже работает внутри "
                    "mpv (Vulkan/OpenGL + VA-API/NVDEC).\n\n"
                    "Системный масштаб:\n"
                    "• KDE: System Settings → Display and Monitor → Scale;\n"
                    "• GNOME: Settings → Displays → Scale;\n"
                    "• для HDR проверьте настройки дисплея и поддержку Vulkan.\n\n"
                    "Отдельные Windows-утилиты (Magpie, NVIDIA VSR) на Linux "
                    "не нужны.")
        messagebox.showinfo("Системный апскейл", text, parent=self.tk)

    # -------------------------------------------------------------- misc
    def _error(self, message: str) -> None:
        messagebox.showwarning(APP_NAME, message, parent=self.tk)

    def _info(self, message: str) -> None:
        messagebox.showinfo(APP_NAME, message, parent=self.tk)

    def run(self) -> None:
        self.tk.mainloop()


# --------------------------------------------------------------------------
#  Точка входа
# --------------------------------------------------------------------------
def resolve_config_dir(root_dir: Path, value: Optional[str]) -> Path:
    if value:
        candidate = Path(value).expanduser()
        if not candidate.is_absolute():
            candidate = (root_dir / candidate).resolve()
        if candidate.is_dir():
            return candidate
    return root_dir / "portable_config"


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Anime4K Center — кроссплатформенный 4K-лаунчер")
    parser.add_argument(
        "--config-dir", default=None,
        help="путь к portable_config (обязателен для mpv на Linux/macOS)")
    parser.add_argument(
        "--smoke-test", action="store_true",
        help="создать окно, проверить запуск и сразу закрыть")
    args = parser.parse_args(argv)

    root_dir = Path(__file__).resolve().parent
    config_dir = resolve_config_dir(root_dir, args.config_dir)
    app = LauncherApp(root_dir, config_dir)

    if args.smoke_test:
        app.tk.update_idletasks()
        app.tk.update()
        app.tk.destroy()
        print("SMOKE OK")
        return 0

    app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
