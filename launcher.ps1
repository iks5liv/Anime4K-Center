param([switch]$SmokeTest)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- paths
$script:root      = Split-Path -Parent $PSCommandPath
$script:mpvPath   = Join-Path $script:root 'mpv.exe'
$script:shaderDir = Join-Path $script:root 'portable_config\shaders'
$script:magpie    = Join-Path $script:root 'Magpie\Magpie.exe'
$script:parser    = Join-Path $script:root 'online_parser.ps1'
$script:manifest  = Join-Path $script:root 'portable_config\season_manifest.json'
$script:meta      = Join-Path $script:root 'temp_playlist_meta.json'
# Кэш профиля GPU: его читают yummy_ui.lua и mpv при прямом запуске.
$script:gpuProfile = Join-Path $script:root 'portable_config\gpu_profile.txt'
$script:gpuTier    = 'hq'
$script:gpuName    = 'не определена'

# Дочерний парсер запускается много раз за сессию: путь к powershell.exe
# ищем один раз, а не через Get-Command на каждый поиск.
try { $script:psExe = (Get-Command powershell.exe -ErrorAction Stop).Source }
catch { $script:psExe = 'powershell.exe' }

# Предкомпилированные регулярки: Test-DirectUrl/Get-EpisodeLabel вызываются
# на каждую введённую ссылку и на каждую серию списка (десятки раз).
$script:rxHttp      = [regex]::new('^(?i)https?://')
$script:rxDirectExt = [regex]::new('(?i)\.(m3u8|mp4|mkv|webm)(\?|#|$)')
$script:rxSxxExx    = [regex]::new('^(?i)S\d+E\d+')
$script:rxEpNumber  = [regex]::new('(?i)(?:серия|серии|эпизод|episode|ep\.?)\s*[№#]?\s*(\d{1,4})')
$script:rxEpPlain   = [regex]::new('^(?i)(серия|эпизод)\s*[№#]?\s*\d+\s*$')
$script:rxSxxExxEnd = [regex]::new('^(?i)S\d+E\d+$')
# HashSet: проверка хоста O(1) вместо перебора массива на каждый вызов.
$script:directHosts = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($d in @('youtube.com', 'youtu.be', 'vk.com', 'vk.ru', 'vkvideo.ru', 'rutube.ru',
                 'kick.com', 'twitch.tv', 'sibnet.ru')) {
    [void]$script:directHosts.Add($d)
}

# ---------------------------------------------------------------- colours
function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }

$colBg       = C '#18181b'
$colCard     = C '#27272a'
$colField    = C '#3f3f46'
$colFieldHi  = C '#52525b'
$colAccent   = C '#6366f1'
$colAccentHi = C '#4f46e5'
$colText     = C '#ffffff'
$colMuted    = C '#a1a1aa'
$colSubtle   = C '#71717a'

$fontBase  = New-Object System.Drawing.Font('Segoe UI', 9.5)
$fontSmall = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fontBold  = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$fontCard  = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
$fontTitle = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
$fontBig   = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$fontBtn   = New-Object System.Drawing.Font('Segoe UI', 10)

# ---------------------------------------------------------------- helpers
function New-Lbl([string]$text, [int]$x, [int]$y, [int]$w, $font, $fore) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Font = $font
    $l.ForeColor = $fore
    $l.BackColor = [System.Drawing.Color]::Transparent
    if ($w -le 0) {
        $l.AutoSize = $true
    } else {
        $l.AutoSize = $false
        $l.Size = New-Object System.Drawing.Size($w, 22)
    }
    return $l
}

function New-Btn([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $back, $hover, $font, $fore, [int]$border = 0, [string]$borderColor = '#52525b') {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.BackColor = $back
    $b.ForeColor = $fore
    $b.Font = $font
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = $border
    if ($border -gt 0) { $b.FlatAppearance.BorderColor = (C $borderColor) }
    $b.FlatAppearance.MouseOverBackColor = $hover
    $b.FlatAppearance.MouseDownBackColor = $hover
    $b.UseVisualStyleBackColor = $false
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

function New-Card([int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size(890, $h)
    $p.BackColor = $colCard
    $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
    return $p
}

function Show-Error([string]$msg) {
    [System.Windows.Forms.MessageBox]::Show($msg, 'Anime4K Center', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
}

function Show-Info([string]$msg) {
    [System.Windows.Forms.MessageBox]::Show($msg, 'Anime4K Center', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

# ---------------------------------------------------------------- GPU profile
# Определяет класс видеокарты один раз при старте лаунчера. Мощные дискретные
# карты (NVIDIA RTX/GTX, AMD Radeon RX >= 4 ГБ, Intel Arc) получают HQ-шейдеры
# _VL/_L; встроенная и офисная графика (Intel UHD/Iris, AMD Vega/Radeon
# Graphics, NVIDIA MX/GT) — облегчённые _M/_S, чтобы 4K не лагал.
function Test-GpuHighEnd([string]$name, [int64]$vram) {
    if (-not $name) { return $false }
    $n = $name.ToLowerInvariant()
    # Виртуальные/удалённые адаптеры не считаем игровой видеокартой.
    if ($n -match 'microsoft basic|remote display|virtual|vmware|virtualbox|parsec|citrix|sunshine|meta virtual') { return $false }
    if ($n -match 'nvidia|geforce|quadro|tesla|titan') {
        # RTX / GTX / Quadro / Tesla / Titan — дискретные игровые и рабочие.
        # MX и GT (офисные/ноутбучные) остаются в лёгком профиле.
        return [bool]($n -match 'rtx|gtx|quadro|tesla|titan')
    }
    if ($n -match 'amd|radeon|firepro') {
        if ($n -match 'radeon\s*rx|rx\s*\d|firepro|radeon\s*pro|radeon\s*vii|radeon\s*r9|radeon\s*r7') {
            # WMI AdapterRAM — uint32 и «упирается» в 4 ГБ у карт с 8/16 ГБ,
            # поэтому 3.5 ГБ уже считаем дискретной картой с 4+ ГБ.
            if ($vram -ge 3500MB) { return $true }
            # RX 5000/6000/7000 — заведомо мощные независимо от отчёта WMI.
            if ($n -match 'rx\s*[567]\d{3}') { return $true }
        }
        return $false
    }
    if ($n -match 'intel') {
        # Дискретная Intel Arc: A770/A750/B580…; встроенная называется
        # «Intel Arc Graphics» без индекса A/B и остаётся в лёгком профиле.
        if ($n -match 'arc' -and ($n -match '[ab]\d{3}' -or $n -match 'arc.*pro')) { return $true }
        return $false
    }
    return $false
}

function Resolve-GpuProfile {
    $names  = New-Object System.Collections.Generic.List[string]
    $isHigh = $false
    $gpus   = @()
    try {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
    } catch {
        try { $gpus = @(Get-WmiObject -Class Win32_VideoController -ErrorAction Stop) } catch { $gpus = @() }
    }
    foreach ($g in $gpus) {
        if (-not $g) { continue }
        $name = [string]$g.Name
        if (-not $name) { continue }
        $status = ''
        try { $status = [string]$g.Status } catch { }
        if ($status -and $status -ne 'OK') { continue }
        $vram = 0
        try { $vram = [int64]$g.AdapterRAM } catch { $vram = 0 }
        if ($vram -lt 0) { $vram = 0 }
        [void]$names.Add($name)
        if (Test-GpuHighEnd $name $vram) { $isHigh = $true }
    }
    if ($isHigh) { $script:gpuTier = 'hq' } else { $script:gpuTier = 'lite' }
    if ($names.Count -gt 0) { $script:gpuName = ($names -join ' + ') } else { $script:gpuName = 'не определена' }
    # Профиль доступен и при прямом запуске mpv.exe (без лаунчера).
    try {
        $stamp = (Get-Date).ToString('s')
        $text  = "tier=$script:gpuTier`r`nname=$script:gpuName`r`ngenerated=$stamp`r`n"
        [System.IO.File]::WriteAllText($script:gpuProfile, $text, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    # Дочерний mpv наследует переменные окружения лаунчера.
    $env:FILMS4K_GPU_TIER = $script:gpuTier
    $env:FILMS4K_GPU_NAME = $script:gpuName
}

Resolve-GpuProfile

# Обычные видеоссылки (хостинги и прямые потоки) запускаются в mpv напрямую,
# без парсера сезонов: одиночному видео не нужны «серии».
function Test-DirectUrl([string]$u) {
    if (-not $script:rxHttp.IsMatch($u)) { return $false }
    if ($script:rxDirectExt.IsMatch($u)) { return $true }
    $h = ''
    try { $h = ([Uri]$u).Host } catch { return $false }
    if (-not $h) { return $false }
    if ($script:directHosts.Contains($h)) { return $true }
    foreach ($d in $script:directHosts) {
        if ($h.EndsWith('.' + $d, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Format-DurationText([int]$sec) {
    if ($sec -le 0) { return '' }
    $m = [int][Math]::Round($sec / 60.0)
    if ($m -lt 60) { return ($m.ToString() + ' мин') }
    $h = [int][Math]::Floor($m / 60)
    $mm = $m % 60
    if ($mm -eq 0) { return ($h.ToString() + ' ч') }
    return ($h.ToString() + ' ч ' + $mm.ToString() + ' мин')
}

# ---------------------------------------------------------------- modes
$script:modes = @(
    @{
        Title = 'Аниме: Стандарт 4K (Mode A HQ)'
        Desc  = 'Для большинства современных аниме. Делает контуры четкими.'
        Files = @(
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Restore_CNN_VL.glsl', 'Anime4K_Upscale_CNN_x2_VL.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl', 'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_M.glsl'
        )
        # Быстрая версия того же пресета Anime4K v4 для встроенных GPU.
        FilesLite = @(
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Restore_CNN_M.glsl', 'Anime4K_Upscale_CNN_x2_M.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl', 'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_S.glsl'
        )
    },
    @{
        Title = 'Аниме: Против мыла 4K (Mode B HQ)'
        Desc  = 'Для серий в плохом качестве и низком битрейте.'
        Files = @(
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Restore_CNN_Soft_VL.glsl', 'Anime4K_Upscale_CNN_x2_VL.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl', 'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_M.glsl'
        )
        FilesLite = @(
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Restore_CNN_Soft_M.glsl', 'Anime4K_Upscale_CNN_x2_M.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl', 'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_S.glsl'
        )
    },
    @{
        Title = 'Аниме: Старое / Шумное 4K (Mode C HQ)'
        Desc  = 'Для аниме 90-х и 2000-х. Убирает зерно и сжатие.'
        Files = @(
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl', 'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_M.glsl'
        )
        FilesLite = @(
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl', 'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_S.glsl'
        )
    },
    @{
        Title = 'Кино и сериалы 4K (FSRCNNX)'
        Desc  = 'Для фильмов с живыми актерами. Без мультяшного эффекта.'
        Files = @('FSRCNNX_x2_16-0-4-1.glsl')
    },
    @{
        Title = 'Старое кино / Сериалы 4K (Реставрация)'
        Desc  = 'Для старых фильмов и сериалов. Убирает зерно, шум и мыло'
        Files = @(
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Denoise_Bilateral_Mean.glsl',
            'FSRCNNX_x2_16-0-4-1.glsl'
        )
        Vf    = 'lavfi=[hqdn3d=luma_spatial=2.0:chroma_spatial=1.5:luma_tmp=3.0:chroma_tmp=2.5]'
    },
    @{
        Title = 'Оригинал (Без улучшений)'
        Desc  = 'Чистое видео без нейросетей и шейдеров.'
        Files = @()
    }
)

# ---------------------------------------------------------------- form
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Anime4K Center'
$form.ClientSize = New-Object System.Drawing.Size(960, 952)
$form.BackColor = $colBg
$form.ForeColor = $colText
$form.Font = $fontBase
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:mpvPath) } catch { }

$table = New-Object System.Windows.Forms.TableLayoutPanel
$table.Dock = [System.Windows.Forms.DockStyle]::Fill
$table.ColumnCount = 1
$table.RowCount = 2
$table.BackColor = $colBg
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
$form.Controls.Add($table)

$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = [System.Windows.Forms.DockStyle]::Fill
$flow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$flow.WrapContents = $false
$flow.AutoScroll = $true
$flow.Padding = New-Object System.Windows.Forms.Padding(24, 16, 24, 4)
$flow.BackColor = $colBg
$table.Controls.Add($flow, 0, 0)

# ---------------------------------------------------------------- header
$head = New-Object System.Windows.Forms.Panel
$head.Size = New-Object System.Drawing.Size(890, 72)
$head.BackColor = $colBg
$head.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)

$lblTitle = New-Lbl 'Anime4K Center' 0 0 0 $fontTitle $colText
$lblSub = New-Lbl 'Домашний 4K-кинотеатр: аниме, фильмы и сериалы — с нейросетевым апскейлом' 3 44 0 $fontBase $colMuted
$head.Controls.Add($lblTitle)
$head.Controls.Add($lblSub)
$flow.Controls.Add($head)

# ---------------------------------------------------------------- card 1: modes
$card1 = New-Card 352
$card1.Controls.Add((New-Lbl 'Режим улучшения' 18 14 0 $fontCard $colText))

$script:radios = New-Object System.Collections.ArrayList
$rowY = 46
for ($i = 0; $i -lt $script:modes.Count; $i++) {
    $m = $script:modes[$i]
    $row = New-Object System.Windows.Forms.Panel
    $row.Location = New-Object System.Drawing.Point(12, $rowY)
    $row.Size = New-Object System.Drawing.Size(866, 48)
    $row.BackColor = $colCard

    $rb = New-Object System.Windows.Forms.RadioButton
    $rb.Location = New-Object System.Drawing.Point(10, 15)
    $rb.Size = New-Object System.Drawing.Size(18, 18)
    $rb.BackColor = $colCard
    $rb.ForeColor = $colText
    $rb.TabStop = $true

    $tl = New-Lbl $m.Title 36 4 800 $fontBold $colText
    $dl = New-Lbl $m.Desc 36 23 800 $fontSmall $colMuted

    $row.Controls.Add($rb)
    $row.Controls.Add($tl)
    $row.Controls.Add($dl)

    $rb.Add_CheckedChanged({
        if ($this.Checked) {
            foreach ($other in $script:radios) {
                if (-not [object]::ReferenceEquals($other, $this)) { $other.Checked = $false }
            }
        }
    })
    $row.Add_Click({ $this.Controls[0].Checked = $true })
    $tl.Add_Click({ $this.Parent.Controls[0].Checked = $true })
    $dl.Add_Click({ $this.Parent.Controls[0].Checked = $true })

    [void]$script:radios.Add($rb)
    $card1.Controls.Add($row)
    $rowY += 50
}
$script:radios[0].Checked = $true
$flow.Controls.Add($card1)

# ---------------------------------------------------------------- card 2: online
$card2 = New-Card 154
$card2.Controls.Add((New-Lbl 'Смотреть онлайн по ссылке или названию' 18 14 0 $fontCard $colText))
$card2.Controls.Add((New-Lbl 'Вставьте ссылку (YouTube, VK, RuTube, Кинопоиск и др.) или введите название аниме, фильма, сериала:' 18 42 820 $fontSmall $colMuted))

$urlBox = New-Object System.Windows.Forms.TextBox
$urlBox.Location = New-Object System.Drawing.Point(18, 62)
$urlBox.Size = New-Object System.Drawing.Size(618, 28)
$urlBox.BackColor = $colField
$urlBox.ForeColor = $colText
$urlBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$urlBox.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$card2.Controls.Add($urlBox)

# кнопка в стиле остальных кнопок приложения (заливка + тонкая рамка)
$btnPaste = New-Btn 'Вставить из буфера' 648 62 226 28 $colField $colFieldHi $fontBtn $colText 1 '#52525b'
$card2.Controls.Add($btnPaste)

$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($btnPaste, 'Вставить ссылку или название из буфера обмена (Ctrl+V)')
$tip.SetToolTip($urlBox, 'Ссылка на видео: YouTube, RuTube, VK Video, Кинопоиск, прямой mp4 / m3u8. Или название аниме, фильма, сериала')

$btnOnline = New-Btn 'Смотреть онлайн в 4K' 18 100 856 44 $colAccent $colAccentHi $fontBig $colText
$card2.Controls.Add($btnOnline)
$flow.Controls.Add($card2)

# ---------------------------------------------------------------- card 3: local files
$card3 = New-Card 100
$card3.Controls.Add((New-Lbl 'Файлы с компьютера' 18 14 0 $fontCard $colText))
$btnFile = New-Btn 'Открыть серию или фильм с ПК' 18 46 419 42 $colField $colFieldHi $fontBtn $colText 1 '#52525b'
$btnFolder = New-Btn 'Открыть папку с сезоном' 453 46 421 42 $colField $colFieldHi $fontBtn $colText 1 '#52525b'
$card3.Controls.Add($btnFile)
$card3.Controls.Add($btnFolder)
$flow.Controls.Add($card3)

# ---------------------------------------------------------------- card 4: browser
$card4 = New-Card 126
$card4.Controls.Add((New-Lbl '4K прямо в браузере (Magpie и NVIDIA VSR)' 18 14 0 $fontCard $colText))
$btnMagpie = New-Btn 'Включить 4K поверх браузера' 18 44 419 42 $colField $colFieldHi $fontBtn $colText 1 '#52525b'
$btnVsr = New-Btn 'Настройки NVIDIA VSR (Суперразрешение)' 453 44 421 42 $colField $colFieldHi $fontBtn $colText 1 '#52525b'
$memo = New-Lbl 'Для Magpie: откройте видео в браузере в обычном окне и нажмите Win + Shift + A' 18 92 856 $fontSmall $colMuted
$card4.Controls.Add($btnMagpie)
$card4.Controls.Add($btnVsr)
$card4.Controls.Add($memo)
$flow.Controls.Add($card4)

# ---------------------------------------------------------------- footer
$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = [System.Windows.Forms.DockStyle]::Fill
$footer.BackColor = $colBg
$footLbl = New-Object System.Windows.Forms.Label
$footLbl.Dock = [System.Windows.Forms.DockStyle]::Fill
$footLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$footLbl.Padding = New-Object System.Windows.Forms.Padding(26, 0, 12, 0)
$footLbl.Font = $fontSmall
$footLbl.ForeColor = $colSubtle
$footLbl.BackColor = $colBg
$footLbl.Text = 'Во время просмотра можно менять режимы на лету: Ctrl+1 (Mode A)  |  Ctrl+2 (Mode B)  |  Ctrl+3 (Mode C)  |  Ctrl+4 (Кино)  |  Ctrl+5 (Старое кино)  |  Ctrl+0 (Оригинал)'
$footer.Controls.Add($footLbl)
$table.Controls.Add($footer, 0, 1)

# ---------------------------------------------------------------- actions
function Get-ModeIndex {
    for ($i = 0; $i -lt $script:radios.Count; $i++) {
        if ($script:radios[$i].Checked) { return $i }
    }
    return 0
}

function Get-ModeArgs([int]$idx) {
    $m = $script:modes[$idx]
    # На встроенных/слабых GPU берём облегчённую цепочку _M/_S того же режима.
    $files = @($m.Files)
    if ($script:gpuTier -eq 'lite' -and $m.ContainsKey('FilesLite') -and @($m.FilesLite).Count -gt 0) {
        $files = @($m.FilesLite)
    }
    # Видеофильтр: сбрасывается во всех режимах, кроме реставрации старого кино.
    if ($m.ContainsKey('Vf') -and $m.Vf) {
        $vfArg = '--vf="' + $m.Vf + '"'
    } else {
        $vfArg = '--vf='
    }
    if ($files.Count -eq 0) { return ($vfArg + ' --glsl-shaders=') }
    $missing = @($files | Where-Object { -not (Test-Path (Join-Path $script:shaderDir $_)) })
    if ($missing.Count -gt 0) { throw ('Не найдены файлы шейдеров: ' + ($missing -join ', ')) }
    $list = ($files | ForEach-Object { Join-Path $script:shaderDir $_ }) -join ';'
    return ($vfArg + ' --glsl-shaders="' + $list + '"')
}

function Get-GpuArgs {
    # Явно передаём профиль производительности в mpv (плюс env и gpu_profile.txt
    # остаются как резервные источники для yummy_ui.lua).
    return (' --script-opts-append=yummy_ui-gpu_tier=' + $script:gpuTier)
}

function Start-Mpv([string]$target) {
    if (-not (Test-Path $script:mpvPath)) { throw 'Не найден mpv.exe рядом с лаунчером.' }
    $argLine = (Get-ModeArgs (Get-ModeIndex)) + (Get-GpuArgs)
    if ($target) { $argLine = $argLine + ' "' + $target + '"' }
    Start-Process -FilePath $script:mpvPath -ArgumentList $argLine -WorkingDirectory $script:root | Out-Null
}

# ---------------------------------------------------------------- онлайн-тайтлы
function Get-OnlineInfo([string]$url) {
    if (-not (Test-Path $script:parser)) { throw 'Не найден online_parser.ps1 рядом с лаунчером.' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:psExe
    # -NonInteractive: дочерний PowerShell не ждёт ввода и не создаёт лишних
    # объектов консоли — старт парсера на десятки миллисекунд быстрее.
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script:parser + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    # URL передаём через переменную окружения: не ломается на &, ?, # и кавычках
    $psi.EnvironmentVariables['FILMS4K_URL'] = $url

    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    # Ждём парсер, продолжая прокачивать сообщения WinForms: окно лаунчера
    # остаётся отзывчивым, а на кнопке виден статус «Получение списка…».
    # Шаг 40 мс вместо 100: результат подхватывается почти сразу после
    # завершения процесса, ожидание DoEvents не «съедает» кадры.
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    while (-not $p.HasExited) {
        if ([DateTime]::UtcNow -gt $deadline) {
            try { $p.Kill() } catch { }
            throw 'Сайт слишком долго отвечает. Попробуйте ещё раз или откройте видео в браузере (Magpie).'
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 40
    }
    $p.WaitForExit()
    $out = ''
    $err = ''
    try { $out = $outTask.Result } catch { }
    try { $err = $errTask.Result } catch { }
    $p.Dispose()

    # Результат — последняя JSON-строка в выводе. Ищем с конца: не разбираем
    # весь stdout (там бывают мегабайты отладочных сообщений от yt-dlp).
    $json = $null
    $lines = $out.Split([char]10)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $s = $lines[$i].Trim()
        if ($s.Length -gt 1 -and $s[0] -eq '{' -and $s[$s.Length - 1] -eq '}') {
            $json = $s
            break
        }
    }
    if (-not $json) {
        $tail = ($err -replace '\s+', ' ').Trim()
        if ($tail.Length -gt 400) { $tail = $tail.Substring(0, 400) }
        throw ('Парсер не вернул результат. ' + $tail)
    }
    return ($json | ConvertFrom-Json)
}

function Select-Voice([string]$title, $voices, [string]$heading = 'Выберите озвучку', [string]$buttonText = 'Запустить выбранную озвучку', [string]$subtitle = '') {
    $script:voicePick = $null
    $script:voiceList = @($voices)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Anime4K Center'
    $dlg.ClientSize = New-Object System.Drawing.Size(480, 430)
    $dlg.BackColor = $colBg
    $dlg.ForeColor = $colText
    $dlg.Font = $fontBase
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    try { $dlg.Icon = $form.Icon } catch { }

    $dlg.Controls.Add((New-Lbl $heading 20 16 0 $fontCard $colText))
    $subText = 'Найдено вариантов: ' + $script:voiceList.Count
    if ($subtitle) { $subText = $subtitle + ' · ' + $subText }
    elseif ($title) { $subText = $title + ' · ' + $subText }
    $dlg.Controls.Add((New-Lbl $subText 21 44 436 $fontSmall $colMuted))

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(20, 76)
    $list.Size = New-Object System.Drawing.Size(440, 264)
    $list.BackColor = $colCard
    $list.ForeColor = $colText
    $list.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $list.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    # Строго один выбранный пункт: без «залипших» подсветок при клике/стрелках.
    $list.SelectionMode = [System.Windows.Forms.SelectionMode]::One
    $list.ItemHeight = 36
    $list.IntegralHeight = $false
    foreach ($v in $script:voiceList) {
        $cnt = 0
        if ($v.episodes) { $cnt = @($v.episodes).Count }
        $row = [string]$v.name + '  ·  ' + $cnt + ' сер.'
        if ($v.label) { $row = [string]$v.label }
        [void]$list.Items.Add($row)
    }
    $list.Add_DrawItem({
        param($sender, $e)
        if ($e.Index -lt 0) { return }
        # Подсветка ровно одной строки — по состоянию самого элемента.
        $isSel = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0) -or
            ($e.Index -eq $sender.SelectedIndex)
        $bg = if ($isSel) { $colAccent } else { $colCard }
        $brush = New-Object System.Drawing.SolidBrush($bg)
        $e.Graphics.FillRectangle($brush, $e.Bounds)
        $brush.Dispose()
        $tb = New-Object System.Drawing.SolidBrush($colText)
        $tx = [int]$e.Bounds.X + 12
        $ty = [int]$e.Bounds.Y + 8
        $e.Graphics.DrawString([string]$sender.Items[$e.Index], $sender.Font, $tb, $tx, $ty)
        $tb.Dispose()
    })
    # Смена выбора перерисовывает список целиком: старая строка не остаётся
    # подсвеченной ни при клике, ни при навигации стрелками.
    $list.Add_SelectedIndexChanged({ param($sender, $e) $sender.Invalidate() })
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    $dlg.Controls.Add($list)

    $btnStart = New-Btn $buttonText 20 356 306 44 $colAccent $colAccentHi $fontBtn $colText
    $btnCancel = New-Btn 'Отмена' 338 356 122 44 $colField $colFieldHi $fontBtn $colText 1 '#52525b'
    $dlg.Controls.Add($btnStart)
    $dlg.Controls.Add($btnCancel)

    $activate = {
        if ($list.SelectedIndex -lt 0) { return }
        $script:voicePick = $script:voiceList[$list.SelectedIndex]
        $dlg.Close()
    }
    $btnStart.Add_Click($activate)
    $list.Add_DoubleClick($activate)
    $btnCancel.Add_Click({ $dlg.Close() })
    $dlg.AcceptButton = $btnStart
    $dlg.CancelButton = $btnCancel

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
    return $script:voicePick
}

function Get-EpisodeLabel($ep, [int]$n, [int]$seasonNo = 0) {
    $t = [string]$ep.title
    $t = (($t -replace '[\r\n]+', ' ') -replace '\s+', ' ').Trim()
    # Парсер уже отдаёт готовые метки SxxExx — не дублируем сезон и номер.
    if ($script:rxSxxExx.IsMatch($t)) { return $t }
    $num = 0
    $m = $script:rxEpNumber.Match($t)
    if ($m.Success) { [void][int]::TryParse($m.Groups[1].Value, [ref]$num) }
    $label = ''
    if ($seasonNo -gt 0) {
        $label = ('S{0:00}E{1:00}' -f $seasonNo, $n)
    } elseif ($num -gt 0) {
        $label = 'Серия ' + $num
    } else {
        $label = 'Серия ' + $n
    }
    if ($t -and -not $script:rxEpPlain.IsMatch($t) -and -not $script:rxSxxExxEnd.IsMatch($t)) {
        $label = $label + ' · ' + $t
    }
    return $label
}

function Write-Playlist($episodes, [string]$path = '', [int]$seasonNo = 0) {
    if (-not $path) { $path = Join-Path $script:root 'temp_playlist.m3u8' }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('#EXTM3U')
    $n = 0
    foreach ($ep in @($episodes)) {
        $n++
        $lines.Add('#EXTINF:-1,' + (Get-EpisodeLabel $ep $n $seasonNo))
        $lines.Add([string]$ep.url)
    }
    [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# Приводит ответ парсера к единому списку сезонов с озвучками.
function Get-OnlineSeasons($info) {
    $result = New-Object System.Collections.ArrayList
    if ($info.seasons) {
        foreach ($s in @($info.seasons)) {
            if (-not $s) { continue }
            $voices = @($s.voices)
            if ($voices.Count -eq 0) { continue }
            [void]$result.Add([ordered]@{
                name    = [string]$s.name
                short   = [string]$s.short
                year    = [string]$s.year
                source  = [string]$s.source
                voices  = $voices
            })
        }
    }
    if ($result.Count -eq 0 -and $info.voices) {
        [void]$result.Add([ordered]@{
            name    = [string]$info.title
            short   = ''
            year    = ''
            source  = ''
            voices  = @($info.voices)
        })
    }
    # Запятая перед $result обязательна: иначе PowerShell «развернёт» ArrayList
    # и вернёт один OrderedDictionary, из-за чего вызывающий код видел не
    # список сезонов, а его поля («У найденных вариантов нет серий»).
    return ,$result
}

# Готовит плейлисты всех сезонов и манифест для селектора сезонов в mpv.
# Возвращает путь плейлиста выбранного сезона.
function Write-SeasonFiles($info, $seasons, [int]$pickedSeason, [string]$pickedVoice) {
    $multi = ($seasons.Count -ge 2)
    $manifestSeasons = New-Object System.Collections.ArrayList
    $metaEpisodes = New-Object System.Collections.ArrayList
    $metaSeen = @{}
    $pickedPath = ''

    for ($i = 0; $i -lt $seasons.Count; $i++) {
        $s = $seasons[$i]
        $voices = @($s.voices)
        if ($voices.Count -eq 0) { continue }
        $voice = $null
        foreach ($v in $voices) {
            if ($pickedVoice -and [string]$v.name -eq $pickedVoice) { $voice = $v; break }
        }
        if (-not $voice) { $voice = $voices[0] }
        $eps = @($voice.episodes)
        if ($eps.Count -eq 0) { continue }

        $seasonNo = $i + 1
        if ($multi) {
            $path = Join-Path $script:root ('temp_playlist_s' + $seasonNo + '.m3u8')
        } else {
            $path = Join-Path $script:root 'temp_playlist.m3u8'
        }
        [void](Write-Playlist $eps $path $seasonNo)
        if (($i + 1) -eq $pickedSeason) { $pickedPath = $path }

        # Качества каждой серии — для переключения прямо в mpv («Качество»).
        $epNo = 0
        foreach ($ep in $eps) {
            $epNo++
            $url = [string]$ep.url
            if (-not $url -or $metaSeen.ContainsKey($url)) { continue }
            $q = [ordered]@{}
            if ($ep.qualities) {
                if ($ep.qualities -is [System.Collections.IDictionary]) {
                    foreach ($k in @($ep.qualities.Keys)) {
                        if ($ep.qualities[$k]) { $q[[string]$k] = [string]$ep.qualities[$k] }
                    }
                } else {
                    foreach ($p in $ep.qualities.PSObject.Properties) {
                        if ($p.Value) { $q[[string]$p.Name] = [string]$p.Value }
                    }
                }
            }
            if ($q.Count -eq 0) { continue }
            $metaSeen[$url] = $true
            $metaEpisode = [ordered]@{
                title     = (Get-EpisodeLabel $ep $epNo $seasonNo)
                url       = $url
                qualities = $q
            }
            if ($ep.duration) { $metaEpisode.duration = [int]$ep.duration }
            [void]$metaEpisodes.Add($metaEpisode)
        }

        [void]$manifestSeasons.Add([ordered]@{
            name     = [string]$s.name
            short    = $(if ($s.short) { [string]$s.short } else { 'Сезон ' + $seasonNo })
            year     = [string]$s.year
            source   = [string]$s.source
            playlist = $path
            count    = $eps.Count
            first    = [string]$eps[0].url
        })
    }

    if ($multi -and $manifestSeasons.Count -ge 2) {
        $manifest = [ordered]@{
            title     = [string]$info.title
            kp_url    = [string]$info.kp_url
            generated = (Get-Date).ToString('s')
            active    = [int]$pickedSeason
            seasons   = @($manifestSeasons)
        }
        $json = $manifest | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($script:manifest, $json, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        # Одиночный фильм/сериал: убираем старый манифест, чтобы селектор
        # сезонов не появился в mpv для следующего видео.
        if (Test-Path $script:manifest) { Remove-Item $script:manifest -Force -ErrorAction SilentlyContinue }
        # Старые сезонные плейлисты тоже не должны попадать в UI.
        Get-ChildItem -Path $script:root -Filter 'temp_playlist_s*.m3u8' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # Метаданные качества: mpv-UI читает их и переключает HLS-вариант
    # текущей серии с сохранением позиции. Нет данных — убираем старый файл.
    if ($metaEpisodes.Count -gt 0) {
        $metaObj = [ordered]@{
            title     = [string]$info.title
            generated = (Get-Date).ToString('s')
            episodes  = @($metaEpisodes)
        }
        $metaJson = $metaObj | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($script:meta, $metaJson, (New-Object System.Text.UTF8Encoding($false)))
    } elseif (Test-Path $script:meta) {
        Remove-Item $script:meta -Force -ErrorAction SilentlyContinue
    }

    if (-not $pickedPath) {
        if ($manifestSeasons.Count -gt 0) { $pickedPath = [string]$manifestSeasons[0].playlist }
    }
    return $pickedPath
}

function Start-MpvPlaylist([string]$playlistPath) {
    if (-not (Test-Path $script:mpvPath)) { throw 'Не найден mpv.exe рядом с лаунчером.' }
    $argLine = (Get-ModeArgs (Get-ModeIndex)) + (Get-GpuArgs) + ' --playlist="' + $playlistPath + '"'
    Start-Process -FilePath $script:mpvPath -ArgumentList $argLine -WorkingDirectory $script:root | Out-Null
}

$btnPaste.Add_Click({
    try {
        $txt = [System.Windows.Forms.Clipboard]::GetText()
        if ($txt) { $urlBox.Text = $txt.Trim() }
    } catch { }
})

$btnOnline.Add_Click({
    $u = $urlBox.Text.Trim()
    if (-not $u) { Show-Error 'Введите ссылку или название аниме, фильма, сериала.'; return }

    # 1. Обычная видеоссылка (хостинг или прямой поток) — сразу в mpv, без парсера.
    if (Test-DirectUrl $u) {
        try { Start-Mpv $u } catch { Show-Error $_.Exception.Message }
        return
    }

    $oldText = $btnOnline.Text
    $btnOnline.Enabled = $false
    $btnOnline.Text = 'Поиск по названию, сезонам и озвучкам...'
    $form.UseWaitCursor = $true
    [System.Windows.Forms.Application]::DoEvents()

    # Ссылка на незнакомый сайт: если по ней не нашлось серий/озвучек,
    # отдаём её напрямую в mpv — yt-dlp воспроизведёт её как одиночный поток.
    $fallbackDirect = $script:rxHttp.IsMatch($u)

    try {
        $info = Get-OnlineInfo $u
        if ($info.protected -or $info.antibot) {
            Show-Info ([string]$info.message)
            return
        }
        if (-not $info.ok) {
            if ($fallbackDirect) {
                try { Start-Mpv $u } catch { Show-Error $_.Exception.Message }
                return
            }
            Show-Error ([string]$info.message)
            return
        }

        $seasons = Get-OnlineSeasons $info
        if ($seasons.Count -eq 0) {
            if ($fallbackDirect) {
                try { Start-Mpv $u } catch { Show-Error $_.Exception.Message }
                return
            }
            Show-Error 'Не удалось найти серии или озвучки.'
            return
        }

        # Плоский список вариантов: сезон × озвучка.
        $variants = New-Object System.Collections.ArrayList
        for ($si = 0; $si -lt $seasons.Count; $si++) {
            $s = $seasons[$si]
            foreach ($v in @($s.voices)) {
                if (-not $v -or -not $v.episodes) { continue }
                $cnt = @($v.episodes).Count
                if ($cnt -eq 0) { continue }
                $label = [string]$v.name + '  ·  ' + $cnt + ' сер.'
                # Резервные источники (RuTube / YouTube) показываем с названием
                # видео и длительностью в минутах, чтобы отсеять нарезки визуально.
                if ($v.duration) {
                    $durText = Format-DurationText ([int]$v.duration)
                    $firstEp = [string]$v.episodes[0].title
                    $pieces = New-Object System.Collections.ArrayList
                    if ($firstEp) { [void]$pieces.Add($firstEp) }
                    [void]$pieces.Add([string]$v.name)
                    if ($durText) { [void]$pieces.Add($durText) }
                    if ($cnt -gt 1) { [void]$pieces.Add($cnt.ToString() + ' сер.') }
                    $label = ($pieces -join '  ·  ')
                }
                if ($seasons.Count -gt 1) {
                    $sn = [string]$s.short
                    if (-not $sn) { $sn = [string]$s.name }
                    $label = $sn + '  ·  ' + $label
                } elseif ([string]$s.name -and [string]$s.name -ne [string]$info.title) {
                    $label = [string]$s.name + '  ·  ' + $label
                }
                [void]$variants.Add([ordered]@{
                    name     = [string]$v.name
                    episodes = @($v.episodes)
                    label    = $label
                    season   = $si + 1
                })
            }
        }
        if ($variants.Count -eq 0) {
            if ($fallbackDirect) {
                try { Start-Mpv $u } catch { Show-Error $_.Exception.Message }
                return
            }
            Show-Error 'У найденных вариантов нет серий.'
            return
        }

        $pick = $variants[0]
        if ($variants.Count -gt 1) {
            $subtitle = ''
            if ($info.kp_id) { $subtitle = 'Кинопоиск · ID ' + [string]$info.kp_id }
            $pick = Select-Voice ([string]$info.title) $variants 'Выберите вариант / озвучку' 'Запустить выбранный вариант' $subtitle
            if ($null -eq $pick) { return }   # пользователь нажал «Отмена»
        }

        $pickedSeason = [int]$pick.season
        if ($pickedSeason -lt 1 -or $pickedSeason -gt $seasons.Count) { $pickedSeason = 1 }
        $playlist = Write-SeasonFiles $info $seasons $pickedSeason ([string]$pick.name)
        if (-not $playlist -or -not (Test-Path $playlist)) {
            if ($fallbackDirect) {
                try { Start-Mpv $u } catch { Show-Error $_.Exception.Message }
                return
            }
            Show-Error 'Не удалось подготовить плейлист серий.'
            return
        }
        Start-MpvPlaylist $playlist
    } catch {
        Show-Error $_.Exception.Message
    } finally {
        if (-not $form.IsDisposed) {
            $btnOnline.Text = $oldText
            $btnOnline.Enabled = $true
            $form.UseWaitCursor = $false
        }
    }
})

$urlBox.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $btnOnline.PerformClick() }
})

# Ctrl+V в любом месте окна вставляет ссылку из буфера
$form.KeyPreview = $true
$form.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::V) {
        $btnPaste.PerformClick()
        $_.SuppressKeyPress = $true
    }
})

# серая подсказка внутри поля ввода (EM_SETCUEBANNER)
try {
    Add-Type -Namespace Win32Cue -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);'
    [void]([Win32Cue.Native]::SendMessage($urlBox.Handle, 0x1501, [IntPtr]1, 'https://... или название (например, Гуррен-Лаганн)'))
} catch { }

$btnFile.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Выберите серию или фильм'
    $dlg.Filter = 'Видео (*.mkv;*.mp4;*.avi;*.webm;*.m4v;*.mov;*.ts)|*.mkv;*.mp4;*.avi;*.webm;*.m4v;*.mov;*.ts|Все файлы (*.*)|*.*'
    $dlg.CheckFileExists = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try { Start-Mpv $dlg.FileName } catch { Show-Error $_.Exception.Message }
    }
})

$btnFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Выберите папку с сезоном (серии пойдут подряд)'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try { Start-Mpv $dlg.SelectedPath } catch { Show-Error $_.Exception.Message }
    }
})

$btnMagpie.Add_Click({
    if (-not (Test-Path $script:magpie)) { Show-Error 'Не найден Magpie.exe в папке Magpie.'; return }
    $running = Get-Process -Name 'Magpie' -ErrorAction SilentlyContinue
    if ($running) { Show-Error 'Magpie уже запущен. Переключите окно браузера и нажмите Win + Shift + A.'; return }
    try { Start-Process -FilePath $script:magpie -WorkingDirectory (Split-Path $script:magpie -Parent) | Out-Null } catch { Show-Error $_.Exception.Message }
})

$btnVsr.Add_Click({
    $candidates = @(
        'C:\Program Files\NVIDIA Corporation\NVIDIA app\CEF\NVIDIA app.exe',
        'C:\Program Files\NVIDIA Corporation\NVIDIA App\NVIDIA App.exe',
        (Join-Path $env:LOCALAPPDATA 'NVIDIA Corporation\NVIDIA app\CEF\NVIDIA app.exe'),
        'C:\Program Files\NVIDIA Corporation\NVIDIA Control Panel\nvcplui.exe'
    )
    $started = $false
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            try { Start-Process -FilePath $c | Out-Null; $started = $true; break } catch { }
        }
    }
    if (-not $started) {
        try { Start-Process -FilePath 'nvcplui.exe' | Out-Null; $started = $true } catch { }
    }
    $msg = 'Откройте раздел Видео -> Регулировка параметров изображения для видео -> включите Суперразрешение (качество 4) и нажмите Применить.'
    if (-not $started) { $msg = "Не удалось автоматически открыть панель NVIDIA (nvcplui.exe / NVIDIA app).`r`n`r`n" + $msg }
    [System.Windows.Forms.MessageBox]::Show($msg, 'NVIDIA VSR', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
})

# ---------------------------------------------------------------- run
if ($SmokeTest) {
    $form.Dispose()
    Write-Output 'SMOKE OK'
    return
}

[void]$form.ShowDialog()
$form.Dispose()
