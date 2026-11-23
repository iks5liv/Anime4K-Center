#!/usr/bin/env bash
# =========================================================
#  Start_Linux.sh — запуск Anime4K Center на Linux / macOS
#  (также подходит для macOS, но есть и Start_macOS.command)
# =========================================================
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1
chmod +x "$SCRIPT_DIR/Start_Linux.sh" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/portable_config/whisper/ai_subs.sh" 2>/dev/null || true

PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
        # Отсеиваем заглушку Microsoft Store и версии ниже 3.8.
        if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
            PYTHON="$candidate"
            break
        fi
    fi
done

if [ -z "$PYTHON" ]; then
    echo ""
    echo "  [!] Python 3.8+ не найден."
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        echo "      brew install python"
    else
        echo "      Ubuntu/Debian: sudo apt install -y python3 python3-tk"
        echo "      Arch:          sudo pacman -S --needed python tk"
        echo "      Fedora:        sudo dnf install -y python3 python3-tkinter"
    fi
    echo ""
    exit 1
fi

# Проверяем tkinter: без него графический лаунчер не создаст окно.
if ! "$PYTHON" -c 'import tkinter' >/dev/null 2>&1; then
    echo ""
    echo "  [!] Не найден tkinter (пакет python3-tk / python-tk)."
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        echo "      brew install python-tk"
    elif command -v apt >/dev/null 2>&1; then
        echo "      sudo apt update && sudo apt install -y python3-tk"
    elif command -v pacman >/dev/null 2>&1; then
        echo "      sudo pacman -S --needed tk"
    elif command -v dnf >/dev/null 2>&1; then
        echo "      sudo dnf install -y python3-tkinter"
    elif command -v zypper >/dev/null 2>&1; then
        echo "      sudo zypper install -y python3-tk"
    else
        echo "      Установите tkinter штатным менеджером пакетов."
    fi
    echo ""
    exit 1
fi

# mpv: системный из PATH или локальный бинарник в корне проекта.
if ! command -v mpv >/dev/null 2>&1 && [ ! -x "$SCRIPT_DIR/mpv" ]; then
    echo ""
    echo "  [!] mpv не найден. Установите его:"
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        echo "      brew install mpv"
    elif command -v apt >/dev/null 2>&1; then
        echo "      sudo apt install -y mpv"
    elif command -v pacman >/dev/null 2>&1; then
        echo "      sudo pacman -S --needed mpv"
    elif command -v dnf >/dev/null 2>&1; then
        echo "      sudo dnf install -y mpv"
    else
        echo "      через менеджер пакетов вашего дистрибутива."
    fi
    echo "  Лаунчер откроется, но воспроизведение будет недоступно."
    echo ""
fi

# yt-dlp: системный или локальный; без него онлайн-поиск работает не полностью.
if ! command -v yt-dlp >/dev/null 2>&1 && [ ! -x "$SCRIPT_DIR/yt-dlp" ]; then
    echo ""
    echo "  [!] yt-dlp не найден — онлайн-резервный поиск будет ограничен."
    echo "      Запустите:  $PYTHON setup.py"
    echo "      или установите: sudo apt install -y yt-dlp  (пример для Debian/Ubuntu)"
    echo ""
fi

# ffmpeg нужен yt-dlp для склейки потоков и Whisper-обёртке.
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "  [i] ffmpeg не найден в PATH — часть онлайн-потоков может не открыться."
    echo "      Установите: sudo apt install -y ffmpeg  (пример для Debian/Ubuntu)"
    echo ""
fi

echo "  Запуск Anime4K Center..."
exec "$PYTHON" "$SCRIPT_DIR/launcher.py" --config-dir=./portable_config "$@"
