#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Anime4K Center — умный кроссплатформенный установщик зависимостей.

Использование:
    python setup.py            # Windows: python setup.py
    python setup.py --check    # только проверить окружение
    python setup.py --force    # перекачать уже существующие файлы

Скрипт использует только стандартную библиотеку Python:
urllib, zipfile, tarfile, subprocess, shutil, platform.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

IS_WINDOWS = sys.platform.startswith("win")
IS_MAC = sys.platform == "darwin"
IS_LINUX = sys.platform.startswith("linux")
# macOS: Homebrew — /opt/homebrew/bin (Apple Silicon M1–M4) и
# /usr/local/bin (Intel). Добавляем оба пути, чтобы shutil.which находил
# mpv/yt-dlp/ffmpeg даже при урезанном PATH из Finder.
if IS_MAC:
    for _brew_bin in ("/opt/homebrew/bin", "/usr/local/bin"):
        _path_parts = os.environ.get("PATH", "").split(os.pathsep)
        if _brew_bin not in _path_parts:
            os.environ["PATH"] = (_brew_bin + os.pathsep
                                  + os.environ.get("PATH", ""))
CREATE_NO_WINDOW = 0x08000000 if IS_WINDOWS else 0
ROOT = Path(__file__).resolve().parent
CONFIG = ROOT / "portable_config"
WHISPER = CONFIG / "whisper"

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
YTDLP_EXE = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
MODEL_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"


# --------------------------------------------------------------------------
#  Вывод
# --------------------------------------------------------------------------
def say(message: str = "") -> None:
    print(message, flush=True)


def head(title: str) -> None:
    say()
    say("=" * 66)
    say("  " + title)
    say("=" * 66)


def ok(message: str) -> None:
    say("  [OK]   " + message)


def note(message: str) -> None:
    say("  [i]    " + message)


def warn(message: str) -> None:
    say("  [!]    " + message)


def fail(message: str) -> None:
    say("  [X]    " + message)


# --------------------------------------------------------------------------
#  Загрузка / распаковка
# --------------------------------------------------------------------------
def _human(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} GB"


def download(url: str, destination: Path, label: str = "") -> bool:
    """Скачивает файл с прогрессом. Возвращает True при успехе."""
    label = label or destination.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = destination.with_suffix(destination.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept": "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=60) as response, \
                open(temp, "wb") as handle:
            total = int(response.headers.get("Content-Length") or 0)
            done = 0
            started = time.time()
            last_print = 0.0
            while True:
                chunk = response.read(1024 * 256)
                if not chunk:
                    break
                handle.write(chunk)
                done += len(chunk)
                now = time.time()
                if now - last_print > 0.7:
                    last_print = now
                    if total:
                        percent = done * 100.0 / total
                        speed = done / max(0.1, now - started)
                        sys.stdout.write(
                            f"\r         {label}: {percent:5.1f}%  "
                            f"{_human(done)} / {_human(total)}  "
                            f"({_human(int(speed))}/s)   ")
                    else:
                        sys.stdout.write(f"\r         {label}: {_human(done)}   ")
                    sys.stdout.flush()
            if total:
                sys.stdout.write("\r" + " " * 78 + "\r")
                sys.stdout.flush()
        if temp.stat().st_size == 0:
            raise OSError("получен пустой файл")
        temp.replace(destination)
        ok(f"{label} → {destination}")
        return True
    except urllib.error.HTTPError as exc:
        fail(f"{label}: HTTP {exc.code} ({url})")
    except urllib.error.URLError as exc:
        fail(f"{label}: сеть недоступна ({exc.reason})")
    except Exception as exc:  # noqa: BLE001 - установщик не должен падать
        fail(f"{label}: {exc}")
    finally:
        try:
            if temp.exists():
                temp.unlink()
        except OSError:
            pass
    return False


def _safe_members(names) -> bool:
    for name in names:
        normalized = os.path.normpath(name)
        if normalized.startswith("..") or os.path.isabs(normalized):
            return False
    return True


def extract_zip(archive: Path, destination: Path,
                flatten: bool = False) -> bool:
    try:
        with zipfile.ZipFile(archive) as zf:
            names = zf.namelist()
            if not _safe_members(names):
                fail("архив содержит небезопасные пути")
                return False
            if flatten:
                top_levels = {n.split("/")[0] for n in names if n.strip("/")}
                strip = ""
                if len(top_levels) == 1:
                    only = next(iter(top_levels))
                    if any(n.startswith(only + "/") for n in names):
                        strip = only + "/"
                destination.mkdir(parents=True, exist_ok=True)
                for name in names:
                    if name.endswith("/"):
                        continue
                    rel = name[len(strip):] if strip and name.startswith(strip) else name
                    if not rel:
                        continue
                    target = destination / rel
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with zf.open(name) as src, open(target, "wb") as dst:
                        shutil.copyfileobj(src, dst)
            else:
                destination.mkdir(parents=True, exist_ok=True)
                zf.extractall(destination)
        return True
    except Exception as exc:  # noqa: BLE001
        fail(f"не удалось распаковать {archive.name}: {exc}")
        return False


def extract_tar(archive: Path, destination: Path) -> bool:
    try:
        with tarfile.open(archive) as tf:
            if not _safe_members(tf.getnames()):
                fail("архив содержит небезопасные пути")
                return False
            destination.mkdir(parents=True, exist_ok=True)
            tf.extractall(destination)
        return True
    except Exception as exc:  # noqa: BLE001
        fail(f"не удалось распаковать {archive.name}: {exc}")
        return False


def extract_7z(archive: Path, destination: Path) -> bool:
    """Распаковка .7z: tar.exe (bsdtar в Windows 10+), затем 7-Zip.

    Официальные сборки mpv для Windows сейчас публикуются только в .7z.
    bsdtar из состава Windows 10/11 читает 7z без установки 7-Zip.
    """
    destination.mkdir(parents=True, exist_ok=True)
    commands = []
    if shutil.which("tar"):
        commands.append(["tar", "-xf", str(archive), "-C", str(destination)])
    if shutil.which("7z"):
        commands.append(["7z", "x", "-y", f"-o{destination}", str(archive)])
    if shutil.which("7za"):
        commands.append(["7za", "x", "-y", f"-o{destination}", str(archive)])
    if not commands:
        fail("для .7z нужен tar.exe (Windows 10+) или 7-Zip в PATH")
        return False
    for command in commands:
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=600,
                creationflags=CREATE_NO_WINDOW, encoding="utf-8", errors="replace")
            if result.returncode == 0:
                return True
            warn(f"{command[0]} не распаковал архив: "
                 f"{(result.stderr or result.stdout or '').strip()[:200]}")
        except Exception as exc:  # noqa: BLE001
            warn(f"{command[0]} не сработал: {exc}")
    return False


def extract_archive(archive: Path, destination: Path,
                    flatten: bool = False) -> bool:
    name = archive.name.lower()
    if name.endswith(".zip"):
        return extract_zip(archive, destination, flatten)
    if name.endswith(".7z"):
        return extract_7z(archive, destination)
    if name.endswith((".tar.gz", ".tgz", ".tar.bz2", ".tar.xz", ".tar")):
        return extract_tar(archive, destination)
    fail(f"неизвестный формат архива: {archive.name}")
    return False


def copy_tree_contents(src: Path, dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        target = dst / item.name
        try:
            if item.is_dir():
                shutil.copytree(item, target, dirs_exist_ok=True)
            else:
                shutil.copy2(item, target)
        except OSError as exc:
            warn(f"не удалось скопировать {item.name}: {exc}")


def github_latest_asset(repo: str, predicate):
    """Возвращает (release_json, download_url) для подходящего asset."""
    api = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urllib.request.Request(api, headers={
        "User-Agent": UA,
        "Accept": "application/vnd.github+json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            data = json.loads(response.read().decode("utf-8", "replace"))
    except Exception as exc:  # noqa: BLE001
        fail(f"GitHub API {repo}: {exc}")
        return None, None
    for asset in data.get("assets", []):
        if predicate(str(asset.get("name", ""))):
            return data, str(asset.get("browser_download_url", ""))
    return data, ""


def github_release_asset(repo: str, predicate, pages: int = 2):
    """Ищет asset в списке последних релизов, а не только в latest.

    Нужно для whisper.cpp: релиз с тегом-сборкой (b5907) содержит готовые
    архивы, а «latest» может указывать на релиз без assets.
    """
    for page in range(1, max(1, pages) + 1):
        api = (f"https://api.github.com/repos/{repo}/releases"
               f"?per_page=20&page={page}")
        req = urllib.request.Request(api, headers={
            "User-Agent": UA,
            "Accept": "application/vnd.github+json",
        })
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                data = json.loads(response.read().decode("utf-8", "replace"))
        except Exception as exc:  # noqa: BLE001
            fail(f"GitHub API {repo}: {exc}")
            return None, ""
        if not isinstance(data, list):
            return None, ""
        for release in data:
            for asset in release.get("assets", []):
                if predicate(str(asset.get("name", ""))):
                    return release, str(asset.get("browser_download_url", ""))
    return None, ""


# --------------------------------------------------------------------------
#  Windows: mpv / yt-dlp / Magpie / whisper.cpp
# --------------------------------------------------------------------------
def windows_mpv(force: bool) -> None:
    target = ROOT / "mpv.exe"
    if target.is_file() and not force:
        ok(f"mpv уже установлен: {target}")
        return
    say("\n  Ищу свежую сборку mpv для Windows (GitHub)...")

    def pick(name: str) -> bool:
        low = name.lower()
        return (low.startswith("mpv-x86_64-") and low.endswith(".7z")
                and "dev" not in low and "debug" not in low and "v3" not in low)

    archive_url = ""
    source = ""
    for repo in ("shinchiro/mpv-winbuild-cmake", "zhongfly/mpv-winbuild"):
        release, url = github_latest_asset(repo, pick)
        if url:
            archive_url, source = url, repo
            break

    if not archive_url:
        warn("Автоматическая загрузка mpv недоступна.")
        note("Скачайте mpv-x86_64-*.7z вручную:")
        note("https://github.com/shinchiro/mpv-winbuild-cmake/releases")
        note("и распакуйте mpv.exe рядом с launcher.py.")
        return

    tag = (release or {}).get("tag_name") or "?"
    note(f"Источник: {source} · {tag}")

    suffix = ".7z" if archive_url.lower().endswith(".7z") else ".zip"
    with tempfile.TemporaryDirectory(prefix="films4k_mpv_") as tmp:
        archive = Path(tmp) / ("mpv" + suffix)
        if not download(archive_url, archive, "mpv (x86_64)"):
            return
        unpacked = Path(tmp) / "unpacked"
        if not extract_archive(archive, unpacked):
            note("Установите 7-Zip (https://7-zip.org) и повторите запуск.")
            return
        copied = 0
        for item in unpacked.rglob("*"):
            if not item.is_file():
                continue
            # Берём файлы из корня архива и из одной вложенной папки.
            if item.parent != unpacked and item.parent.parent != unpacked:
                continue
            low = item.name.lower()
            if low in ("mpv.exe", "mpv.com", "d3dcompiler_43.dll") or low.endswith(".dll"):
                shutil.copy2(item, ROOT / item.name)
                ok(f"извлечён {item.name}")
                copied += 1
        if not (ROOT / "mpv.exe").is_file():
            fail("в архиве не найден mpv.exe")
        elif copied:
            note("mpv обновлён. Конфиг остаётся в portable_config.")


def windows_ytdlp(force: bool) -> None:
    target = ROOT / "yt-dlp.exe"
    if target.is_file() and not force:
        ok(f"yt-dlp уже установлен: {target}")
        return
    say("\n  Скачиваю yt-dlp.exe с GitHub...")
    download(YTDLP_EXE, target, "yt-dlp.exe")


def windows_magpie(force: bool) -> None:
    target = ROOT / "Magpie" / "Magpie.exe"
    if target.is_file() and not force:
        ok(f"Magpie уже установлен: {target}")
        return
    say("\n  Ищу свежий релиз Magpie на GitHub...")

    def pick(name: str) -> bool:
        low = name.lower()
        return (low.endswith(".zip") and "magpie" in low and "x64" in low
                and "arm" not in low)

    release, url = github_latest_asset("Blinue/Magpie", pick)
    if not url:
        for asset in (release or {}).get("assets", []):
            name = str(asset.get("name", "")).lower()
            if name.endswith(".zip") and "arm" not in name:
                url = str(asset.get("browser_download_url", ""))
                break
    if not url:
        fail("не найден zip-архив Magpie в последнем релизе")
        note("Скачайте вручную: https://github.com/Blinue/Magpie/releases")
        return

    with tempfile.TemporaryDirectory(prefix="films4k_magpie_") as tmp:
        archive = Path(tmp) / "magpie.zip"
        if not download(url, archive, "Magpie"):
            return
        unpacked = Path(tmp) / "unpacked"
        if not extract_zip(archive, unpacked):
            return
        exe = next((p for p in unpacked.rglob("Magpie.exe")), None)
        if not exe:
            fail("в архиве не найден Magpie.exe")
            return
        copy_tree_contents(exe.parent, ROOT / "Magpie")
        ok(f"Magpie установлен: {ROOT / 'Magpie' / 'Magpie.exe'}")


def download_whisper_model(force: bool) -> None:
    target = WHISPER / "ggml-base.bin"
    if target.is_file() and not force:
        ok(f"Модель Whisper уже есть: {target}")
        return
    say("\n  Скачиваю модель Whisper ggml-base.bin (~142 МБ)...")
    note("Источник: huggingface.co/ggerganov/whisper.cpp")
    download(MODEL_URL, target, "ggml-base.bin")


def windows_whisper(force: bool) -> None:
    WHISPER.mkdir(parents=True, exist_ok=True)
    target = WHISPER / "whisper-cli.exe"
    if target.is_file() and not force:
        ok(f"whisper-cli уже установлен: {target}")
        return
    say("\n  Ищу свежую сборку whisper.cpp (x64) на GitHub...")

    def pick(name: str) -> bool:
        # Идеальный вариант — обычная CPU-сборка для x64.
        return name.lower() == "whisper-bin-x64.zip"

    release, url = github_release_asset("ggml-org/whisper.cpp", pick, pages=2)

    if not url:
        def pick_any(name: str) -> bool:
            low = name.lower()
            if not low.endswith(".zip") or "x64" not in low or "bin" not in low:
                return False
            return not any(token in low for token in
                           ("cublas", "cuda", "arm", "blas", "xcframework",
                            "win32", "opencl"))
        release, url = github_release_asset("ggml-org/whisper.cpp", pick_any, pages=2)

    if not url:
        fail("не найден подходящий zip-архив whisper.cpp")
        note("Скачайте whisper-bin-x64.zip вручную:")
        note("https://github.com/ggml-org/whisper.cpp/releases")
        return

    tag = (release or {}).get("tag_name") or "?"
    note(f"Выбран релиз whisper.cpp {tag}")

    with tempfile.TemporaryDirectory(prefix="films4k_whisper_") as tmp:
        archive = Path(tmp) / "whisper.zip"
        if not download(url, archive, "whisper.cpp"):
            return
        unpacked = Path(tmp) / "unpacked"
        if not extract_zip(archive, unpacked):
            return
        exe = next((p for p in unpacked.rglob("whisper-cli.exe")), None)
        if not exe:
            fail("в архиве не найден whisper-cli.exe")
            return
        copy_tree_contents(exe.parent, WHISPER)
        ok(f"whisper.cpp установлен: {WHISPER / 'whisper-cli.exe'}")


# --------------------------------------------------------------------------
#  Linux / macOS
# --------------------------------------------------------------------------
def read_os_release() -> dict:
    data = {}
    try:
        text = Path("/etc/os-release").read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                data[key.strip()] = value.strip().strip('"')
    except OSError:
        pass
    return data


def linux_install_command() -> str:
    info = read_os_release()
    ids = (info.get("ID", "") + " " + info.get("ID_LIKE", "")).lower()
    if any(token in ids for token in ("debian", "ubuntu", "mint", "pop", "kali")):
        return "sudo apt update && sudo apt install -y mpv yt-dlp ffmpeg python3-tk"
    if any(token in ids for token in ("arch", "manjaro", "endeavouros")):
        return "sudo pacman -S --needed mpv yt-dlp ffmpeg tk"
    if any(token in ids for token in ("fedora", "rhel", "centos", "rocky", "almalinux")):
        return ("sudo dnf install -y mpv yt-dlp ffmpeg python3-tkinter\n"
                "         # mpv/ffmpeg в Fedora могут требовать RPM Fusion")
    if any(token in ids for token in ("opensuse", "suse")):
        return "sudo zypper install -y mpv yt-dlp ffmpeg python3-tk"
    if "alpine" in ids:
        return "sudo apk add mpv yt-dlp ffmpeg py3-tkinter"
    if "void" in ids:
        return "sudo xbps-install -S mpv yt-dlp ffmpeg python3-tkinter"
    return ("Установите mpv, yt-dlp, ffmpeg и tkinter штатным менеджером "
            "пакетов вашего дистрибутива.")


def tkinter_available() -> bool:
    try:
        import tkinter  # noqa: F401
        return True
    except Exception:
        return False


def check_binary(name: str, label: str) -> bool:
    found = shutil.which(name)
    if found:
        ok(f"{label}: {found}")
        return True
    fail(f"{label} не найден в PATH")
    return False


def update_ytdlp() -> None:
    local = ROOT / "yt-dlp"
    binary = str(local) if local.is_file() and os.access(local, os.X_OK) \
        else shutil.which("yt-dlp")
    if not binary:
        return
    note("Обновляю yt-dlp до последней версии...")
    try:
        result = subprocess.run([binary, "-U"], capture_output=True,
                                text=True, timeout=120)
        output = (result.stdout or result.stderr or "").strip()
        if result.returncode == 0:
            ok("yt-dlp обновлён")
        else:
            warn("yt-dlp -U не удался (возможно, установлен пакетным менеджером)")
        if output:
            for line in output.splitlines()[-4:]:
                say("         " + line)
    except Exception as exc:  # noqa: BLE001
        warn(f"не удалось обновить yt-dlp: {exc}")


def download_local_ytdlp() -> None:
    if IS_MAC:
        asset = "yt-dlp_macos"
    else:
        machine = platform.machine().lower()
        if machine in ("aarch64", "arm64"):
            asset = "yt-dlp_linux_aarch64"
        else:
            asset = "yt-dlp_linux"
    target = ROOT / "yt-dlp"
    say(f"\n  yt-dlp не найден — скачиваю локальную сборку ({asset}) в корень проекта...")
    url = f"https://github.com/yt-dlp/yt-dlp/releases/latest/download/{asset}"
    if download(url, target, "yt-dlp"):
        make_executable(target)
        ok("Локальный yt-dlp готов (sudo не требуется)")


def make_executable(path: Path) -> None:
    if IS_WINDOWS or not path.is_file():
        return
    try:
        mode = path.stat().st_mode
        path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    except OSError:
        pass


def unix_checks(force: bool, install: bool = True) -> None:
    system = "macOS" if IS_MAC else "Linux"
    head(f"{system}: проверка окружения")

    have_mpv = check_binary("mpv", "mpv")
    have_ytdlp = check_binary("yt-dlp", "yt-dlp")
    have_ffmpeg = check_binary("ffmpeg", "ffmpeg")
    have_tk = tkinter_available()
    if have_tk:
        ok("tkinter (python3-tk) доступен")
    else:
        fail("tkinter не найден — графический лаунчер не запустится")

    whisper_local = WHISPER / "whisper-cli"
    whisper_system = shutil.which("whisper-cli")
    if whisper_local.is_file():
        make_executable(whisper_local)
        ok(f"whisper-cli: {whisper_local}")
    elif whisper_system:
        ok(f"whisper-cli: {whisper_system}")
    else:
        warn("whisper-cli не найден — ИИ-субтитры будут недоступны")
        note("Соберите whisper.cpp: https://github.com/ggml-org/whisper.cpp")
        note("и положите whisper-cli в portable_config/whisper/ или в PATH")

    if IS_MAC:
        brew = shutil.which("brew")
        if brew:
            ok(f"Homebrew: {brew}")
        else:
            fail("Homebrew (brew) не найден")
            note("Установите Homebrew:")
            say('         /bin/bash -c "$(curl -fsSL '
                'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"')
        if not (have_mpv and have_ytdlp and have_tk):
            note("Команда установки:")
            say("         brew install mpv yt-dlp python-tk ffmpeg")
    else:
        if not (have_mpv and have_ytdlp and have_ffmpeg and have_tk):
            note("Команда установки для вашего дистрибутива:")
            for line in linux_install_command().splitlines():
                say("         " + line)
        else:
            ok("Все системные зависимости на месте")

    if not install:
        note("Режим --check: скачивание и обновление пропущены.")
        return

    if not have_ytdlp:
        download_local_ytdlp()
    update_ytdlp()
    download_whisper_model(force)

    # Права +x для скриптов и локальных бинарников.
    for rel in ("launcher.py", "setup.py", "Start_Linux.sh",
                "Start_macOS.command", "portable_config/whisper/ai_subs.sh"):
        make_executable(ROOT / rel)
    if (ROOT / "yt-dlp").is_file():
        make_executable(ROOT / "yt-dlp")
    if (ROOT / "mpv").is_file():
        make_executable(ROOT / "mpv")

    say()
    note("Дальше:  ./Start_Linux.sh   (Linux)")
    note("         ./Start_macOS.command   (macOS)")
    note("или:     python3 launcher.py --config-dir=./portable_config")


# --------------------------------------------------------------------------
#  Windows
# --------------------------------------------------------------------------
def windows_checks(force: bool) -> None:
    head("Windows: проверка и установка компонентов")
    if not tkinter_available():
        fail("tkinter не найден в этом Python. Переустановите Python "
             "с галочкой «tcl/tk and IDLE».")
    else:
        ok("tkinter доступен")
    windows_mpv(force)
    windows_ytdlp(force)
    windows_magpie(force)
    windows_whisper(force)
    download_whisper_model(force)

    say()
    heading = "Готово! Запуск: Start_Windows.bat или Anime4K_Center.vbs"
    say(heading)


# --------------------------------------------------------------------------
#  main
# --------------------------------------------------------------------------
def print_summary(check_only: bool) -> None:
    head("Проверка файлов проекта")
    required = [
        "launcher.py", "launcher.ps1", "Anime4K_Center.vbs",
        "portable_config/mpv.conf", "portable_config/input.conf",
        "portable_config/scripts/yummy_ui.lua",
        "portable_config/scripts/thumbfast.lua",
        "portable_config/shaders/FSRCNNX_x2_16-0-4-1.glsl",
    ]
    for rel in required:
        path = ROOT / rel
        (ok if path.is_file() else fail)(rel)
    say()
    say("  Тяжёлые бинарники и кэш в git не попадают (.gitignore).")
    if check_only:
        note("Режим --check: установка пропущена.")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Anime4K Center — установка зависимостей")
    parser.add_argument("--check", "--check-only", action="store_true",
                        dest="check", help="только проверить окружение")
    parser.add_argument("--force", action="store_true",
                        help="перекачать уже существующие файлы")
    args = parser.parse_args(argv)

    say("Anime4K Center · setup.py")
    say(f"Платформа: {platform.platform()}")
    say(f"Python:    {sys.version.split()[0]}")
    say(f"Папка:     {ROOT}")

    CONFIG.mkdir(parents=True, exist_ok=True)
    WHISPER.mkdir(parents=True, exist_ok=True)

    if IS_WINDOWS:
        if args.check:
            head("Windows: проверка окружения")
            if tkinter_available():
                ok("tkinter доступен")
            else:
                fail("tkinter не найден")
            for rel, label in (
                    ("mpv.exe", "mpv.exe"), ("yt-dlp.exe", "yt-dlp.exe"),
                    ("Magpie/Magpie.exe", "Magpie"),
                    ("portable_config/whisper/whisper-cli.exe", "whisper-cli.exe"),
                    ("portable_config/whisper/ggml-base.bin", "ggml-base.bin")):
                path = ROOT / rel
                (ok if path.is_file() else fail)(label)
        else:
            windows_checks(args.force)
    else:
        if args.check:
            unix_checks(force=False, install=False)
        else:
            unix_checks(args.force)

    print_summary(args.check)
    say()
    say("Готово. Приятного просмотра!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
