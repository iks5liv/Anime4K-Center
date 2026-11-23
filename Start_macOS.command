#!/bin/bash
# =========================================================
#  Start_macOS.command — двойной клик в Finder для запуска
#  Anime4K Center на macOS (использует системный Python 3).
# =========================================================
set -u

# Homebrew: Apple Silicon (M1–M4) — /opt/homebrew/bin,
# Intel Mac — /usr/local/bin. Finder запускает .command с урезанным PATH,
# поэтому добавляем оба каталога явно.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1
chmod +x "$SCRIPT_DIR/Start_macOS.command" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/portable_config/whisper/ai_subs.sh" 2>/dev/null || true

if ! command -v brew >/dev/null 2>&1; then
    echo ""
    echo "  [!] Homebrew не найден. Установите его:"
    echo '      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    echo ""
fi

PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
        if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
            PYTHON="$candidate"
            break
        fi
    fi
done

if [ -z "$PYTHON" ]; then
    echo "  [!] Python 3.8+ не найден. Установите: brew install python"
    read -r -p "Нажмите Enter, чтобы закрыть..." _ || true
    exit 1
fi

if ! "$PYTHON" -c 'import tkinter' >/dev/null 2>&1; then
    echo "  [!] Не найден tkinter. Установите: brew install python-tk"
    read -r -p "Нажмите Enter, чтобы закрыть..." _ || true
    exit 1
fi

if ! command -v mpv >/dev/null 2>&1 && [ ! -x "$SCRIPT_DIR/mpv" ]; then
    echo "  [!] mpv не найден. Установите: brew install mpv"
    echo "  Лаунчер откроется, но воспроизведение будет недоступно."
fi

if ! command -v yt-dlp >/dev/null 2>&1 && [ ! -x "$SCRIPT_DIR/yt-dlp" ]; then
    echo "  [i] yt-dlp не найден. Запустите: $PYTHON setup.py"
fi

exec "$PYTHON" "$SCRIPT_DIR/launcher.py" --config-dir=./portable_config "$@"
