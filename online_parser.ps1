# =========================================================
#  online_parser.ps1 — поиск и разбор онлайн-видео
#  Вход: ссылка (YouTube / VK / RuTube / Кинопоиск / аниме-каталог)
#        или название аниме, фильма, сериала.
#  Выход: JSON { ok, title, kind, kp_id, kp_url, seasons=[...],
#                voices=[{name,episodes[]}], protected, message }
#
#  Стратегия:
#   0) системный прокси Windows + браузерные заголовки для всех запросов;
#   1) прямая ссылка -> yt-dlp --flat-playlist -J;
#   2) Кинопоиск-ссылка -> kp_id + название (Wikidata, если страница закрыта);
#   3) название -> API AniLiberty (поиск релиза + франшиза/сезоны) ->
#      открытый поиск RuTube -> yt-dlp ytsearch;
#   4) HTML-страница: iframe-плееры, открытые API, прямые .m3u8 / .mp4;
#   5) DRM / Cloudflare -> понятное сообщение, а не техническая ошибка.
# =========================================================
param([string]$Url)

$ErrorActionPreference = 'Stop'
# Отключаем отрисовку прогресс-бара Invoke-WebRequest: в фоновом процессе он
# не нужен, но на каждом запросе стоит десятки миллисекунд (заметно на серии
# из десятков запросов к API/страницам).
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 } catch { }
try { [Net.ServicePointManager]::DefaultConnectionLimit = 10 } catch { }
# Без «Expect: 100-continue» каждый запрос не ждёт подтверждения сервера.
try { [Net.ServicePointManager]::Expect100Continue = $false } catch { }

if (-not $Url) { $Url = $env:FILMS4K_URL }
$Url = ([string]$Url).Trim()

$script:Ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
$script:Root = Split-Path -Parent $PSCommandPath
$script:Ytdlp = Join-Path $script:Root 'yt-dlp.exe'
$script:AntibotMsg = 'Прямой поток защищен. Откройте фильм в браузере и нажмите "Включить 4K поверх браузера (Magpie)".'
$script:NoTitleMsg = 'Введите ссылку или название аниме, фильма, сериала.'
$script:DefaultHeaders = @{
    'Accept'          = 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8'
    'Accept-Language' = 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7'
}
# Кодировка и cookie читаются один раз за процесс, а не на каждый запрос.
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Cookie = [Environment]::GetEnvironmentVariable('FILMS4K_COOKIE')

function Log([string]$m) {
    try { [Console]::Error.WriteLine('[films4k] ' + $m) } catch { }
}

# --------------------------------------------------------- системный прокси
function Get-ProxyUrl {
    $found = New-Object System.Collections.ArrayList

    # 1. Настройки WinINet / системный прокси (VPN-клиенты часто пишут сюда)
    try {
        $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($reg -and $reg.ProxyEnable -eq 1 -and $reg.ProxyServer) {
            $raw = [string]$reg.ProxyServer
            if ($raw -match '\s*=\s*') {
                foreach ($part in ($raw -split ';')) {
                    if ($part -match '^\s*(https?)\s*=\s*(.+?)\s*$') {
                        $val = $Matches[2]
                        if ($val -notmatch '^[a-z]+://') { $val = 'http://' + $val }
                        [void]$found.Add($val)
                    }
                }
            } elseif ($raw) {
                if ($raw -notmatch '^[a-z]+://') { $raw = 'http://' + $raw }
                [void]$found.Add($raw)
            }
        }
    } catch { }

    # 2. Автоопределение прокси через .NET (учитывает PAC-файл)
    try {
        $wp = [System.Net.WebRequest]::GetSystemWebProxy()
        $pu = $wp.GetProxy('https://aniliberty.top')
        if ($pu -and $pu.AbsoluteUri -match '^https?://') {
            if ($pu.Host -and $pu.Host -notmatch 'aniliberty|anilibria') {
                [void]$found.Add($pu.AbsoluteUri)
            }
        }
    } catch { }

    # 3. Переменные окружения (Clash / v2ray / sing-box)
    foreach ($n in @('HTTPS_PROXY', 'ALL_PROXY', 'HTTP_PROXY', 'https_proxy', 'all_proxy', 'http_proxy')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) {
            if ($v -notmatch '^[a-z]+://') { $v = 'http://' + $v }
            [void]$found.Add($v)
        }
    }

    foreach ($p in $found) {
        $p = ([string]$p).Trim()
        if ($p -and $p -match '^https?://') { return $p.TrimEnd('/') }
    }
    return ''
}

$script:Proxy = Get-ProxyUrl
if ($script:Proxy) { Log ('proxy: ' + $script:Proxy) } else { Log 'proxy: straight connection' }

# --------------------------------------------------------- HTTP
function Fetch([string]$u, [string]$referer = '', [string]$ua = '', [string]$accept = '') {
    try {
        $h = $script:DefaultHeaders.Clone()
        if ($accept) { $h['Accept'] = $accept }
        if ($referer) { $h['Referer'] = $referer }
        if ($script:Cookie) { $h['Cookie'] = $script:Cookie }
        $agent = $script:Ua
        if ($ua) { $agent = $ua }
        $p = @{
            Uri                = $u
            UseBasicParsing    = $true
            UserAgent          = $agent
            TimeoutSec         = 30
            Headers            = $h
            MaximumRedirection = 6
            ErrorAction        = 'Stop'
        }
        if ($script:Proxy) { $p['Proxy'] = $script:Proxy }
        $r = Invoke-WebRequest @p
        $text = ''
        $bytes = $null
        try {
            $ms = $r.RawContentStream
            if ($ms) {
                $ms.Position = 0
                $bytes = New-Object byte[] ([int]$ms.Length)
                [void]$ms.Read($bytes, 0, $bytes.Length)
            }
        } catch { }
        if ($bytes -and $bytes.Length -gt 0) {
            $ct = ''
            try { $ct = [string]$r.Headers['Content-Type'] } catch { }
            $enc = $null
            if ($ct -match '(?i)charset\s*=\s*"?([A-Za-z0-9_\-]+)') {
                try { $enc = [Text.Encoding]::GetEncoding($Matches[1]) } catch { }
            }
            if (-not $enc) {
                # JSON всегда UTF-8; для HTML ищем meta charset в первых байтах
                if ($ct -match '(?i)json') {
                    $enc = $script:Utf8
                } else {
                    $head = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(2048, $bytes.Length))
                    if ($head -match '(?i)<meta[^>]+charset\s*=\s*["'']?([A-Za-z0-9_\-]+)') {
                        try { $enc = [Text.Encoding]::GetEncoding($Matches[1]) } catch { }
                    }
                }
            }
            if (-not $enc) { $enc = $script:Utf8 }
            $text = $enc.GetString($bytes)
        } elseif ($r.Content -is [byte[]]) {
            $text = [Text.Encoding]::UTF8.GetString($r.Content)
        } else {
            $text = [string]$r.Content
        }
        return @{ ok = $true; code = [int]$r.StatusCode; text = $text }
    } catch {
        $code = 0
        try {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $code = [int]$_.Exception.Response.StatusCode
            }
        } catch { }
        return @{ ok = $false; code = $code; text = '' }
    }
}

function Get-Json([string]$u, [string]$referer = '', [string]$ua = '', [string]$accept = '') {
    $r = Fetch $u $referer $ua $accept
    if (-not $r.ok -or -not $r.text) { return $null }
    try { return ($r.text | ConvertFrom-Json) } catch {
        # Иногда API отдаёт BOM / лишний пробел перед JSON
        try {
            $clean = $r.text.Trim().TrimStart([char]0xFEFF)
            return ($clean | ConvertFrom-Json)
        } catch { return $null }
    }
}

function Out-Json($obj) {
    $obj | ConvertTo-Json -Depth 14 -Compress
    exit 0
}

function New-Result([bool]$ok, [string]$title, $voices, [bool]$antibot, [string]$message, $seasons = $null, [string]$kpUrl = '', [string]$kind = '', [string]$kpId = '') {
    $seasonList = @()
    if ($null -ne $seasons) { $seasonList = @($seasons) }
    $voiceList = @()
    if ($null -ne $voices) { $voiceList = @($voices) }
    return [ordered]@{
        ok        = $ok
        title     = $title
        kind      = $kind
        kp_id     = $kpId
        kp_url    = $kpUrl
        seasons   = $seasonList
        voices    = $voiceList
        protected = $antibot
        message   = $message
    }
}

# --------------------------------------------------------- утилиты
function Norm([string]$u) {
    if (-not $u) { return '' }
    $u = [Net.WebUtility]::HtmlDecode($u)
    $u = $u -replace '\\/', '/'
    $u = $u -replace '\\u0026', '&'
    $u = $u -replace '\\u003d', '='
    $u = $u.Trim()
    if ($u -match '^//') { $u = 'https:' + $u }
    return $u
}

function Abs-Url([string]$baseUrl, [string]$u) {
    $u = Norm $u
    if (-not $u) { return '' }
    if ($u -match '^https?://') { return $u }
    if ($u -match '^/') {
        try { return ([Uri]$baseUrl).GetLeftPart([UriPartial]::Authority) + $u } catch { return '' }
    }
    return ''
}

function Clean-Title([string]$s) {
    if (-not $s) { return '' }
    $s = [Net.WebUtility]::HtmlDecode($s)
    $s = $s -replace '\\[nrt]', ' '
    $s = $s -replace '\s+', ' '
    $s = $s -replace '(?i)\s*[—–-]\s*(Кинопоиск|Kinopoisk).*$', ''
    $s = $s -replace '(?i)\s*[|•·]\s*(Кинопоиск|Kinopoisk).*$', ''
    $s = $s -replace '(?i)^\s*(смотреть\s+)?(онлайн|бесплатно)\s+', ''
    $s = $s -replace '(?i)\s+(смотреть\s+)?онлайн\s*$', ''
    $s = $s -replace '(?i)\s+(бесплатно|в\s+хорошем\s+качестве)\s*$', ''
    $s = $s -replace '\s*\(\s*(фильм|сериал|мультфильм|аниме|тв)\s*\)\s*$', ''
    return $s.Trim(' ', '-', '—', '–', '|', ':')
}

$script:KeyCache  = @{}
$script:ToksCache = @{}

function Title-Key([string]$s) {
    if (-not $s) { return '' }
    # Кэш: при поиске Title-Key вызывается на каждый результат, а запрос
    # пользователя нормализуется десятки раз. Половина вызовов — повторные.
    if ($script:KeyCache.ContainsKey($s)) { return [string]$script:KeyCache[$s] }
    $v = $s.ToLowerInvariant()
    $v = $v -replace '[^\p{L}\p{N}]+', ' '
    $v = ($v -replace '\s+', ' ').Trim()
    if ($script:KeyCache.Count -ge 2000) { $script:KeyCache.Clear() }
    $script:KeyCache[$s] = $v
    return $v
}

$script:StopWords = @('смотреть', 'онлайн', 'сериал', 'сериала', 'фильм', 'фильма', 'аниме', 'мультфильм', 'сезон', 'серия', 'серии', 'эпизод', 'все', 'всех', 'новый', 'новая', 'the', 'and', 'movie', 'series', 'full')

function Title-Tokens([string]$s) {
    if (-not $s) { return @() }
    if ($script:ToksCache.ContainsKey($s)) { return ,$script:ToksCache[$s] }
    $arr = New-Object System.Collections.ArrayList
    foreach ($t in ((Title-Key $s) -split ' ')) {
        if ($t.Length -ge 3 -and $script:StopWords -notcontains $t) { [void]$arr.Add($t) }
    }
    $v = $arr.ToArray()
    if ($script:ToksCache.Count -ge 2000) { $script:ToksCache.Clear() }
    $script:ToksCache[$s] = $v
    return ,$v
}

function Title-Score([string]$a, [string]$b) {
    $ka = Title-Key $a
    $kb = Title-Key $b
    if (-not $ka -or -not $kb) { return 0 }
    if ($ka -eq $kb) { return 100 }
    if ($ka.Contains($kb) -or $kb.Contains($ka)) { return 72 }
    $ta = Title-Tokens $a
    $tb = Title-Tokens $b
    if ($ta.Count -eq 0 -or $tb.Count -eq 0) { return 0 }
    $hit = 0
    foreach ($t in $tb) { if ($ta -contains $t) { $hit++ } }
    return [int](60 * $hit / [Math]::Max(1, $tb.Count))
}

function Test-Antibot([string]$text, [int]$code) {
    if ($code -eq 401 -or $code -eq 403 -or $code -eq 429 -or $code -eq 503) { return $true }
    if (-not $text) { return $false }
    $low = $text.ToLowerInvariant()
    $markers = @(
        'cf-chl', 'cf_chl_opt', 'challenge-platform', 'just a moment',
        'checking your browser', 'ddos-guard', 'access denied',
        'доступ ограничен', 'проверка браузера', 'подтвердите, что вы не робот',
        'verify you are human', 'enable javascript and cookies to continue',
        'sso.kinopoisk.ru/install', 'passport.yandex.ru', 'showcaptcha'
    )
    foreach ($m in $markers) { if ($low.Contains($m)) { return $true } }
    return $false
}

function Test-Drm([string]$text) {
    if (-not $text) { return $false }
    $low = $text.ToLowerInvariant()
    foreach ($m in @('widevine', 'playready', 'clearkey', 'drmtoday', 'encryptedmedia', 'digital rights management')) {
        if ($low.Contains($m)) { return $true }
    }
    return $false
}

function Get-PageTitle([string]$html) {
    if (-not $html) { return '' }
    $m = [regex]::Match($html, '(?is)<title[^>]*>(.*?)</title>')
    if ($m.Success) { return Clean-Title ([Net.WebUtility]::HtmlDecode($m.Groups[1].Value) -replace '\s+', ' ') }
    $m = [regex]::Match($html, '(?is)property\s*=\s*["'']og:title["'']\s+content\s*=\s*["'']([^"'']+)')
    if ($m.Success) { return Clean-Title ([Net.WebUtility]::HtmlDecode($m.Groups[1].Value)) }
    return ''
}

function Add-Unique($list, [string]$url, [string]$title) {
    $url = Norm $url
    if ($url -notmatch '^https?://') { return }
    foreach ($x in $list) { if ($x.url -eq $url) { return } }
    [void]$list.Add([ordered]@{ title = $title; url = $url })
}

$script:EpPatterns = @(
    [regex]::new('(?i)(?:серия|серии|серию|эпизод|episode|ep\.?|e)\s*[№#]?\s*(\d{1,4})'),
    [regex]::new('(?i)(\d{1,4})\s*(?:серия|серии|эпизод)'),
    [regex]::new('(?i)\bS\d{1,2}E(\d{1,4})\b')
)

function Get-Ep-Number([string]$t) {
    if (-not $t) { return 0 }
    foreach ($p in $script:EpPatterns) {
        $m = $p.Match($t)
        if ($m.Success) {
            $n = 0
            [void][int]::TryParse($m.Groups[1].Value, [ref]$n)
            if ($n -gt 0) { return $n }
        }
    }
    return 0
}

function Format-Episodes($eps, [int]$seasonNo = 0) {
    $out = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($ep in @($eps)) {
        if (-not $ep) { continue }
        $n++
        $t = [string]$ep.title
        $t = (($t -replace '[\r\n]+', ' ') -replace '\s+', ' ').Trim()
        $num = Get-Ep-Number $t
        $label = ''
        if ($seasonNo -gt 0) {
            $label = ('S{0:00}E{1:00}' -f $seasonNo, $n)
            # В названии серии от API уже есть «Серия N» — не дублируем.
            $t = $t -replace '^(?i)(серия|эпизод)\s*[№#]?\s*\d+\s*[·:\-–—]?\s*', ''
        } elseif ($num -gt 0) {
            $label = 'Серия ' + $num
        } else {
            $label = 'Серия ' + $n
        }
        if ($t -and $t -notmatch '^(?i)(серия|эпизод)\s*[№#]?\s*\d+\s*$' -and $t -notmatch '^(?i)S\d+E\d+') {
            $label = $label + ' · ' + $t
        }
        $item = [ordered]@{ title = $label; url = [string]$ep.url }
        if ($ep.qualities) { $item.qualities = $ep.qualities }
        if ($ep.duration) { $item.duration = [int]$ep.duration }
        [void]$out.Add($item)
    }
    return @($out)
}

# --------------------------------------------------------- yt-dlp
function Get-CookieBrowsers {
    $arr = New-Object System.Collections.ArrayList
    $pairs = @(
        @{ name = 'chrome';  path = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') },
        @{ name = 'edge';    path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') },
        @{ name = 'brave';   path = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data') },
        @{ name = 'firefox'; path = (Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles') },
        @{ name = 'opera';   path = (Join-Path $env:APPDATA 'Opera Software\Opera Stable') }
    )
    foreach ($p in $pairs) {
        if ($p.path -and (Test-Path $p.path)) { [void]$arr.Add($p.name) }
    }
    # Yandex Browser: yt-dlp официально его не умеет, но профиль определяем —
    # если пользователь положил cookies.txt рядом, он подхватится через --cookies.
    return ,$arr
}

$script:CookieBrowsers = Get-CookieBrowsers
if ($script:CookieBrowsers.Count -gt 0) { Log ('cookies browsers: ' + ($script:CookieBrowsers -join ', ')) }

function Run-Ytdlp([string]$target, [bool]$withCookies = $false, [int]$timeoutSec = 90) {
    if (-not (Test-Path $script:Ytdlp)) { return $null }
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    try {
        $items = @(
            '--flat-playlist', '-J', '--no-warnings', '--ignore-config',
            '--socket-timeout', '20', '--retries', '1',
            '--user-agent', $script:Ua,
            '--add-header', ('Accept-Language: ' + $script:DefaultHeaders['Accept-Language']),
            '--add-header', 'Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8'
        )
        if ($script:Proxy) { $items += @('--proxy', $script:Proxy) }
        if ($withCookies) {
            $browser = ''
            foreach ($b in $script:CookieBrowsers) {
                if ($target -match 'kinopoisk|okko|ivi\.ru|wink|kion|start\.ru|yandex') { $browser = $b; break }
            }
            if (-not $browser -and $script:CookieBrowsers.Count -gt 0) { $browser = $script:CookieBrowsers[0] }
            if ($browser) { $items += @('--cookies-from-browser', $browser) }
        }
        $cookieFile = Join-Path $script:Root 'cookies.txt'
        if (Test-Path $cookieFile) { $items += @('--cookies', $cookieFile) }
        $items += $target

        $quoted = @($items | ForEach-Object { '"' + ([string]$_ -replace '"', '\"') + '"' })
        $argLine = $quoted -join ' '
        $p = Start-Process -FilePath $script:Ytdlp -ArgumentList $argLine -NoNewWindow -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $p.WaitForExit($timeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            return $null
        }
        $txt = [IO.File]::ReadAllText($out)
        if (-not $txt.Trim()) {
            try {
                $e = [IO.File]::ReadAllText($err)
                if ($e.Trim()) { Log ('yt-dlp: ' + (($e -replace '\s+', ' ').Trim())) }
            } catch { }
            return $null
        }
        return ($txt | ConvertFrom-Json)
    } catch {
        return $null
    } finally {
        Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    }
}

function Run-YtdlpSmart([string]$target, [bool]$preferCookies = $false) {
    $r = Run-Ytdlp $target $preferCookies 90
    if (-not $r -and $script:CookieBrowsers.Count -gt 0) {
        Log 'yt-dlp: retry with browser cookies'
        $r = Run-Ytdlp $target (-not $preferCookies) 90
    }
    return $r
}

function Convert-YtdlpResult($yt, [string]$fallbackUrl = '') {
    if (-not $yt) { return $null }
    $eps = New-Object System.Collections.ArrayList
    $title = Clean-Title ([string]$yt.title)
    if ($yt.entries) {
        $n = 0
        foreach ($e in @($yt.entries)) {
            if (-not $e) { continue }
            $n++
            $eu = [string]$e.webpage_url
            if (-not $eu) { $eu = [string]$e.url }
            if ($eu -and $eu -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
                if ($e.id -and ([string]$e.ie_key -match 'youtube' -or [string]$yt.extractor_key -match 'youtube')) {
                    $eu = 'https://www.youtube.com/watch?v=' + [string]$e.id
                } elseif ($e.id -and ([string]$e.ie_key -match 'rutube' -or [string]$yt.extractor_key -match 'rutube')) {
                    $eu = 'https://rutube.ru/video/' + [string]$e.id + '/'
                } else { $eu = '' }
            }
            if (-not $eu) { continue }
            $et = [string]$e.title
            if (-not $et) { $et = 'Серия ' + $n }
            Add-Unique $eps $eu $et
        }
    } else {
        $eu = [string]$yt.webpage_url
        if (-not $eu) { $eu = $fallbackUrl }
        Add-Unique $eps $eu $title
    }
    if ($eps.Count -eq 0) { return $null }
    if (-not $title) { $title = 'Онлайн-видео' }
    $voice = [ordered]@{ name = 'Оригинал'; episodes = @($eps) }
    return @{ title = $title; voices = @($voice) }
}

# --------------------------------------------------------- HTML (прежние источники)
function Get-MediaLinks([string]$text, [string]$baseUrl) {
    $arr = New-Object System.Collections.ArrayList
    $patterns = @(
        '(?i)(?:https?:)?//[^\s"<>\\]+?\.(?:m3u8|mp4)(?:\?[^\s"<>\\]*)?',
        '(?i)(?:src|href|file)\s*=\s*"([^"]+?\.(?:m3u8|mp4)[^"]*)"',
        '(?i)"(?:src|file|url|link)"\s*:\s*"([^"]+?\.(?:m3u8|mp4)[^"]*)"'
    )
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($text, $p)) {
            $raw = $m.Groups[1].Value
            if (-not $raw) { $raw = $m.Value }
            $u = Abs-Url $baseUrl $raw
            if ($u) { Add-Unique $arr $u '' }
        }
    }
    return ,$arr
}

function Get-Iframes([string]$text, [string]$baseUrl) {
    $arr = New-Object System.Collections.ArrayList
    $patterns = @(
        '(?is)<iframe[^>]+(?:data-)?src\s*=\s*"([^"]+)"',
        "(?is)<iframe[^>]+(?:data-)?src\s*=\s*'([^']+)'"
    )
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($text, $p)) {
            $u = Abs-Url $baseUrl $m.Groups[1].Value
            if ($u -and $u -notmatch 'about:blank|javascript:') {
                $exists = $false
                foreach ($x in $arr) { if ($x -eq $u) { $exists = $true; break } }
                if (-not $exists) { [void]$arr.Add($u) }
            }
        }
    }
    return ,$arr
}

function Get-EpisodeLinks([string]$text, [string]$baseUrl) {
    $arr = New-Object System.Collections.ArrayList
    $patterns = @(
        '(?i)"link"\s*:\s*"((?:https?:)?//[^"]+)"',
        '(?i)href\s*=\s*"([^"]*(?:/seria/|/series/|/episode/|/episodes/|/video/)[^"]*)"',
        '(?i)"(?:episode|episodes)"\s*:\s*"([^"]+)"'
    )
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($text, $p)) {
            $u = Abs-Url $baseUrl $m.Groups[1].Value
            if ($u -and $u -notmatch '\.(?:css|js|png|jpe?g|webp|svg|gif)(?:\?|$)') {
                Add-Unique $arr $u ''
            }
        }
    }
    return ,$arr
}

function Get-TranslationNames([string]$text) {
    $arr = New-Object System.Collections.ArrayList
    $found = New-Object System.Collections.ArrayList
    $patterns = @(
        '(?is)"translation"\s*:\s*\{[^{}]*?"title"\s*:\s*"([^"]{2,80})"',
        '(?is)"translations"\s*:\s*\[(.{0,8000}?)\]',
        '(?i)data-(?:translation|voice|studio)\s*=\s*"([^"]{2,80})"'
    )
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($text, $p)) {
            if ($p -like '*translations*') {
                foreach ($t in [regex]::Matches($m.Groups[1].Value, '"title"\s*:\s*"([^"]{2,80})"')) {
                    $v = [Net.WebUtility]::HtmlDecode($t.Groups[1].Value).Trim()
                    if ($v -and -not $found.Contains($v)) { $found.Add($v) | Out-Null; [void]$arr.Add($v) }
                }
            } else {
                $v = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value).Trim()
                if ($v -and -not $found.Contains($v)) { $found.Add($v) | Out-Null; [void]$arr.Add($v) }
            }
        }
    }
    return ,$arr
}

# --------------------------------------------------------- Кинопоиск / Wikidata
function Get-KpId([string]$u) {
    $m = [regex]::Match($u, '(?i)kinopoisk\.ru/(film|series)/(\d+)')
    if ($m.Success) {
        return @{ id = $m.Groups[2].Value; type = $m.Groups[1].Value.ToLowerInvariant() }
    }
    return $null
}

function Get-KpTitle([string]$kpId, [string]$kpType) {
    if (-not $kpId) { return '' }
    $props = @('P2603')
    if ($kpType -eq 'series') { $props = @('P2604', 'P2603') }
    foreach ($prop in $props) {
        $q = 'SELECT ?itemLabel WHERE { ?item wdt:' + $prop + ' "' + $kpId + '". SERVICE wikibase:label { bd:serviceParam wikibase:language "ru,en". } } LIMIT 1'
        $u = 'https://query.wikidata.org/sparql?format=json&query=' + [Uri]::EscapeDataString($q)
        $j = Get-Json $u '' 'Films4K-Center/1.0 (local desktop media app)' 'application/sparql-results+json'
        if ($j -and $j.results -and $j.results.bindings) {
            $b = @($j.results.bindings)
            if ($b.Count -gt 0 -and $b[0].itemLabel -and $b[0].itemLabel.value) {
                $t = Clean-Title ([string]$b[0].itemLabel.value)
                if ($t) { Log ('kinopoisk title: ' + $t); return $t }
            }
        }
    }
    return ''
}

# --------------------------------------------------------- AniLiberty
$script:AniBase = 'https://aniliberty.top/api/v1'
$script:AniRef = 'https://aniliberty.top/'

function Search-AniReleases([string]$q) {
    if (-not $q) { return @() }
    $u = $script:AniBase + '/app/search/releases?query=' + [Uri]::EscapeDataString($q)
    $j = Get-Json $u $script:AniRef
    if (-not $j) { return @() }
    Log ('aniliberty search "' + $q + '": ' + (@($j).Count) + ' results')
    return ,@($j)
}

function Get-AniRelease([string]$idOrAlias) {
    if (-not $idOrAlias) { return $null }
    return (Get-Json ($script:AniBase + '/anime/releases/' + [Uri]::EscapeDataString($idOrAlias)) $script:AniRef)
}

function Get-AniFranchise([int]$releaseId) {
    if ($releaseId -le 0) { return @() }
    $j = Get-Json ($script:AniBase + '/anime/franchises/release/' + $releaseId) $script:AniRef
    if (-not $j) { return @() }
    return ,@($j)
}

function Convert-AniRelease($j, [string]$shortName, [int]$seasonNo = 0) {
    if (-not $j -or -not $j.episodes) { return $null }
    # Сортируем серии по ordinal (1, 2, 3, ...), сохраняя исходный порядок
    # для записей без номера.
    $indexed = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($ep in @($j.episodes)) {
        if (-not $ep) { continue }
        $i++
        $n = [int]$ep.ordinal
        if ($n -le 0) { $n = $i }
        [void]$indexed.Add(@{ n = $n; i = $i; ep = $ep })
    }
    $eps = New-Object System.Collections.ArrayList
    $seenLinks = @{}
    foreach ($x in ($indexed | Sort-Object @{ Expression = { $_.n } }, @{ Expression = { $_.i } })) {
        $ep = $x.ep
        # Сохраняем все доступные HLS-качества серии: по ним UI в mpv
        # переключает качество без потери позиции (temp_playlist_meta.json).
        $q = [ordered]@{}
        if ($ep.hls_1080) { $q['1080'] = [string]$ep.hls_1080 }
        if ($ep.hls_720) { $q['720'] = [string]$ep.hls_720 }
        if ($ep.hls_480) { $q['480'] = [string]$ep.hls_480 }
        $link = ''
        foreach ($k in @('1080', '720', '480')) {
            if ($q.Contains($k)) { $link = [string]$q[$k]; break }
        }
        if (-not $link) { $link = [string]$ep.hls }
        if (-not $link) { continue }
        $link = Norm $link
        if ($seenLinks.ContainsKey($link)) { continue }
        $seenLinks[$link] = $true
        $n = [int]$x.n
        $t = [string]$ep.name
        if (-not $t) { $t = 'Серия ' + $n }
        else { $t = 'Серия ' + $n + ' · ' + $t }
        [void]$eps.Add([ordered]@{ title = $t; url = $link; qualities = $q })
    }
    if ($eps.Count -eq 0) { return $null }

    $main = ''
    if ($j.name -and $j.name.main) { $main = [string]$j.name.main }
    if (-not $main) { $main = 'AniLiberty' }
    $year = ''
    if ($j.year) { $year = [string]$j.year }
    $label = $main
    if ($year) { $label = $label + ' (' + $year + ')' }
    if ($shortName) { $label = $shortName + ' · ' + $label }

    $voiceName = 'AniLiberty · HLS'
    $episodes = Format-Episodes $eps $seasonNo
    return [ordered]@{
        name     = $label
        base     = ($main + $(if ($year) { ' (' + $year + ')' } else { '' }))
        short    = $(if ($shortName) { $shortName } else { 'Сезон 1' })
        year     = $year
        source   = 'AniLiberty'
        release  = [int]$j.id
        voices   = @([ordered]@{ name = $voiceName; episodes = @($episodes); source = 'AniLiberty' })
    }
}

function Get-AniSeasons($release) {
    if (-not $release) { return @() }
    $seasons = New-Object System.Collections.ArrayList
    $items = New-Object System.Collections.ArrayList

    # Франшиза: связанные релизы = сезоны / фильмы
    $fr = Get-AniFranchise ([int]$release.id)
    foreach ($f in $fr) {
        if ($f -and $f.franchise_releases) {
            foreach ($frr in @($f.franchise_releases)) {
                if ($frr -and $frr.release_id) {
                    $exists = $false
                    foreach ($x in $items) { if ([int]$x.id -eq [int]$frr.release_id) { $exists = $true; break } }
                    if (-not $exists) {
                        $rel = $frr.release
                        $year = 0
                        if ($rel -and $rel.year) { $year = [int]$rel.year }
                        [void]$items.Add(@{ id = [int]$frr.release_id; year = $year; sort = [int]$frr.sort_order })
                    }
                }
            }
        }
    }
    if ($items.Count -eq 0) { [void]$items.Add(@{ id = [int]$release.id; year = [int]$release.year; sort = 0 }) }

    # Сортируем как франшиза: по порядку, затем по году; без релиза-дубля.
    $sorted = @($items | Sort-Object @{ Expression = { $_.sort } }, @{ Expression = { $_.year } })
    $tv = 0
    $movies = 0
    foreach ($it in $sorted) {
        if ($seasons.Count -ge 12) { break }
        $detail = $null
        if ([int]$it.id -eq [int]$release.id) { $detail = $release }
        else { $detail = Get-AniRelease ([string]$it.id) }
        if (-not $detail) { continue }
        $type = ''
        if ($detail.type -and $detail.type.value) { $type = [string]$detail.type.value }
        $short = ''
        $no = 0
        if ($type -match '(?i)movie|film') {
            $movies++
            $short = 'Фильм ' + $movies
        } else {
            $tv++
            $no = $tv
            $short = 'Сезон ' + $tv
        }
        $season = Convert-AniRelease $detail $short $no
        if ($season) { [void]$seasons.Add($season) }
    }
    Log ('aniliberty seasons: ' + $seasons.Count)
    return ,$seasons
}

function Find-AniSeasons([string]$q) {
    $releases = Search-AniReleases $q
    if ($releases.Count -eq 0 -and $q -match '\s') {
        $shortQ = ($q -split '\s+')[0]
        if ($shortQ.Length -ge 3) { $releases = Search-AniReleases $shortQ }
    }
    $best = $null
    $bestScore = 0
    foreach ($r in $releases) {
        if (-not $r -or -not $r.id) { continue }
        $names = @()
        if ($r.name -and $r.name.main) { $names += [string]$r.name.main }
        if ($r.name -and $r.name.english) { $names += [string]$r.name.english }
        if ($r.alias) { $names += ([string]$r.alias -replace '-', ' ') }
        $sc = 0
        foreach ($n in $names) { $sc = [Math]::Max($sc, (Title-Score $n $q)) }
        if ($r.year) { $sc += 2 }  # лёгкий приоритет заполненным карточкам
        if ($sc -gt $bestScore) { $bestScore = $sc; $best = $r }
    }
    if (-not $best -or $bestScore -lt 40) {
        Log ('aniliberty: no confident match for "' + $q + '" (best=' + $bestScore + ')')
        return @()
    }
    $detail = $null
    if ($best.alias) { $detail = Get-AniRelease ([string]$best.alias) }
    if (-not $detail) { $detail = Get-AniRelease ([string]$best.id) }
    if (-not $detail) { return @() }
    Log ('aniliberty best: ' + [string]$best.alias + ' score=' + $bestScore)
    return (Get-AniSeasons $detail)
}

# --------------------------------------------------------- RuTube (открытый поиск)
# Общий фильтр «мусора» для обоих открытых источников: трейлеры, нарезки,
# стримы-обсуждения, ASMR, музыка, аудио-«исцеления» и прочие длинные ролики,
# которые не являются фильмом или серией.
$script:JunkRe = '(?i)трейлер|trailer|тизер|teaser|обзор|review|реакция|reaction|фрагмент|клип|музык|саундтрек|soundtrack|\bost\b|ambient|оркестр|концерт|кавер|cover|разбор|реценз|сцен[аы]|момент|theory|analysis|explained|shorts|asmr|стрим|stream|летсплей|let''?s\s*play|прохожд|геймплей|gameplay|walkthrough|майнкрафт|minecraft|roblox|\bgta\b|скайрим|skyrim|nioh|once\s+human|fortnite|dota|valorant|подкаст|podcast|аудиокниг|аудиоспектакл|радиоспектакл|исцелен|звуком|медитац|аффирмац|нарезк|подборк|топ\s*\d'
# Отдельный фильтр по названию канала: каналы ASMR, «исцеляющих матриц»,
# релакс-музыки и стримов не публикуют полные фильмы.
$script:JunkAuthorRe = '(?i)asmr|гар\s*яев|гаряев|wavegenetics|softradio|релакс|relax|медитац|аффирмац|исцелен|частот|биоакустик|психея|аудиокниг|аудиоспектакл|радиоспектакл|\bстрим|stream|летсплей|прохожд|подкаст|podcast'

function Search-RuTube([string]$q) {
    if (-not $q) { return @() }
    $script:RuFiltered = 0
    $u = 'https://rutube.ru/api/search/video/?query=' + [Uri]::EscapeDataString($q) + '&limit=30'
    $j = Get-Json $u 'https://rutube.ru/'
    if (-not $j -or -not $j.results) { return @() }
    $items = @($j.results) | Where-Object {
        $_ -and $_.id -and -not $_.is_deleted -and -not $_.is_locked -and -not $_.is_adult
    }
    Log ('rutube search "' + $q + '": ' + (@($items).Count) + ' results')

    $qTokens = @(Title-Tokens $q)
    $groups = @{}
    $groupAuthor = @{}
    foreach ($it in $items) {
        $t = [string]$it.title
        $dur = [int]$it.duration
        # Резервный источник для фильмов и сериалов: только полноценные
        # видео от 20 минут (1200 с), чтобы отсеять нарезки, клипы и трейлеры.
        if ($dur -lt 1200) { continue }
        $author = ''
        if ($it.author -and $it.author.name) { $author = [string]$it.author.name }
        if (-not $author) { $author = 'RuTube' }
        # Мусор ищем и в названии ролика, и в названии канала.
        if ($t -match $script:JunkRe) { continue }
        if ($author -match $script:JunkAuthorRe) { continue }
        $rel = Title-Score $t $q
        if ($rel -lt 15) { continue }
        $ep = Get-Ep-Number $t
        $episodic = ($t -match '(?i)(?:серия|серии|серию|эпизод|episode)\s*[№#]?\s*\d|\bS\d{1,2}E\d{1,4}\b|\b\d{1,2}\s*сезон\b')
        $hasYear = ($t -match '(?:19|20)\d{2}')
        $hasMarker = ($t -match '(?i)\bфильм|сериал|полный|полная версия|HD|4K|1080|смотреть|онлайн|премьера')
        # Похоже ли это вообще на фильм/серию, а не на ролик «по мотивам».
        # Пропускаем: серии, видео с годом/пометкой фильма, а также точное
        # совпадение названия (бывает, что полный фильм выложен без года).
        $exactish = ((Title-Key $t) -eq (Title-Key $q))
        if (-not ($episodic -or $hasYear -or $hasMarker -or $exactish)) { continue }
        # Слабые совпадения («Барби и Хрустальный замок» на запрос «Ходячий
        # замок») отбрасываем: это другой фильм, а не вариант нужного.
        if ($rel -lt 40 -and -not $exactish) { continue }
        $script:RuFiltered++
        if ($rel -gt $script:RuTopRel) { $script:RuTopRel = $rel }

        # Бонусы к релевантности: год выпуска, признаки полного фильма/серии,
        # близость длины названия к запросу (длинные «простыни» обычно мусорные).
        $bonus = 0
        if ($hasYear) { $bonus += 1200 }
        if ($hasMarker) { $bonus += 400 }
        $extra = @(Title-Tokens $t).Count - $qTokens.Count
        if ($extra -le 0) { $bonus += 2000 }
        elseif ($extra -eq 1) { $bonus += 1200 }
        elseif ($extra -eq 2) { $bonus += 400 }
        elseif ($extra -ge 6) { $bonus -= 800 }

        $akey = $author.ToLowerInvariant()
        if ($episodic) {
            $key = $akey + '|series'
        } else {
            # Разные фильмы одного канала — отдельные варианты, а не «серии».
            $key = $akey + '|' + (Title-Key $t)
        }
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = New-Object System.Collections.ArrayList
            $groupAuthor[$key] = @{ author = $author; episodic = $episodic }
        }
        [void]$groups[$key].Add(@{
            title    = $t
            url      = 'https://rutube.ru/video/' + [string]$it.id + '/'
            duration = $dur
            ep       = $ep
            rel      = $rel
            bonus    = $bonus
        })
    }

    $cand = New-Object System.Collections.ArrayList
    foreach ($k in $groups.Keys) {
        $arr = @($groups[$k])
        $seen = @{}
        $eps = New-Object System.Collections.ArrayList
        $total = 0
        $bestRel = 0
        $bestBonus = 0
        foreach ($x in ($arr | Sort-Object @{ Expression = { if ($_.ep -gt 0) { $_.ep } else { 9999 } } }, @{ Expression = { $_.duration }; Descending = $true })) {
            if ($seen.ContainsKey($x.url)) { continue }
            $seen[$x.url] = $true
            $total += [int]$x.duration
            if ([int]$x.rel -gt $bestRel) { $bestRel = [int]$x.rel }
            if ([int]$x.bonus -gt $bestBonus) { $bestBonus = [int]$x.bonus }
            [void]$eps.Add([ordered]@{ title = $x.title; url = $x.url; duration = [int]$x.duration })
        }
        if ($eps.Count -eq 0) { continue }
        $name = [string]$groupAuthor[$k].author
        [void]$cand.Add(@{
            # Релевантность названия — в приоритете, затем бонусы, число серий
            # и суммарная длительность как слабое дополнительное предпочтение.
            score = ($bestRel * 1000000) + ($bestBonus * 100) + ($eps.Count * 1000) + [Math]::Min($total, 200000)
            voice = [ordered]@{ name = $name + ' · RuTube'; episodes = @($eps); source = 'RuTube'; duration = $total }
        })
    }
    $voices = New-Object System.Collections.ArrayList
    foreach ($c in ($cand | Sort-Object @{ Expression = { $_.score }; Descending = $true })) {
        if ($voices.Count -ge 8) { break }
        [void]$voices.Add($c.voice)
    }
    Log ('rutube filtered=' + $script:RuFiltered + ' groups=' + $groups.Count + ' voices=' + $voices.Count)
    return ,@($voices)
}

function Get-RuTubeSeasons([string]$q) {
    $queries = @($q, ($q + ' фильм'), ($q + ' сериал'))
    $all = New-Object System.Collections.ArrayList
    $script:RuTopRel = 0
    foreach ($qq in $queries) {
        $voices = Search-RuTube $qq
        foreach ($v in $voices) {
            $dup = $false
            foreach ($x in $all) { if ($x.name -eq $v.name) { $dup = $true; break } }
            if (-not $dup) { [void]$all.Add($v) }
        }
        if ($all.Count -ge 8) { break }
    }
    if ($all.Count -eq 0) { return @() }
    if ($all.Count -gt 8) { $all = @($all | Select-Object -First 8) }
    # Сезон один, но вариантов (каналов/озвучек) может быть несколько.
    $season = [ordered]@{
        name    = $q
        base    = $q
        short   = ''
        year    = ''
        source  = 'RuTube'
        release = 0
        voices  = @($all)
    }
    return ,@($season)
}

function Get-YtSearchSeasons([string]$q) {
    # Открытый резервный поиск yt-dlp: 15 результатов на запрос
    # «… фильм смотреть онлайн» и «… сериал смотреть онлайн».
    $queries = @(($q + ' фильм смотреть онлайн'), ($q + ' сериал смотреть онлайн'))
    $eps = New-Object System.Collections.ArrayList
    $totalDur = 0
    foreach ($qq in $queries) {
        $yt = Run-YtdlpSmart ('ytsearch15:' + $qq)
        if (-not $yt -or -not $yt.entries) { continue }
        foreach ($e in @($yt.entries)) {
            if (-not $e -or -not $e.id) { continue }
            $title = [string]$e.title
            $chan = ''
            if ($e.channel) { $chan = [string]$e.channel }
            elseif ($e.uploader) { $chan = [string]$e.uploader }
            if ($title -match $script:JunkRe) { continue }
            if ($chan -and $chan -match $script:JunkAuthorRe) { continue }
            # Как и в RuTube: фильмы/сериалы — только от 20 минут.
            if ($e.duration -and [int]$e.duration -lt 1200) { continue }
            if ((Title-Score $title $q) -lt 15) { continue }
            $url = 'https://www.youtube.com/watch?v=' + [string]$e.id
            $dup = $false
            foreach ($x in $eps) { if ($x.url -eq $url) { $dup = $true; break } }
            if ($dup) { continue }
            $item = [ordered]@{ title = $title; url = $url }
            if ($e.duration) {
                $item.duration = [int]$e.duration
                $totalDur += [int]$e.duration
            }
            [void]$eps.Add($item)
        }
        if ($eps.Count -ge 15) { break }
    }
    if ($eps.Count -eq 0) { return @() }
    $season = [ordered]@{
        name    = $q
        base    = $q
        short   = ''
        year    = ''
        source  = 'YouTube'
        release = 0
        voices  = @([ordered]@{ name = 'YouTube · открытый поиск'; episodes = @(Format-Episodes $eps 0); source = 'YouTube'; duration = $totalDur })
    }
    return ,@($season)
}

# --------------------------------------------------------- AniLibria по ссылке
function Try-AniLibria([string]$u, [string]$pageTitle) {
    try {
        $uri = [Uri]$u
        if ($uri.Host -notmatch 'anilibria|aniliberty') { return $null }
        $slug = ($uri.AbsolutePath.TrimEnd('/') -split '/')[-1]
        $slug = $slug -replace '\.html?$', ''
        if ($slug -and $slug -match '^(release|anime|releases)$') { $slug = '' }

        $queries = New-Object System.Collections.ArrayList
        if ($slug) { [void]$queries.Add($slug) }
        if ($pageTitle) {
            $seasons = Find-AniSeasons (Clean-Title $pageTitle)
            if ($seasons.Count -gt 0) { return @{ title = $seasons[0].name; seasons = $seasons } }
        }
        foreach ($alias in $queries) {
            $j = Get-AniRelease $alias
            if (-not $j) { continue }
            $seasons = Get-AniSeasons $j
            if ($seasons.Count -gt 0) { return @{ title = $seasons[0].name; seasons = $seasons } }
        }
    } catch { }
    return $null
}

# --------------------------------------------------------- основной разбор
try {
    if (-not $Url) {
        Out-Json (New-Result $false '' @() $false $script:NoTitleMsg)
    }

    $isUrl = $Url -match '^https?://'
    $query = ''
    $kp = $null
    $kpTitle = ''
    $kpUrl = ''
    $direct = $null

    # ---------- 0. Кинопоиск-ссылка: kp_id + точное название ----------
    if ($isUrl -and ($Url -match 'kinopoisk\.ru')) {
        $kp = Get-KpId $Url
        if ($kp) {
            $kpUrl = 'https://www.kinopoisk.ru/' + $kp.type + '/' + $kp.id + '/'
            Log ('kinopoisk id: ' + $kp.id + ' (' + $kp.type + ')')
            $page = Fetch $Url $kpUrl
            if ($page.ok -and -not (Test-Antibot $page.text $page.code) -and -not (Test-Drm $page.text)) {
                $kpTitle = Get-PageTitle $page.text
            } elseif ($page.ok -and (Test-Drm $page.text)) {
                Out-Json (New-Result $false '' @() $true $script:AntibotMsg @() $kpUrl 'kp' $kp.id)
            }
            if (-not $kpTitle) { $kpTitle = Get-KpTitle $kp.id $kp.type }
            if ($kpTitle) {
                $query = $kpTitle
                Log ('kinopoisk page resolved: ' + $query)
            } else {
                # Страница закрыта (SSO/DRM), название определить не удалось.
                Out-Json (New-Result $false '' @() $true $script:AntibotMsg @() $kpUrl 'kp' $kp.id)
            }
        } else {
            Out-Json (New-Result $false '' @() $false 'Не удалось найти номер фильма в ссылке Кинопоиска. Скопируйте ссылку вида kinopoisk.ru/film/12345/.' @() $Url 'kp')
        }
    }

    if (-not $query) {
        if ($isUrl) {
            # ---------- 1. прямая ссылка -> yt-dlp ----------
            $direct = $Url

            # Аниме-сайты: сначала пробуем официальное API AniLiberty по названию
            # со страницы, и лишь затем — прямые ссылки/iframe (как резерв).
            if ($Url -match '(?i)jut\.su|yummyani|animego|anilibria|aniliberty|animedia|anime365|smotret-anime|animelib|animevost') {
                $ap = Fetch $Url $Url
                if ($ap.ok -and -not (Test-Antibot $ap.text $ap.code) -and -not (Test-Drm $ap.text)) {
                    $at = Get-PageTitle $ap.text
                    if ($at) {
                        Log ('anime site title: ' + $at)
                        $ani = Find-AniSeasons $at
                        if ($ani.Count -gt 0) {
                            $atop = [string]$ani[0].name
                            if ($ani[0].base) { $atop = [string]$ani[0].base }
                            Out-Json (New-Result $true $atop @($ani[0].voices) $false '' $ani '' 'anime')
                        }
                    }
                }
            }

            if ($Url -match '\.(m3u8|mp4)(\?|$)') {
                $eps = New-Object System.Collections.ArrayList
                Add-Unique $eps $Url 'Прямой поток'
                $seasons = @([ordered]@{
                    name    = 'Прямой поток'
                    short   = ''
                    year    = ''
                    source  = 'direct'
                    release = 0
                    voices  = @([ordered]@{ name = 'Прямой поток'; episodes = @($eps); source = 'direct' })
                })
                Out-Json (New-Result $true 'Прямой поток' @($seasons[0].voices) $false '' $seasons '' 'direct')
            }

            $yt = Run-YtdlpSmart $Url
            $conv = Convert-YtdlpResult $yt $Url
            if ($conv) {
                $seasons = @([ordered]@{
                    name    = $conv.title
                    short   = ''
                    year    = ''
                    source  = 'yt-dlp'
                    release = 0
                    voices  = @($conv.voices)
                })
                Out-Json (New-Result $true $conv.title @($conv.voices) $false '' $seasons '' 'video')
            }

            # Аниме-каталог по ссылке
            if ($Url -match '(?i)anilibria|aniliberty') {
                $ani = Try-AniLibria $Url ''
                if ($ani) {
                    Out-Json (New-Result $true $ani.title @($ani.seasons[0].voices) $false '' $ani.seasons '' 'anime')
                }
            }

            # ---------- HTML-страница ----------
            $page = Fetch $Url $Url
            if (-not $page.ok -and $page.code -eq 0) {
                Out-Json (New-Result $false '' @() $true $script:AntibotMsg)
            }
            if ($page.ok -and (Test-Drm $page.text)) {
                Out-Json (New-Result $false '' @() $true $script:AntibotMsg)
            }
            $html = [string]$page.text
            $title = Get-PageTitle $html
            if ($page.ok -and (Test-Antibot $html $page.code)) {
                # Закрытая страница: название из title ещё может пригодиться
                if ($title -and $page.code -eq 200) {
                    Log ('closed page title: ' + $title)
                    $query = $title
                } else {
                    Out-Json (New-Result $false $title @() $true $script:AntibotMsg)
                }
            } elseif (-not $query) {
                if ($title) { $query = $title }

                $voices = New-Object System.Collections.ArrayList
                $directLinks = Get-MediaLinks $html $Url
                if ($directLinks.Count -gt 0) {
                    [void]$voices.Add([ordered]@{ name = 'Оригинал'; episodes = @($directLinks) })
                }

                $iframes = Get-Iframes $html $Url
                $vi = 0
                foreach ($ifr in $iframes) {
                    if ($vi -ge 8) { break }
                    $sub = Fetch $ifr $Url
                    if (-not $sub.ok -or -not $sub.text) { continue }
                    $vi++
                    $subText = [string]$sub.text
                    $names = Get-TranslationNames $subText
                    $links = Get-EpisodeLinks $subText $ifr
                    $subDirect = Get-MediaLinks $subText $ifr
                    foreach ($d in $subDirect) {
                        $exists = $false
                        foreach ($l in $links) { if ($l.url -eq $d.url) { $exists = $true; break } }
                        if (-not $exists) { [void]$links.Add($d) }
                    }
                    if ($links.Count -eq 0) { continue }
                    $vname = 'Озвучка ' + $vi
                    if ($names.Count -gt 0) { $vname = [string]$names[0] }
                    $dup = $false
                    foreach ($v in $voices) { if ($v.name -eq $vname) { $dup = $true; break } }
                    if ($dup) { $vname = $vname + ' #' + $vi }
                    [void]$voices.Add([ordered]@{ name = $vname; episodes = @($links) })
                }

                $clean = New-Object System.Collections.ArrayList
                $seen = @{}
                foreach ($v in $voices) {
                    if (-not $v.episodes -or $v.episodes.Count -eq 0) { continue }
                    $key = (($v.episodes | ForEach-Object { $_.url }) -join '|')
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    [void]$clean.Add($v)
                }
                if ($clean.Count -gt 0) {
                    if (-not $title) { $title = 'Онлайн-тайтл' }
                    $seasons = @([ordered]@{
                        name = $title; short = ''; year = ''; source = $Url; release = 0; voices = @($clean)
                    })
                    Out-Json (New-Result $true $title @($clean) $false '' $seasons '' 'video')
                }
            }
        } else {
            $query = Clean-Title $Url
        }
    }

    if (-not $query) {
        Out-Json (New-Result $false '' @() $false $script:NoTitleMsg)
    }

    Log ('title search: ' + $query)

    # ---------- 2. Аниме: AniLiberty ----------
    $seasons = Find-AniSeasons $query
    if ($seasons.Count -gt 0) {
        $first = $seasons[0]
        $topTitle = $first.name
        if ($first.base) { $topTitle = [string]$first.base }
        Out-Json (New-Result $true $topTitle @($first.voices) $false '' $seasons $kpUrl 'anime' $(if ($kp) { $kp.id } else { '' }))
    }

    # ---------- 3. Фильмы и сериалы: открытый поиск ----------
    $movieSeasons = Get-RuTubeSeasons $query
    $ruVoices = @()
    if ($movieSeasons.Count -gt 0) { $ruVoices = @($movieSeasons[0].voices) }
    # RuTube заблокирован, дал слишком мало вариантов или ни одного точного
    # попадания (только «по мотивам») — дополняем открытым поиском yt-dlp,
    # чтобы у пользователя всегда был выбор источника.
    if ($ruVoices.Count -lt 3 -or [int]$script:RuTopRel -lt 60) {
        $ytSeasons = Get-YtSearchSeasons $query
        if ($ytSeasons.Count -gt 0) {
            $ytSeasons[0].voices = @($ruVoices) + @($ytSeasons[0].voices)
            $movieSeasons = $ytSeasons
        }
    }
    if ($movieSeasons.Count -gt 0) {
        $first = $movieSeasons[0]
        $topTitle = $first.name
        if ($first.base) { $topTitle = [string]$first.base }
        Out-Json (New-Result $true $topTitle @($first.voices) $false '' $movieSeasons $kpUrl 'movie' $(if ($kp) { $kp.id } else { '' }))
    }

    # ---------- 4. Ничего не нашли ----------
    if ($kp) {
        Out-Json (New-Result $false $kpTitle @() $true $script:AntibotMsg @() $kpUrl 'kp' $kp.id)
    }
    Out-Json (New-Result $false $query @() $false 'Не удалось найти видео по названию. Проверьте написание или откройте фильм в браузере (Magpie).' @() $kpUrl 'movie')
} catch {
    Out-Json (New-Result $false '' @() $false ('Ошибка поиска: ' + $_.Exception.Message))
}
