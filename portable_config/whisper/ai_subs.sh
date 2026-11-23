#!/bin/sh
# =========================================================
#  ai_subs.sh - AI subtitles for yummy_ui.lua (Linux / macOS)
#  Extracts a 16 kHz mono WAV with mpv, then runs whisper-cli.
#  Uses GPU acceleration when available, otherwise CPU fallback.
#  Args: media wav prefix marker log [lang]
# =========================================================
set -u

if [ "$#" -lt 5 ]; then
    exit 2
fi

media=$1
wav=$2
prefix=$3
marker=$4
logf=$5
lang=${6:-auto}
srt="$prefix.srt"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

log() {
    printf '%s\n' "$*" >>"$logf" 2>/dev/null || true
}

# Ищет бинарник сначала в portable_config/whisper, затем в корне проекта,
# затем в системном PATH. Локальные файлы должны иметь права +x.
find_tool() {
    name=$1
    for dir in "$script_dir" "$root" ""; do
        if [ -n "$dir" ]; then
            cand="$dir/$name"
        else
            cand=$(command -v "$name" 2>/dev/null || true)
        fi
        if [ -n "$cand" ] && [ -f "$cand" ] && [ -x "$cand" ]; then
            printf '%s' "$cand"
            return 0
        fi
    done
    return 1
}

mpv_bin=$(find_tool mpv || true)
whisper_bin=$(find_tool whisper-cli || true)
model="$script_dir/ggml-base.bin"
if [ ! -f "$model" ] && [ -f "$root/ggml-base.bin" ]; then
    model="$root/ggml-base.bin"
fi

log "start $(date 2>/dev/null || echo now)"
log "media: $media"

if [ -z "$mpv_bin" ]; then
    log "ERROR: mpv not found (install mpv or put the binary in the project root)"
elif [ -z "$whisper_bin" ]; then
    log "ERROR: whisper-cli not found (portable_config/whisper, project root or PATH)"
elif [ ! -f "$model" ]; then
    log "ERROR: model not found: $model"
else
    rm -f "$marker" "$wav" "$srt" 2>/dev/null || true

    # 1) Извлекаем звук в 16 кГц mono WAV.
    "$mpv_bin" --no-config --really-quiet --no-video \
        --audio-samplerate=16000 --audio-channels=mono \
        --o="$wav" "$media" >/dev/null 2>&1
    rc=$?
    log "extract rc=$rc"

    if [ "$rc" -ne 0 ] || [ ! -f "$wav" ]; then
        log "ERROR: audio extraction failed"
        rc=-1
    else
        # 2) Распознавание речи.
        cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
        case "$cpus" in
            ''|*[!0-9]*) cpus=4 ;;
        esac

        os_name=$(uname -s 2>/dev/null || echo Linux)
        gpu=0
        if [ "$os_name" = "Darwin" ]; then
            # На macOS whisper.cpp обычно собран с Metal.
            gpu=1
        elif command -v nvidia-smi >/dev/null 2>&1; then
            gpu=1
        fi

        if [ "$gpu" -eq 1 ]; then
            log "GPU: acceleration enabled"
            "$whisper_bin" -m "$model" -f "$wav" -l "$lang" -t "$cpus" \
                -osrt -of "$prefix" >>"$logf" 2>&1
            rc=$?
            log "whisper rc=$rc"
            if [ "$rc" -ne 0 ] || [ ! -f "$srt" ]; then
                log "acceleration failed, retrying with --no-gpu"
                rm -f "$srt" 2>/dev/null || true
                "$whisper_bin" -m "$model" -f "$wav" -l "$lang" -t "$cpus" \
                    -osrt -of "$prefix" --no-gpu >>"$logf" 2>&1
                rc=$?
                log "whisper CPU rc=$rc"
            fi
        else
            log "GPU: not detected, using CPU (--no-gpu)"
            "$whisper_bin" -m "$model" -f "$wav" -l "$lang" -t "$cpus" \
                -osrt -of "$prefix" --no-gpu >>"$logf" 2>&1
            rc=$?
            log "whisper rc=$rc"
        fi

        if [ "$rc" -eq 0 ] && [ -f "$srt" ]; then
            ok=1
        else
            ok=0
            log "ERROR: no srt produced"
        fi
    fi
fi

rm -f "$wav" 2>/dev/null || true

{
    printf 'rc=%s\n' "${rc:--1}"
    printf 'ok=%s\n' "${ok:-0}"
    printf 'srt=%s\n' "$srt"
} >"$marker" 2>/dev/null || true

exit 0
