<div align="center">

# 🎬 Anime4K Center

### Cross-Platform AI 4K Media Player & Launcher

**mpv + Anime4K + FSRCNNX + Whisper AI + yt-dlp — wrapped in a modern streaming-service UI.**

[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-6366f1?style=flat-square)](#-installation)
[![mpv](https://img.shields.io/badge/mpv-0.37%2B-691f74?style=flat-square)](https://mpv.io)
[![Python](https://img.shields.io/badge/Python-3.8%2B-3776AB?style=flat-square&logo=python&logoColor=white)](https://python.org)
[![License](https://img.shields.io/badge/license-MIT-22c55e?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/badge/release-v1.0.0-6366f1?style=flat-square)](https://github.com)

**Real-time neural upscaling · 6 shader modes · AI subtitles · audio enhancement · multi-source online search**

[Features](#-features) · [Shader Modes](#-1-neural-4k-upscaling--restoration) · [Hotkeys](#-keyboard-shortcuts) · [Install](#-installation) · [Vivaldi](#-browser-integration-magpie--nvidia-vsr--vivaldi) · [Русский](#-русский)

</div>

---

## 📖 Overview

**Anime4K Center** turns a portable [mpv](https://mpv.io) build into a full home-theater
application. It combines real-time GPU shaders, a cinema-style player interface,
speech-to-text subtitles and online search in one package — on **Windows, Linux
and macOS (Intel and Apple Silicon)**.

It is not a video converter and not a streaming website: playback, shader
switching, quality selection, season/episode navigation and subtitle generation
all happen **live**, while the video is playing.

```text
┌──────────────────────────────────────────────────────────────┐
│  Video title                                          [⚙]    │
│                                   Аудио · Субтитры · Качество│
│  Сезон 2 ▾   [1] [2] [3] [4] [5] [6] [7] [8] …               │
│                                                              │
│                     4K video (Anime4K / FSRCNNX)             │
│                                                              │
│         [ Пропустить заставку ]   [ Пропустить эндинг ]       │
│  ─────────────────────●──────────────────────────────        │
└──────────────────────────────────────────────────────────────┘
```

---

## ✨ Features

| Area | What you get |
|---|---|
| 🧠 **Neural upscaling** | 6 live modes: Anime4K A/B/C, FSRCNNX, Old-Cinema Restoration, Original |
| ⚙️ **Hardware adaptation** | Automatic HQ / Lite shader profile (discrete GPU vs integrated), shader cache, universal hardware decoding |
| 🖥️ **Streaming-style UI** | Top bar with title + Audio / Subtitles / Quality pills, season selector, episode strip, settings menu |
| ⏭️ **Skip buttons** | “Skip intro” / “Skip ending” appear only at the right chapter timings and disappear after use |
| 🖼️ **Timeline previews** | thumbfast hover previews + chapter/episode markers for local files, YouTube, VK Video and RuTube |
| 🗣️ **AI subtitles** | whisper.cpp speech recognition with GPU/CPU fallback, auto-attached SRT |
| 🔊 **Audio FX** | 4 real-time modes: Original, Clear Voice, Bad-Audio Repair, Cinema / Surround |
| 🔎 **Smart search** | AniLiberty, RuTube, yt-dlp (YouTube / VK / Kick / Twitch / sibnet) and an HTML fallback parser |
| 🪟 **Browser upscaling** | Magpie and NVIDIA RTX VSR on Windows — works over Vivaldi, Chrome, Edge and other players |
| 🌍 **Cross-platform** | Windows, Linux, macOS (Intel `/usr/local/bin` and Apple Silicon `/opt/homebrew/bin`) |

---

## 🧠 1. Neural 4K Upscaling & Restoration

All six modes are switched **instantly** with `Ctrl+1 … Ctrl+5` / `Ctrl+0`.
Shaders are applied at render time by mpv’s `gpu-next` (libplacebo) renderer.

| # | Mode | Hotkey | HQ shader chain | Lite fallback | Best for |
|---|------|--------|-----------------|---------------|----------|
| 1 | **Anime4K Mode A — Standard 4K (HQ)** | `Ctrl+1` | Clamp → Restore_CNN_**VL** → Upscale_CNN_x2_**VL** → AutoDownscalePre_x2/x4 → Upscale_CNN_x2_**M** | Restore_CNN_**M** → Upscale_CNN_x2_**M** → Upscale_CNN_x2_**S** | Most modern 1080p anime — crisp, clean line art |
| 2 | **Anime4K Mode B — Anti-Soap 4K (HQ)** | `Ctrl+2` | Clamp → Restore_CNN_**Soft_VL** → Upscale_CNN_x2_**VL** → AutoDownscale ×2/×4 → Upscale_CNN_x2_**M** | Restore_CNN_**Soft_M** → Upscale_CNN_x2_**M** → Upscale_CNN_x2_**S** | Low-bitrate / 720p episodes, “soapy” compression |
| 3 | **Anime4K Mode C — Old / Noisy 4K (HQ)** | `Ctrl+3` | Clamp → Upscale_**Denoise**_CNN_x2_**VL** → AutoDownscale ×2/×4 → Upscale_CNN_x2_**M** | Upscale_Denoise_CNN_x2_**M** → Upscale_CNN_x2_**S** | 1990s–2000s anime, grain and compression artifacts |
| 4 | **Cinema & Series 4K (FSRCNNX)** | `Ctrl+4` | FSRCNNX_x2_16-0-4-1 | — | Live-action films and series — no “cartoon” look |
| 5 | **Old Cinema & Series 4K (Restoration)** | `Ctrl+5` | Clamp → Denoise_Bilateral_Mean → FSRCNNX **+ `vf hqdn3d`** | — | DVD rips, VHS digitizations, old TV series |
| 6 | **Original (No Shaders)** | `Ctrl+0` | — | — | Reference playback, benchmarking, weak PCs |

> **HQ vs Lite is automatic.** The launcher (or `yummy_ui.lua`) classifies the
> GPU and writes `portable_config/gpu_profile.txt`. The hotkey stays the same,
> only the shader weights change — so you can move the folder between a gaming
> desktop and a laptop without editing configs.

### Mode 5 in detail

The restoration preset removes the `vf` filter left by other modes first, then
adds:

```text
lavfi=[hqdn3d=luma_spatial=2.0:chroma_spatial=1.5:luma_tmp=3.0:chroma_tmp=2.5]
```

This soft temporal/spatial denoise is followed by `Anime4K_Denoise_Bilateral_Mean`
and `FSRCNNX_x2_16-0-4-1`, giving clean edges without the plastic look of pure
anime shaders.

---

## ⚙️ 2. Smart Hardware Adaptation

### GPU tiers

`portable_config/gpu_profile.txt` is shared by the launcher and the Lua UI:

```ini
tier=hq
name=NVIDIA GeForce RTX 4070
generated=2026-11-23T18:00:00
```

| Tier | Detected hardware | Shader weights |
|------|-------------------|----------------|
| `hq` | NVIDIA RTX/GTX/Quadro/Tesla, AMD Radeon RX, Intel Arc A/B-series, Apple M1–M4 | `_VL` / `_L` + `_M` |
| `lite` | Intel UHD/Iris, AMD Vega/Radeon Graphics, MX/GT, virtual machines, unknown adapters | `_M` / `_S` |

Detection sources:

- **Windows** — `Win32_VideoController` via PowerShell/WMI;
- **Linux** — `lspci` + `glxinfo -B`;
- **macOS** — `system_profiler SPDisplaysDataType`.

If mpv is started directly, `yummy_ui.lua` performs the same detection itself.
You can override it with `FILMS4K_GPU_TIER` / `FILMS4K_GPU_NAME`.

### Decoding & rendering

| Setting | Value | Why |
|---|---|---|
| `vo` | `gpu-next` | libplacebo renderer, same quality on all vendors |
| `gpu-api` | `auto` | DirectX 11 / Vulkan (Windows), Vulkan / OpenGL (Linux), Metal (macOS) |
| `hwdec` | `auto-safe` | NVDEC, D3D11VA/DXVA2, VAAPI/VDPAU, VideoToolbox — with safe CPU fallback |
| `gpu-shader-cache` | `yes` | Compiled GLSL binaries cached in `portable_config/shader_cache/`; no black frame on restart |
| `vd-lavc-threads` | `4` | Enough for 4K HEVC/AVC without starving the UI script |
| `scale` / `cscale` | `ewa_lanczossharp` | High-quality luma/chroma scaling |
| `deband` | `yes` | Removes banding in skies and dark scenes |

---

## 🖥️ 3. Streaming-Style Player UI

Implemented in `portable_config/scripts/yummy_ui.lua` (≈180 KB of Lua) on top of
mpv’s ASS/OSD overlay system. The built-in OSC is disabled (`osc=no`).

### Top bar

- **Title** on the left, read from media metadata.
- **Three selector pills** on the right:
  - **Аудио · …** — switch audio track / dub (language + codec shown);
  - **Субтитры · …** — enable/disable, pick a track, or **✨ Generate AI subtitles**;
  - **Качество · …** — real quality switching for online streams (1080 / 720 / 480),
    shows the *actual* decoded resolution and adapts the label for vertical
    “Shorts”-style videos.

### Seasons and episodes

- **Season selector** `Сезон N ▾` appears only for multi-season releases.
- **Episode strip** `1 2 3 … N` with active-episode highlight and protection
  against cyclic scrolling.
- Choosing an episode rebuilds the playlist and starts playback immediately.

### Skip buttons

- **«Пропустить заставку»** and **«Пропустить эндинг / След. серия»**.
- They are shown **only** when the current chapter matches intro/ending names
  and timings, and disappear after a click, after the chapter ends, or when the
  user seeks away.

### Timeline previews

- **thumbfast** generates hover previews in a background mpv process.
- Chapter and episode markers are drawn on the seek bar.
- Works for **local files, YouTube, VK Video and RuTube**.
- The background process exits after 60 s of inactivity to release VRAM and is
  re-spawned automatically on the next hover.

### Settings menu (⚙)

- Compact card with sections: shader modes, **ЗВУК** (audio), GPU info,
  AI subtitles, playback options.
- OSD notifications auto-hide after **2 seconds** (`osd-duration=2000`).
- The whole panel hides after ~2.5 s of mouse inactivity.

---

## 🗣️ 4. AI Subtitles (whisper.cpp)

Generate subtitles for **local files** without leaving the player:

1. Open **Субтитры → ✨ Сгенерировать ИИ-субтитры** (or send the
   `ai-subs` script message).
2. The wrapper extracts a **16 kHz mono WAV** with mpv.
3. `whisper-cli` runs with `ggml-base.bin`:
   - **NVIDIA + CUDA** → GPU;
   - **macOS** → Metal build if available;
   - otherwise → CPU (`--no-gpu`), so missing CUDA libraries never break it.
4. The finished `.srt` is attached automatically.

Output files next to the video:

| File | Meaning |
|---|---|
| `<video>.ai.srt` | Generated subtitles |
| `<video>.ai.done` | Marker with `rc`, `ok`, `srt` |
| `<video>.ai.log` | Wrapper log for troubleshooting |

Wrappers: `portable_config/whisper/ai_subs.vbs` (Windows) and
`portable_config/whisper/ai_subs.sh` (Linux / macOS, POSIX).

---

## 🔊 5. Real-Time Audio Enhancement

Four modes, switchable from the settings menu or with hotkeys. Implemented as
live FFmpeg `af` filter chains:

| Mode | Hotkeys | DSP chain | Effect |
|------|---------|-----------|--------|
| **Original** | `Alt+5` / `Alt+1` | *(none)* | Bit-perfect source audio |
| **Clear Voice** | `Alt+6` / `Alt+2` | `pan` (center extraction) → `highpass=120` → `lowpass=7500` → `acompressor` | Suppresses background music/SFX, lifts dialogue |
| **Bad-Audio Repair** | `Alt+7` / `Alt+3` | `highpass=80` → `lowpass=14000` → `afftdn` → `dynaudnorm` | Removes hiss/hum, evens out quiet rips |
| **Cinema / Surround** | `Alt+8` / `Alt+4` | `dynaudnorm` → `equalizer 65 Hz` → `equalizer 12 kHz` | Wider, louder, “big screen” sound |

> `Alt+1…Alt+4` are aliases for laptops where the top function row is occupied.
> The classic `Alt+5…Alt+8` keep working.

---

## 🔎 6. Launchers & Smart Online Search

Two interchangeable front-ends with the same design language
(`#18181b` / `#27272a` / `#6366f1`):

| Launcher | Platform | Notes |
|---|---|---|
| `launcher.ps1` + `online_parser.ps1` + `Anime4K_Center.vbs` | Windows | Classic native UI, no Python required |
| `launcher.py` (tkinter) | Windows, Linux, macOS | Full cross-platform port, same 6 modes and workflow |

### What the launcher does

- **Paste a link or type a title** — it decides what to do:
  - direct stream (`.m3u8`, `.mp4`, YouTube, VK Video, RuTube, Kick, Twitch,
    sibnet.ru) → plays immediately;
  - anime catalog page → extracts the title and searches AniLiberty;
  - film/series → searches RuTube, then adds YouTube variants.
- **Variant picker** — dubs, seasons, episode counts, durations, qualities.
- **Playlist builder** — writes `temp_playlist*.m3u8`,
  `temp_playlist_meta.json` and, for multi-season shows,
  `portable_config/season_manifest.json`.
- **Background search** — the Python UI searches in a worker thread, so the
  window never freezes.

### Search sources

| Source | What it provides |
|---|---|
| **AniLiberty API** | Release search, seasons, franchise tree, dubs, 1080/720/480 HLS |
| **RuTube API** | Video search with duration filter (clips/trailers/streams under 20 min are rejected), chapters |
| **yt-dlp** | Direct links and playlists: YouTube, VK Video, RuTube, Kick, Twitch, sibnet.ru and other supported sites |
| **HTML fallback** | If APIs return nothing, the page and its iframes are parsed for direct `m3u8` / `mp4` links |
| **Kinopoisk links** | Recognized, but DRM/SSO-protected pages are reported instead of failing silently |

Cloudflare challenges, anti-bot stubs, Widevine DRM and Kinopoisk SSO produce a
clear message with a suggestion to open the video in a browser —
**DRM is never bypassed**.

---

## ⌨️ Keyboard Shortcuts

### Shader modes

| Keys | Action |
|---|---|
| `Ctrl+1` | Anime4K Mode A — Standard 4K (HQ) |
| `Ctrl+2` | Anime4K Mode B — Anti-Soap 4K (HQ) |
| `Ctrl+3` | Anime4K Mode C — Old / Noisy 4K (HQ) |
| `Ctrl+4` | Cinema & Series 4K (FSRCNNX) |
| `Ctrl+5` | Old Cinema & Series 4K (Restoration) |
| `Ctrl+0` | Original — no shaders |

### Audio

| Keys | Action |
|---|---|
| `Alt+5` / `Alt+1` | Sound: Original |
| `Alt+6` / `Alt+2` | Sound: Clear Voice |
| `Alt+7` / `Alt+3` | Sound: Bad-Audio Repair |
| `Alt+8` / `Alt+4` | Sound: Cinema / Surround |

### Subtitles & navigation

| Keys | Action |
|---|---|
| `v` | Toggle subtitles (CC), OSD in the top-left corner |
| `j` | Cycle to the next subtitle track |
| `PgUp` | Next chapter / episode |
| `PgDn` | Previous chapter / episode |

### Standard mpv controls (kept intact)

| Keys | Action |
|---|---|
| `Space` or `p` | Play / pause |
| `←` / `→` | Seek −5 s / +5 s |
| `↑` / `↓` | Seek +60 s / −60 s |
| `Shift+←` / `Shift+→` | Precise seek ∓1 s |
| `f` | Toggle fullscreen |
| `#` | Cycle audio tracks (mpv default) |
| `s` | Screenshot (with subtitles) |
| `S` | Screenshot without subtitles |
| `m` | Mute |
| `9` / `0` | Volume − / + |
| `i` | Playback statistics |
| `o` | Toggle OSD |
| `q` | Quit |

### Launcher

| Keys | Action |
|---|---|
| `Ctrl+V` | Paste a link from the clipboard |
| `Enter` | Run the online search from the input field |

### Mouse

| Action | Result |
|---|---|
| Hover the timeline | Preview frame + chapter name + exact time |
| Click `Аудио` / `Субтитры` / `Качество` | Open the corresponding selector |
| Click `Сезон N ▾` | Switch season |
| Click an episode tile | Jump to that episode |
| Click `⚙` | Open settings (shaders, audio, GPU, AI subtitles) |
| Click skip buttons | Skip intro / ending |

---

## 🚀 Installation

### Requirements

- **mpv** 0.37+ (0.38+ recommended, `gpu-next` support)
- **yt-dlp** — online search and streaming
- **ffmpeg** — stream merging, thumbnails, audio extraction
- **Python 3.8+ with tkinter** — only for the cross-platform `launcher.py`
- **whisper-cli + `ggml-base.bin`** — only for AI subtitles

`python setup.py` downloads the Windows binaries automatically. On Linux/macOS
it checks the system packages and prints the exact install command for your
distribution.

### 🪟 Windows

1. Unpack the project into any folder (for example `D:\Anime4K`).
2. Update components (optional, files are not overwritten unless `--force`):

   ```bat
   python setup.py
   ```

   Downloads `mpv.exe` (fresh `shinchiro/mpv-winbuild-cmake` build, `.7z`
   extracted with Windows `tar.exe` or 7-Zip), `yt-dlp.exe`, Magpie,
   `whisper-cli.exe` and the Whisper model.
3. Start:

   ```bat
   Start_Windows.bat          :: classic native UI (no console)
   Start_Windows.bat --py     :: cross-platform Python UI
   ```

   `Start_Windows.bat` uses `Anime4K_Center.vbs` by default, so no console
   window flashes. Python is only required for the `--py` mode.

### 🐧 Linux

```bash
# Debian / Ubuntu / Mint
sudo apt update
sudo apt install -y mpv yt-dlp ffmpeg python3 python3-tk

# Arch / Manjaro
sudo pacman -S --needed mpv yt-dlp ffmpeg python tk

# Fedora (RPM Fusion may be required for mpv/ffmpeg)
sudo dnf install -y mpv yt-dlp ffmpeg python3 python3-tkinter

# openSUSE
sudo zypper install -y mpv yt-dlp ffmpeg python3-tk
```

```bash
python3 setup.py
chmod +x Start_Linux.sh portable_config/whisper/ai_subs.sh
./Start_Linux.sh
```

`setup.py` reads `/etc/os-release`, suggests the right command, and can download
a local `yt-dlp` into the project root without `sudo`.

### 🍎 macOS (Intel & Apple Silicon M1–M4)

```bash
brew install mpv yt-dlp ffmpeg python python-tk
python3 setup.py
chmod +x Start_macOS.command portable_config/whisper/ai_subs.sh
./Start_macOS.command
```

Or simply **double-click `Start_macOS.command` in Finder**.

Homebrew paths are handled automatically:

| Mac | Homebrew prefix |
|---|---|
| Apple Silicon (M1–M4) | `/opt/homebrew/bin` |
| Intel | `/usr/local/bin` |

Both `Start_macOS.command`, `launcher.py` and `setup.py` add **both** directories
to `PATH`, so Finder launches (which get a minimal environment) work correctly.

If macOS quarantines the file after download: right-click → **Open**, or

```bash
xattr -d com.apple.quarantine Start_macOS.command
```

On Apple Silicon mpv uses **Metal** and **VideoToolbox**; whisper.cpp uses Metal.

### `--config-dir` on Unix

Windows mpv automatically looks for `portable_config` next to the binary.
Linux/macOS do not, so the launchers always pass:

```bash
python3 launcher.py --config-dir=./portable_config
```

---

## 🪟 Browser Integration: Magpie / NVIDIA VSR / Vivaldi

Anime4K Center also helps when you watch in a browser tab.

### Magpie (Windows)

- Magpie upscales **any window**, including **Vivaldi**, Chrome, Edge and Firefox.
- Launch `Magpie/Magpie.exe`, select the Vivaldi window, press the configured
  hotkey (default `Win+Shift+A`) to toggle scaling.
- Useful for sites that block embedding: watch in the browser, upscale the
  window to 4K.

### NVIDIA RTX Video Super Resolution (Windows, RTX 20/30/40/50)

- NVIDIA Control Panel → **Adjust video image settings** → enable
  **RTX video enhancement / Super Resolution**.
- Works in Chromium-based browsers, including **Vivaldi**.
- No project files are modified; the launcher simply exposes a shortcut card on
  Windows and an informational card on Linux/macOS.

### Cookies for online search (Vivaldi)

Some sites require a logged-in session. The launcher automatically passes a
`cookies.txt` file from the project root to yt-dlp when it exists.

Generate it from Vivaldi in either way:

```bash
# yt-dlp can read Vivaldi's Chromium cookie store directly
yt-dlp --cookies-from-browser vivaldi --cookies cookies.txt "URL"
```

or export cookies with any “Get cookies.txt LOCALLY”-style extension
(Netscape format) and save the file as `cookies.txt` next to `launcher.py`.

> Cookies are personal data: `cookies.txt` is already listed in `.gitignore`.

**DRM note:** Vivaldi and Chromium use Widevine. Anime4K Center does **not**
bypass DRM — protected Kinopoisk/Netflix-style pages show an explanatory message.

---

## 📁 Project Structure

```text
Anime4K-Center/
├── launcher.py                 # Cross-platform tkinter launcher
├── launcher.ps1                # Native Windows launcher
├── online_parser.ps1           # Search backend for the Windows launcher
├── Anime4K_Center.vbs          # Console-free Windows entry point
├── setup.py                    # Dependency installer / checker (stdlib only)
├── Start_Windows.bat           # Windows launcher (CRLF)
├── Start_Linux.sh              # Linux launcher (LF)
├── Start_macOS.command         # macOS launcher (LF, double-click)
├── LICENSE                     # MIT License (project code)
├── NOTICE                      # Third-party components and their licenses
├── README.md
├── .gitignore
├── .gitattributes
├── mpv-register.bat            # Optional file-association helpers
├── mpv-unregister.bat
├── updater.bat
├── mpv/
│   └── fonts.conf              # Fontconfig defaults for portable mpv
└── portable_config/
    ├── mpv.conf                # Video, audio, network, subtitle, GPU options
    ├── input.conf              # Hotkeys
    ├── ca-bundle.crt           # CA bundle for Windows TLS
    ├── script-opts/
    │   └── thumbfast.conf
    ├── scripts/
    │   ├── yummy_ui.lua        # Player UI, modes, audio FX, AI subtitles
    │   └── thumbfast.lua       # Timeline previews
    ├── shaders/                # Anime4K, FSRCNNX and helper GLSL (40 files)
    ├── whisper/
    │   ├── ai_subs.vbs         # Windows AI-subtitle wrapper
    │   └── ai_subs.sh          # POSIX AI-subtitle wrapper
    ├── shader_cache/           # generated — ignored by git
    └── watch_later/            # generated — ignored by git
```

Binaries (`mpv.exe`, `mpv.com`, `yt-dlp.exe`, `Magpie/`, Whisper DLLs and
models) are **not** stored in the repository. `python setup.py` downloads them.

---

## 🧩 GPU Profile Format

```ini
tier=hq
name=NVIDIA GeForce RTX 4070
generated=2026-11-23T18:00:00
```

- `tier=hq` → `_VL` / `_L` shader weights;
- `tier=lite` → `_M` / `_S` shader weights;
- `FILMS4K_GPU_TIER` and `FILMS4K_GPU_NAME` override detection;
- the file is recreated by the launcher on every start and is git-ignored.

---

## 🛠️ Troubleshooting

| Symptom | Fix |
|---|---|
| “mpv not found” | Run `python setup.py`, or install mpv and add it to `PATH` |
| Online search finds nothing | Check the network, run `yt-dlp -U`, try a direct link, update `cookies.txt` |
| Black screen / no video | Change `gpu-api` in `mpv.conf` (`auto` → `opengl` or `vulkan`) |
| 4K stutters | The GPU was classified as `hq` by mistake — set `tier=lite` in `gpu_profile.txt` |
| No timeline previews | Check `script-opts/thumbfast.conf` and that `mpv` is in `PATH` |
| AI subtitles missing | Read `<video>.ai.log`; check `whisper-cli` and `ggml-base.bin` |
| No window on Linux | Install `python3-tk`, then `./Start_Linux.sh` |
| macOS says “Python not found” | `brew install python python-tk` |
| macOS blocks `Start_macOS.command` | Right-click → Open, or remove quarantine with `xattr` |
| mpv download fails on Windows | Install 7-Zip or use Windows 10/11 `tar.exe`; manual builds: [shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake/releases) |
| Subtitles look wrong | Edit the `sub-*` block in `portable_config/mpv.conf` |
| Vivaldi video needs login | Export `cookies.txt` (see the Vivaldi section) |

---

## 📦 Single-File Build (PyInstaller)

```bash
pip install pyinstaller

# Windows
pyinstaller --noconfirm --onedir --windowed ^
  --name "Anime4K Center" ^
  --icon icon.ico ^
  --add-data "portable_config;portable_config" ^
  launcher.py

# Linux / macOS
pyinstaller --noconfirm --onedir --windowed \
  --name "Anime4K Center" \
  --add-data "portable_config:portable_config" \
  launcher.py
```

`--onedir` is recommended: `portable_config`, mpv, yt-dlp and Whisper stay next
to the executable and are found automatically. For `--onefile`, ship the config
and binaries separately and start with `--config-dir=<path>`.

macOS signing / packaging:

```bash
codesign --deep --force -s - "dist/Anime4K Center.app"
hdiutil create -volname "Anime4K Center" -srcfolder "dist/Anime4K Center.app" \
  -ov -format UDZO "Anime4K-Center.dmg"
```

---

## 🤝 Credits & Third-Party Licenses

| Component | Author / Project | License |
|---|---|---|
| mpv | mpv team / shinchiro builds | GPL-2.0+/LGPL-2.1+ |
| Anime4K | bloc97 | MIT |
| FSRCNNX | igv / community | MIT |
| yt-dlp | yt-dlp contributors | Unlicense |
| whisper.cpp | ggml-org | MIT |
| thumbfast | po5 | MPL-2.0 |
| Magpie | Blinue | MIT |
| FFmpeg | FFmpeg team | LGPL-2.1+ / GPL-2.0+ |

The **project code** is released under the **MIT License** — see [LICENSE](LICENSE).
Third-party components keep their own licenses — the full list with links is in
[NOTICE](NOTICE).

---

## 🇷🇺 Русский

**Anime4K Center** — кроссплатформенный медиаплеер и лаунчер на базе **mpv** с
нейросетевым 4K-апскейлом в реальном времени, интерфейсом в стиле онлайн-кинотеатров,
ИИ-субтитрами, улучшением звука и умным онлайн-поиском.

### Ключевые возможности

- **6 режимов обработки**: Anime4K A (чёткость линий), B (против «мыла»),
  C (старое/шумное аниме), FSRCNNX (кино), Реставрация старого кино
  (`hqdn3d` + денойз), Оригинал без шейдеров.
- **Автоопределение GPU**: `hq` → `_VL`/`_L`, `lite` → `_M`/`_S`;
  кэш шейдеров, `hwdec=auto-safe`, `gpu-api=auto`.
- **Интерфейс плеера**: верхняя панель с названием и плашками
  **Аудио / Субтитры / Качество** (реальное переключение разрешения онлайн),
  селектор сезонов, лента серий, кнопки **«Пропустить заставку»** и
  **«Пропустить эндинг»**, превью-кадры thumbfast, меню **⚙**, OSD на 2 секунды.
- **ИИ-субтитры** whisper.cpp с автоматическим GPU/CPU-фолбэком,
  файлы `.ai.srt`, `.ai.done`, `.ai.log`.
- **4 режима звука**: Оригинал, Четкий голос, Улучшение плохого звука,
  Кинотеатр/Объёмный (`Alt+5…8` и дубли `Alt+1…4`).
- **Поиск**: AniLiberty, RuTube, yt-dlp (YouTube, VK Видео, Kick, Twitch,
  sibnet.ru), HTML-резерв; DRM/Cloudflare не обходятся — выводится понятное
  сообщение.
- **Браузер**: Magpie и NVIDIA RTX VSR на Windows работают поверх **Vivaldi**,
  Chrome, Edge и других окон.

### Быстрый старт

**Windows**

```bat
python setup.py
Start_Windows.bat          :: классический интерфейс
Start_Windows.bat --py     :: Python-интерфейс
```

**Linux**

```bash
sudo apt install -y mpv yt-dlp ffmpeg python3 python3-tk
python3 setup.py
chmod +x Start_Linux.sh portable_config/whisper/ai_subs.sh
./Start_Linux.sh
```

**macOS** (Intel и Apple Silicon M1–M4)

```bash
brew install mpv yt-dlp ffmpeg python python-tk
python3 setup.py
chmod +x Start_macOS.command portable_config/whisper/ai_subs.sh
./Start_macOS.command
```

Homebrew-пути `/opt/homebrew/bin` (M1–M4) и `/usr/local/bin` (Intel)
подставляются автоматически. На Unix лаунчер всегда передаёт
`--config-dir=./portable_config`.

### Горячие клавиши (кратко)

| Клавиши | Действие |
|---|---|
| `Ctrl+1…5` | Режимы шейдеров Anime4K / FSRCNNX / Реставрация |
| `Ctrl+0` | Оригинал без шейдеров |
| `Alt+5…8` / `Alt+1…4` | 4 режима звука |
| `v` / `j` | Субтитры вкл-выкл / следующая дорожка |
| `PgUp` / `PgDn` | Следующая / предыдущая глава или серия |
| `Space`, `f`, `s`, `#` | Пауза, полный экран, скриншот, аудиодорожка |
| `Ctrl+V`, `Enter` | Вставить ссылку, запустить поиск (в лаунчере) |

### Важно для Vivaldi

- Для сайтов с авторизацией положите `cookies.txt` (Netscape) в корень проекта
  или используйте `yt-dlp --cookies-from-browser vivaldi`.
- Magpie и NVIDIA RTX VSR включаются в Windows и работают с окном Vivaldi.
- DRM (Widevine) не обходится.

---

<div align="center">

**Anime4K Center v1.0.0** · Made with ❤️ for anime and movies

[⬆ Back to top](#-anime4k-center)

</div>
