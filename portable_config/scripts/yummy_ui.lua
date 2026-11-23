-- =========================================================
--  yummy_ui.lua — кастомный интерфейс «аниме-плеера» для mpv
--  Рисуется только через mp.assdraw (без внешних зависимостей).
--  Шапка: выбор аудио/субтитров + горизонтальный список серий.
--  Подвал: синий прогресс-бар, громкость, время, CC, настройки,
--  мини-режим и полный экран.
-- =========================================================

local mp = require 'mp'
local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

-- Единый контейнер кэшей и служебных флагов интерфейса.
-- ВАЖНО: главный чанк этого скрипта уже у предела LuaJIT (200 локальных
-- переменных/функций на функцию), поэтому вся новая «инфраструктура»
-- живёт полями одной таблицы, а не отдельными local-переменными.
local RT = {
    bgr = {}, tags = {}, clean = {}, txt = {},  -- кэши строк/цветов
    nclean = 0, ntxt = 0,                       -- счётчики для сброса кэшей
    mx = 0, my = 0, mok = false,                -- позиция курсора на кадр
    pending = false,                            -- отложенная перерисовка
    regpush = 0, qmeta = 0,                     -- троттлинг диска/отладки
}

local FONT      = 'Segoe UI'
local PAD       = 22       -- базовый отступ (при 720p)
local HIDE_SEC  = 2.5      -- через сколько секунд прятать интерфейс и курсор

-- --------------------------------------------------------- палитра
local COL = {
    bg     = '141416',
    bg2    = '1f1f23',
    bg3    = '27272a',
    green  = '22c55e',
    blue   = '3b82f6',
    blue2  = '60a5fa',
    text   = 'f4f4f5',
    muted  = 'a1a1aa',
    subtle = '71717a',
    border = '52525b',
    dark   = '0b0b0d',
}

-- Кэш цветовых тегов. rr()/txt()/иконки вызывают tags() десятки раз за кадр,
-- а набор цветов и альф постоянный. Без кэша каждый вызов — string.sub +
-- string.format + конкатенации, то есть постоянный мусор для GC Lua.
local function bgr(hex)
    local v = RT.bgr[hex]
    if v then return v end
    v = hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2)
    RT.bgr[hex] = v
    return v
end

local function tags(hex, alpha)
    local a = alpha or 0
    local by_alpha = RT.tags[hex]
    if not by_alpha then
        by_alpha = {}
        RT.tags[hex] = by_alpha
    end
    local v = by_alpha[a]
    if v then return v end
    v = '\\1c&H' .. bgr(hex) .. '&\\1a&H' .. string.format('%02X', a) .. '&'
    by_alpha[a] = v
    return v
end

-- --------------------------------------------------------- состояние
local st = {
    duration   = 0,
    time_pos   = 0,
    pause      = false,
    volume     = 100,
    mute       = false,
    aid        = 'auto',
    sid        = 'auto',
    vid        = 'auto',
    speed      = 1,
    track_list = {},
    playlist   = {},
    playlist_pos = 0,
    chapters   = {},
    fullscreen = false,
    media_title = '',
    idle       = false,
    skip_used  = false,
    ending_used = false,
}

local visible       = false
local hovering      = false
local last_activity = 0
local last_data     = nil
local last_push     = 0
local menu          = nil
local drag          = nil
local active_region = nil
local pending_click = nil
local dbl_timer     = nil
local sim           = nil
local pl_win_start  = 1
local pl_win_cur    = nil   -- серия, под которую окно ленты уже подъехало
local pl_win_vis    = nil   -- сколько квадратов помещалось при последнем расчёте
local ch_win_start  = 1
local ch_win_cur    = nil   -- последняя глава, к которой окно меню уже подъехало

-- Мастер-список серий текущего сезона. Строится из плейлиста + метаданных
-- (temp_playlist_meta.json): num 1..N, название, ссылки на все качества.
-- Смена качества меняет только URL записи в плейлисте и НЕ разрушает список:
-- номера серий всегда остаются порядковыми 1, 2, 3…
local EPISODES = {
    list      = {},   -- { num, title, url, qualities = {['1080']=url,...}, meta }
    cur       = 0,    -- текущий порядковый номер (1..N)
    quality_h = nil,  -- выбранное пользователем качество (1080/720/480), живёт между сериями
}

-- Курсор мыши синхронизирован с нашей плашкой: пока интерфейс виден —
-- штатное автоскрытие 2.5 с, когда интерфейс спрятан — прячем сразу.
local function cursor_sync(show)
    local want = show and '2500' or 'always'
    if tostring(mp.get_property('cursor-autohide') or '') ~= want then
        mp.set_property('cursor-autohide', want)
    end
end

-- --------------------------------------------------------- thumbfast
-- Превью-кадры таймлайна. thumbfast присылает размеры через
-- script-message "thumbfast-info" (JSON), а готовый кадр — через
-- "thumbfast-render". Рисуем кадр сами через overlay-add, чтобы
-- карточка (#141416 + рамка) и текст были частью нашего интерфейса.
local thumb = {
    width = 0, height = 0,
    disabled = true, available = false,
}
local thumb_img     = nil   -- { path, w, h, id }
local thumb_visible = false -- overlay добавлен
local thumb_shown   = false -- запрос к thumbfast активен
local thumb_pos     = nil   -- { x, y } верхнего левого угла кадра
local thumb_req_t   = nil   -- время последнего запроса кадра
local thumb_req_at  = nil   -- wall-clock последнего запроса (антидребезг)
local thumb_card    = nil   -- прямоугольник карточки превью (удержание кадра)
local thumb_freeze  = nil   -- { x } позиция курсора в момент последнего наведения на бар

-- Антидребезг запросов к thumbfast: не чаще 1 раза в 0.05 с и только если
-- время под курсором сдвинулось минимум на 0.5 с. Очередь подпроцесса не
-- забивается, и кадры плавно меняются вслед за курсором, а не «залипают».
local THUMB_REQ_MIN_DT   = 0.5
local THUMB_REQ_MIN_WALL = 0.05

-- --------------------------------------------------------- строки
-- Кэш очистки текста: названия серий, метки треков и время повторяются
-- из кадра в кадр, а два gsub на каждый вызов — лишняя работа и мусор.
local function clean(s)
    s = tostring(s or '')
    local v = RT.clean[s]
    if v then return v end
    v = s:gsub('[\r\n\t]', ' '):gsub('[{}]', '')
    -- Ограниченный кэш: старые записи сбрасываем, память не растёт.
    if RT.nclean >= 400 then
        RT.clean, RT.nclean = {}, 0
    end
    RT.clean[s] = v
    RT.nclean = RT.nclean + 1
    return v
end

local function utf8_head(s, n)
    local count, i = 0, 1
    while i <= #s and count < n do
        local b = s:byte(i)
        local len = 1
        if b >= 240 then len = 4
        elseif b >= 224 then len = 3
        elseif b >= 192 then len = 2 end
        i = i + len
        count = count + 1
    end
    return s:sub(1, i - 1)
end

local function utf8_len(s)
    local n = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 128 or b >= 192 then n = n + 1 end
    end
    return n
end

local function tw(s, px)
    return utf8_len(s) * px * 0.55
end

local function fit(s, maxw, px)
    s = clean(s)
    if tw(s, px) <= maxw then return s end
    local maxchars = math.max(1, math.floor(maxw / (px * 0.55)))
    if maxchars <= 1 then return '…' end
    return utf8_head(s, maxchars - 1) .. '…'
end

local function fmt_time(t)
    t = tonumber(t) or 0
    if t < 0 then t = 0 end
    t = math.floor(t + 0.5)
    local h = math.floor(t / 3600)
    local m = math.floor((t % 3600) / 60)
    local s = t % 60
    if h > 0 then return string.format('%d:%02d:%02d', h, m, s) end
    return string.format('%02d:%02d', m, s)
end

local function fmt_time_floor(t)
    t = tonumber(t) or 0
    if t < 0 then t = 0 end
    t = math.floor(t)
    local h = math.floor(t / 3600)
    local m = math.floor((t % 3600) / 60)
    local s = t % 60
    if h > 0 then return string.format('%d:%02d:%02d', h, m, s) end
    return string.format('%02d:%02d', m, s)
end

-- --------------------------------------------------------- примитивы ASS
local function rr(ass, x0, y0, x1, y1, r, hex, alpha)
    if x1 < x0 then x0, x1 = x1, x0 end
    if y1 < y0 then y0, y1 = y1, y0 end
    r = r or 0
    local half_w, half_h = (x1 - x0) / 2, (y1 - y0) / 2
    if r < 0 then r = 0 elseif r > half_w then r = half_w end
    if r > half_h then r = half_h end
    ass:new_event()
    ass:append('{\\an7\\pos(0,0)\\p1\\bord0\\shad0' .. tags(hex, alpha) .. '}')
    ass:draw_start()
    if r > 0.5 then
        ass:round_rect_cw(x0, y0, x1, y1, r)
    else
        ass:rect_cw(x0, y0, x1, y1)
    end
    ass:draw_stop()
end

local function rr_ring(ass, x0, y0, x1, y1, r, th, hex, alpha)
    r = r or 0
    local half_w, half_h = (x1 - x0) / 2, (y1 - y0) / 2
    if r < 0 then r = 0 elseif r > half_w then r = half_w end
    if r > half_h then r = half_h end
    th = th or 1
    if th < 0.6 then th = 0.6 end
    ass:new_event()
    ass:append('{\\an7\\pos(0,0)\\p1\\bord0\\shad0' .. tags(hex, alpha) .. '}')
    ass:draw_start()
    ass:round_rect_cw(x0, y0, x1, y1, r)
    local inner = r - th
    if inner < 0 then inner = 0 end
    ass:round_rect_ccw(x0 + th, y0 + th, x1 - th, y1 - th, inner)
    ass:draw_stop()
end

local function rr_stroke(ass, x0, y0, x1, y1, r, th, hex, alpha)
    r = r or 0
    local half_w, half_h = (x1 - x0) / 2, (y1 - y0) / 2
    if r < 0 then r = 0 elseif r > half_w then r = half_w end
    if r > half_h then r = half_h end
    th = th or 1
    if th < 0.6 then th = 0.6 end
    ass:new_event()
    ass:append('{\\an7\\pos(0,0)\\p1\\bord' .. string.format('%.2f', th) ..
        '\\shad0\\3c&H' .. bgr(hex) .. '&\\3a&H' .. string.format('%02X', alpha or 0) .. '&\\1a&HFF&}')
    ass:draw_start()
    ass:round_rect_cw(x0, y0, x1, y1, r)
    ass:draw_stop()
end

local function poly(ass, hex, alpha, pts)
    ass:new_event()
    ass:append('{\\an7\\pos(0,0)\\p1\\bord0\\shad0' .. tags(hex, alpha) .. '}')
    ass:draw_start()
    ass:move_to(pts[1][1], pts[1][2])
    for i = 2, #pts do ass:line_to(pts[i][1], pts[i][2]) end
    ass:draw_stop()
end

local function stroke(ass, pts, th, hex, alpha)
    ass:new_event()
    ass:append('{\\an7\\pos(0,0)\\p1\\bord' .. string.format('%.2f', th) ..
        '\\shad0\\3c&H' .. bgr(hex) .. '&\\3a&H' .. string.format('%02X', alpha or 0) .. '&\\1a&HFF&}')
    ass:draw_start()
    ass:move_to(pts[1][1], pts[1][2])
    for i = 2, #pts do ass:line_to(pts[i][1], pts[i][2]) end
    ass:draw_stop()
end

-- Кэш «шапки» текстового тега: у названий серий/меню шрифт и цвета
-- повторяются кадр в кадр — собираем строку один раз, а не 60 раз в секунду.
-- Позиция входит в ключ (в теге есть \\pos), иначе текст «прилипал» бы к
-- координатам первого вызова.
local function txt(ass, x, y, an, px, hex, alpha, s, bold, font)
    local key = an .. '|' .. x .. '|' .. y .. '|' .. px .. '|' .. hex .. '|' ..
        (alpha or 0) .. '|' .. (bold and 1 or 0) .. '|' .. (font or FONT)
    local tag = RT.txt[key]
    if not tag then
        tag = string.format('{\\an%d\\pos(%.1f,%.1f)\\fn%s\\fs%.1f\\b%d\\bord0\\shad0%s\\q2}',
            an, x, y, font or FONT, px, bold and 1 or 0, tags(hex, alpha))
        if RT.ntxt >= 800 then
            RT.txt, RT.ntxt = {}, 0
        end
        RT.txt[key] = tag
        RT.ntxt = RT.ntxt + 1
    end
    ass:new_event()
    ass:append(tag)
    ass:append(clean(s))
end

-- --------------------------------------------------------- иконки
local function ic_play(ass, cx, cy, u, hex, alpha)
    poly(ass, hex, alpha, {
        { cx - u * 0.34, cy - u * 0.48 },
        { cx + u * 0.46, cy },
        { cx - u * 0.34, cy + u * 0.48 },
    })
end

local function ic_pause(ass, cx, cy, u, hex, alpha)
    local w = u * 0.17
    local h = u * 0.48
    rr(ass, cx - u * 0.30, cy - h, cx - u * 0.30 + w, cy + h, u * 0.05, hex, alpha)
    rr(ass, cx + u * 0.13, cy - h, cx + u * 0.13 + w, cy + h, u * 0.05, hex, alpha)
end

local function ic_volume(ass, cx, cy, u, hex, alpha, muted)
    poly(ass, hex, alpha, {
        { cx - u * 0.62, cy - u * 0.18 },
        { cx - u * 0.36, cy - u * 0.18 },
        { cx - u * 0.08, cy - u * 0.44 },
        { cx - u * 0.08, cy + u * 0.44 },
        { cx - u * 0.36, cy + u * 0.18 },
        { cx - u * 0.62, cy + u * 0.18 },
    })
    if muted then
        poly(ass, hex, alpha, {
            { cx + u * 0.06, cy - u * 0.40 },
            { cx + u * 0.15, cy - u * 0.40 },
            { cx + u * 0.48, cy + u * 0.40 },
            { cx + u * 0.39, cy + u * 0.40 },
        })
    else
        stroke(ass, {
            { cx + u * 0.06, cy - u * 0.20 },
            { cx + u * 0.20, cy },
            { cx + u * 0.06, cy + u * 0.20 },
        }, math.max(1, u * 0.09), hex, alpha)
        stroke(ass, {
            { cx + u * 0.22, cy - u * 0.36 },
            { cx + u * 0.38, cy },
            { cx + u * 0.22, cy + u * 0.36 },
        }, math.max(1, u * 0.09), hex, alpha)
    end
end

local function ic_fullscreen(ass, cx, cy, u, hex, alpha)
    local d = u * 0.46
    local L = u * 0.26
    local th = math.max(1, u * 0.10)
    local function bracket(sx, sy)
        stroke(ass, {
            { cx + sx * (d - L), cy + sy * d },
            { cx + sx * d, cy + sy * d },
            { cx + sx * d, cy + sy * (d - L) },
        }, th, hex, alpha)
    end
    bracket(-1, -1)
    bracket(1, -1)
    bracket(-1, 1)
    bracket(1, 1)
end

local function ic_mini(ass, cx, cy, u, hex, alpha)
    local th = math.max(1, u * 0.09)
    rr_stroke(ass, cx - u * 0.50, cy - u * 0.40, cx + u * 0.10, cy + u * 0.34, u * 0.08, th, hex, alpha)
    rr_stroke(ass, cx - u * 0.10, cy - u * 0.06, cx + u * 0.50, cy + u * 0.42, u * 0.08, th, hex, alpha)
end

local function ic_gear(ass, cx, cy, u, hex, alpha)
    local th = math.max(1, u * 0.095)
    local R = u * 0.32
    local r1, r2 = u * 0.30, u * 0.45
    for k = 0, 7 do
        local a = k * math.pi / 4
        local da = 0.21
        local tip = da * 0.62
        poly(ass, hex, alpha, {
            { cx + math.cos(a - da) * r1, cy + math.sin(a - da) * r1 },
            { cx + math.cos(a - tip) * r2, cy + math.sin(a - tip) * r2 },
            { cx + math.cos(a + tip) * r2, cy + math.sin(a + tip) * r2 },
            { cx + math.cos(a + da) * r1, cy + math.sin(a + da) * r1 },
        })
    end
    rr_ring(ass, cx - R, cy - R, cx + R, cy + R, R, th, hex, alpha)
end

local function ic_skip(ass, cx, cy, u, hex, alpha)
    poly(ass, hex, alpha, {
        { cx - u * 0.52, cy - u * 0.36 },
        { cx - u * 0.10, cy },
        { cx - u * 0.52, cy + u * 0.36 },
    })
    poly(ass, hex, alpha, {
        { cx - u * 0.08, cy - u * 0.36 },
        { cx + u * 0.34, cy },
        { cx - u * 0.08, cy + u * 0.36 },
    })
end

-- --------------------------------------------------------- профиль GPU
-- Класс видеокарты определяет лаунчер (Win32_VideoController) и передаёт
-- tier через script-opts / env / portable_config/gpu_profile.txt. Если mpv
-- запущен напрямую, скрипт один раз читает имена и объём памяти адаптеров.
-- hq   = дискретная игровая карта (NVIDIA RTX/GTX, Radeon RX, Intel Arc,
--        Apple M1/M2/M3/M4)
-- lite = встроенная/офисная (Intel UHD/Iris, Vega/Radeon Graphics, MX/GT,
--        виртуальные адаптеры)
RT.gpu = { tier = 'hq', name = '', source = 'default', on_ready = nil }

do
    local G = RT.gpu

    local function norm_tier(v)
        if not v then return nil end
        v = tostring(v):lower():gsub('%s+', '')
        if v == 'lite' or v == 'low' or v == 'fast' or v == 'igpu'
            or v == 'integrated' or v == 'weak' then
            return 'lite'
        end
        if v == 'hq' or v == 'high' or v == 'full' or v == 'strong' then
            return 'hq'
        end
        return nil
    end

    local function read_file(path)
        if not path or path == '' then return nil end
        local f = io.open(path, 'rb')
        if not f then return nil end
        local data = f:read('*a')
        f:close()
        return data
    end

    local function set_tier(tier, name, source)
        local old = G.tier
        G.tier = norm_tier(tier) or G.tier or 'hq'
        if name and name ~= '' then G.name = name end
        if source then G.source = source end
        msg.verbose(string.format('gpu: tier=%s source=%s name=%s',
            G.tier, tostring(G.source), tostring(G.name)))
        if G.on_ready and old ~= G.tier then G.on_ready(old) end
    end

    -- 1) Профиль, переданный лаунчером (script-opts / env / файл-кэш).
    -- mp.get_opt() принимает полный ключ вида <script>-<option>.
    local opt_tier = nil
    if mp.get_opt then
        opt_tier = mp.get_opt('yummy_ui-gpu_tier') or mp.get_opt('gpu_tier')
    end
    if norm_tier(opt_tier) then
        set_tier(opt_tier, nil, 'script-opt')
    else
        local env_tier = os.getenv('FILMS4K_GPU_TIER')
        if norm_tier(env_tier) then
            set_tier(env_tier, os.getenv('FILMS4K_GPU_NAME'), 'env')
        else
            local profile_path = mp.command_native({ 'expand-path', '~~/gpu_profile.txt' })
            local text = read_file(profile_path)
            if text then
                local tier = text:match('tier%s*=%s*([%w_%-]+)')
                local name = text:match('name%s*=%s*([^\r\n]+)') or text:match('gpu%s*=%s*([^\r\n]+)')
                if norm_tier(tier) then
                    set_tier(tier, name, 'profile')
                end
            end
        end
    end

    -- 2) Если профиля нет (mpv.exe запущен напрямую) — один раз читаем WMI.
    local function classify(text)
        local high = false
        local names = {}
        for line in tostring(text or ''):gmatch('[^\r\n]+') do
            local name, ram = line:match('^(.-)|(%d+)%s*$')
            if not name then name, ram = line:match('^(.-)|%s*$') end
            name = (name or line):gsub('^%s+', ''):gsub('%s+$', '')
            if name ~= '' then
                names[#names + 1] = name
                local n = name:lower()
                local skip = n:find('microsoft basic') or n:find('remote display')
                    or n:find('virtual') or n:find('vmware') or n:find('virtualbox')
                    or n:find('parsec') or n:find('citrix') or n:find('sunshine')
                    or n:find('meta virtual')
                if not skip then
                    local vram = tonumber(ram) or 0
                    if n:find('nvidia') or n:find('geforce') or n:find('quadro')
                        or n:find('tesla') or n:find('titan') then
                        if n:find('rtx') or n:find('gtx') or n:find('quadro')
                            or n:find('tesla') or n:find('titan') then
                            high = true
                        end
                    elseif n:find('amd') or n:find('radeon') or n:find('firepro') then
                        if n:find('radeon%s*rx') or n:find('rx%s*%d')
                            or n:find('firepro') or n:find('radeon%s*pro')
                            or n:find('radeon%s*vii') or n:find('radeon%s*r9')
                            or n:find('radeon%s*r7') then
                            -- 4+ ГБ (WMI упирается в 4 ГБ у 8/16-ГБ карт)
                            -- либо заведомо мощная серия RX 5000/6000/7000.
                            if vram >= 3500 * 1024 * 1024 or n:find('rx%s*[567]%d%d%d')
                                or n:find('firepro') or n:find('radeon%s*pro')
                                or n:find('radeon%s*vii') or n:find('radeon%s*r9') then
                                high = true
                            end
                        end
                    elseif n:find('intel') then
                        -- Intel Arc A770/B580… — дискретная; «Arc Graphics»
                        -- без индекса A/B остаётся встроенной и идёт в lite.
                        if n:find('arc') and (n:find('[ab]%d%d%d') or n:find('arc.*pro')) then
                            high = true
                        end
                    elseif n:find('apple') then
                        -- Apple Silicon: единая память и очень быстрый
                        -- Metal-бэкенд — держим полноценные VL-шейдеры.
                        if n:find('apple%s*m%d') or n:find('apple%s*m%d%s') then
                            high = true
                        end
                    end
                end
            end
        end
        return (high and 'hq' or 'lite'), table.concat(names, ' + ')
    end

    if G.source == 'default' then
        -- Профиль ещё не задан (mpv запущен напрямую, без лаунчера).
        -- Определяем GPU средствами самой ОС:
        --   Windows — WMI/CIM (Win32_VideoController);
        --   Linux   — lspci + glxinfo;
        --   macOS   — system_profiler SPDisplaysDataType.
        local platform = (mp.get_property('platform') or ''):lower()
        if platform == '' then
            if jit and jit.os == 'Windows' then platform = 'windows'
            elseif jit and jit.os == 'OSX' then platform = 'darwin'
            else platform = 'linux' end
        end

        local function normalize(out)
            out = tostring(out or '')
            local entries = {}
            if platform == 'darwin' then
                local cur
                for line in out:gmatch('[^\r\n]+') do
                    local chip = line:match('Chipset Model:%s*(.+)$')
                    if chip then
                        cur = { name = chip:gsub('%s+$', ''), ram = 0 }
                        entries[#entries + 1] = cur
                    end
                    local num, unit = line:match('VRAM%s*%([^%)]*%):%s*([%d%.]+)%s*(%a+)')
                    if not num then
                        num, unit = line:match('VRAM%s*%(Total%):%s*([%d%.]+)%s*(%a+)')
                    end
                    if num and cur then
                        local n = tonumber(num) or 0
                        local u = (unit or ''):lower()
                        if u == 'gb' then n = n * 1024 * 1024 * 1024
                        elseif u == 'mb' then n = n * 1024 * 1024
                        elseif u == 'kb' then n = n * 1024 end
                        cur.ram = math.floor(n)
                    end
                end
            elseif platform == 'linux' then
                local cur
                for line in out:gmatch('[^\r\n]+') do
                    local name
                    if line:find('VGA compatible controller') or line:find('3D controller')
                        or line:find('Display controller') then
                        name = line:match(':%s*(.+)$')
                    else
                        name = line:match('OpenGL renderer string:%s*(.+)$')
                            or line:match('Device:%s*(.+)$')
                    end
                    if name then
                        name = name:gsub('%s*%(rev[^%)]*%).*$', ''):gsub('%s+$', '')
                        cur = { name = name, ram = 0 }
                        entries[#entries + 1] = cur
                    end
                    local vram = line:match('Video memory:%s*(%d+)%s*MB')
                    if vram and cur then cur.ram = tonumber(vram) * 1024 * 1024 end
                end
            end
            if #entries == 0 then
                -- Не удалось распознать структуру — отдаём как есть, classify
                -- разберёт строки без VRAM.
                return out
            end
            local lines = {}
            for _, e in ipairs(entries) do
                lines[#lines + 1] = e.name .. '|' .. tostring(e.ram)
            end
            return table.concat(lines, '\n')
        end

        local args
        if platform == 'windows' then
            args = {
                'powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive',
                '-ExecutionPolicy', 'Bypass', '-Command',
                "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " ..
                "(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name + '|' + [string]([int64]$_.AdapterRAM) }) -join [char]10"
            }
        elseif platform == 'darwin' then
            args = { 'system_profiler', 'SPDisplaysDataType' }
        else
            args = {
                'sh', '-c',
                '(command -v lspci >/dev/null 2>&1 && lspci -nn 2>/dev/null | grep -Ei "VGA|3D|Display"); ' ..
                'echo "---"; ' ..
                '(command -v glxinfo >/dev/null 2>&1 && glxinfo -B 2>/dev/null | grep -Ei "OpenGL renderer|Device|Video memory")'
            }
        end

        local ok = pcall(function()
            mp.command_native_async({
                name = 'subprocess',
                args = args,
                capture_stdout = true,
                capture_stderr = true,
                playback_only = false,
            }, function(success, result)
                if not success or type(result) ~= 'table' then return end
                local out = normalize(result.stdout or '')
                if out == '' then return end
                local tier, name = classify(out)
                set_tier(tier, name, platform == 'windows' and 'wmi' or 'os')
            end)
        end)
        if not ok then
            msg.warn('gpu: определение через ОС недоступно, профиль по умолчанию hq')
        end
    end
end

-- --------------------------------------------------------- режимы шейдеров
local MODES = {
    {
        label = 'Аниме · Mode A (HQ)',
        osd   = 'Аниме 4K (Mode A HQ)',
        files = {
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Restore_CNN_VL.glsl',
            'Anime4K_Upscale_CNN_x2_VL.glsl', 'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_M.glsl',
        },
        -- Быстрая версия того же пресета Anime4K v4 для встроенных GPU.
        files_lite = {
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Restore_CNN_M.glsl',
            'Anime4K_Upscale_CNN_x2_M.glsl', 'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_S.glsl',
        },
    },
    {
        label = 'Аниме · Mode B (HQ)',
        osd   = 'Аниме 4K (Mode B - для низкого качества)',
        files = {
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Restore_CNN_Soft_VL.glsl',
            'Anime4K_Upscale_CNN_x2_VL.glsl', 'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_M.glsl',
        },
        files_lite = {
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Restore_CNN_Soft_M.glsl',
            'Anime4K_Upscale_CNN_x2_M.glsl', 'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_S.glsl',
        },
    },
    {
        label = 'Аниме · Mode C (HQ)',
        osd   = 'Аниме 4K (Mode C - от шумов)',
        files = {
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl', 'Anime4K_AutoDownscalePre_x4.glsl',
            'Anime4K_Upscale_CNN_x2_M.glsl',
        },
        files_lite = {
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl', 'Anime4K_AutoDownscalePre_x4.glsl',
            'Anime4K_Upscale_CNN_x2_S.glsl',
        },
    },
    {
        label = 'Кино · FSRCNNX',
        osd   = 'Кино и сериалы 4K (FSRCNNX)',
        files = { 'FSRCNNX_x2_16-0-4-1.glsl' },
    },
    {
        -- Реставрация старых фильмов и сериалов: мягкий hqdn3d + денойз Anime4K
        -- + нейросетевой апскейл FSRCNNX. Всегда между «Кино» и «Оригинал».
        label = 'Старое кино · Реставрация',
        osd   = 'Старое кино и сериалы 4K (Реставрация)',
        files = {
            'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Denoise_Bilateral_Mean.glsl',
            'FSRCNNX_x2_16-0-4-1.glsl',
        },
        vf = 'lavfi=[hqdn3d=luma_spatial=2.0:chroma_spatial=1.5:luma_tmp=3.0:chroma_tmp=2.5]',
    },
    {
        label = 'Оригинал · без шейдеров',
        osd   = 'Шейдеры отключены (Оригинал)',
        files = {},
    },
}

local function shader_names()
    local v = mp.get_property_native('glsl-shaders')
    local list = {}
    if type(v) == 'table' then
        for _, p in ipairs(v) do list[#list + 1] = tostring(p) end
    elseif type(v) == 'string' then
        for p in v:gmatch('[^;]+') do list[#list + 1] = p end
    end
    local out = {}
    for _, p in ipairs(list) do
        -- пустой список шейдеров mpv иногда отдаёт как { "" } — отбрасываем
        local name = p:match('([^/\\]+)$') or p
        if name ~= '' then out[#out + 1] = name end
    end
    return out
end

local function current_mode()
    local cur = shader_names()
    local lite = (RT.gpu.tier == 'lite')
    for i, m in ipairs(MODES) do
        local files = m.files
        if lite and m.files_lite and #m.files_lite > 0 then files = m.files_lite end
        if #cur == #files then
            local same = true
            for j = 1, #cur do
                if cur[j] ~= files[j] then same = false; break end
            end
            if same then return i end
        end
    end
    return 0
end

local function apply_mode(idx, silent)
    local m = MODES[idx]
    if not m then return end
    local files = m.files
    -- На встроенных/слабых GPU — быстрые _M/_S вместо тяжёлых _VL.
    if RT.gpu.tier == 'lite' and m.files_lite and #m.files_lite > 0 then
        files = m.files_lite
    end
    -- Любая смена режима начинается с полного сброса видеофильтров:
    -- hqdn3d нужен только реставрации старого кино и не должен висеть
    -- на современных видео (лишняя нагрузка на GPU).
    mp.commandv('vf', 'set', '')
    mp.commandv('change-list', 'glsl-shaders', 'clr', '')
    if #files > 0 then
        local parts = {}
        for _, f in ipairs(files) do parts[#parts + 1] = '~~/shaders/' .. f end
        mp.commandv('change-list', 'glsl-shaders', 'set', table.concat(parts, ';'))
    end
    if m.vf then mp.commandv('vf', 'set', m.vf) end
    if not silent then mp.osd_message('Режим: ' .. m.osd, 2) end
end

-- Профиль мог определиться позже старта (WMI/лаунчер): заменяем уже
-- загруженную HQ-цепочку на быструю, не меняя выбранный пользователем режим.
local function adapt_shaders_to_gpu()
    if RT.gpu.tier ~= 'lite' then return end
    local cur = shader_names()
    for i, m in ipairs(MODES) do
        if #cur == #m.files then
            local same = true
            for j = 1, #cur do
                if cur[j] ~= m.files[j] then same = false; break end
            end
            if same then apply_mode(i, true); return end
        end
    end
end
RT.gpu.on_ready = adapt_shaders_to_gpu
mp.add_timeout(0.3, adapt_shaders_to_gpu)
-- mpv.conf применяет HQ-цепочку к каждому новому файлу: на слабой карте
-- повторяем подмену после загрузки файла (пользовательский выбор режима
-- уже в lite-варианте и под фильтр не попадает).
mp.register_event('file-loaded', adapt_shaders_to_gpu)

-- --------------------------------------------------------- дорожки
local LANG = {
    ru = 'Русский', en = 'Английский', ja = 'Японский', uk = 'Украинский',
    de = 'Немецкий', fr = 'Французский', es = 'Испанский', ko = 'Корейский',
    zh = 'Китайский', it = 'Итальянский', pl = 'Польский', tr = 'Турецкий',
    -- трёхбуквенные коды (mpv/mkvmetadata отдают именно их)
    rus = 'Русский', eng = 'Английский', jpn = 'Японский', ukr = 'Украинский',
    deu = 'Немецкий', ger = 'Немецкий', fra = 'Французский', fre = 'Французский',
    spa = 'Испанский', kor = 'Корейский', zho = 'Китайский', chi = 'Китайский',
    ita = 'Итальянский', pol = 'Польский', tur = 'Турецкий',
}

local function track_items(kind)
    local out = {}
    local tl = st.track_list or {}
    local n = 0
    for _, t in ipairs(tl) do
        if t.type == kind then
            n = n + 1
            local name = t.title
            if not name or name == '' then
                if t.lang and t.lang ~= '' then
                    name = LANG[t.lang] or t.lang:upper()
                else
                    name = 'Дорожка ' .. n
                end
            end
            if t.codec then name = name .. ' · ' .. tostring(t.codec) end
            out[#out + 1] = {
                label    = clean(name),
                selected = (t.selected == true),
                action   = function()
                    local prop = (kind == 'audio') and 'aid' or 'sid'
                    mp.set_property_number(prop, t.id)
                end,
            }
        end
    end
    return out
end

-- Включены ли субтитры: ориентируемся на реально выбранную дорожку,
-- потому что свойство sid бывает false / 'no' / 'auto' / номер.
function subs_enabled()
    for _, t in ipairs(st.track_list or {}) do
        if t.type == 'sub' and t.selected == true then return true end
    end
    return false
end

local function sub_items()
    local on = subs_enabled()
    local out = {
        {
            label    = 'Отключить субтитры',
            selected = not on,
            action   = function() mp.set_property('sid', 'no') end,
        },
    }
    for _, it in ipairs(track_items('sub')) do out[#out + 1] = it end
    out[#out + 1] = {
        label    = '✨ Сгенерировать ИИ-субтитры',
        selected = false,
        ai       = true,
        action   = function() ai_generate() end,
    }
    return out
end

local function current_track_label(kind)
    local n = 0
    for _, t in ipairs(st.track_list or {}) do
        if t.type == kind then
            n = n + 1
            if t.selected == true then
                local name = t.title
                if not name or name == '' then
                    if t.lang and t.lang ~= '' then
                        name = LANG[t.lang] or t.lang:upper()
                    else
                        name = 'Дорожка ' .. n
                    end
                end
                return clean(name)
            end
        end
    end
    if kind == 'sub' then return 'выкл' end
    return 'нет'
end

-- Номер серии для квадратной кнопки. СТРОГО порядковый (1..N).
-- Раньше здесь парсились цифры из title/URL, и после смены качества новая
-- HLS-ссылка с хешем вида «…e149…» или «…e534…» давала мусорные номера.
-- Никакого разбора ссылок: только сохранённый номер или индекс в списке.
local function ep_number(e, i)
    if e and e.episode_num then return e.episode_num end
    return i
end

local function current_op()
    local chs = st.chapters or {}
    for i, ch in ipairs(chs) do
        local name = (ch.title or ''):lower()
        local is_op = name:find('opening', 1, true)
            or name:find('опенинг', 1, true)
            or name:find('заставка', 1, true)
            or name:match('^%s*op[%s%-_:%.]')
            or name:match('^%s*оп[%s%-_:%.]')
        if is_op then
            local nxt = chs[i + 1]
            return {
                start = ch.time,
                stop  = nxt and nxt.time or (ch.time + 90),
            }
        end
    end
    return nil
end

-- Эндинг (ED) — глава с титрами в конце серии
local function current_ed()
    local chs = st.chapters or {}
    for i, ch in ipairs(chs) do
        local name = (ch.title or ''):lower()
        local is_ed = name:find('ending', 1, true)
            or name:find('энд', 1, true)
            or name:find('енд', 1, true)
            or name:find('титры', 1, true)
            or name:find('титра', 1, true)
            or name:find('credits', 1, true)
            or name:find('конец', 1, true)
            or name:match('^%s*ed[%s%-_:%.]')
            or name:match('^%s*ед[%s%-_:%.]')
        if is_ed then
            local nxt = chs[i + 1]
            return {
                start = ch.time,
                stop  = nxt and nxt.time or (ch.time + 90),
            }
        end
    end
    return nil
end

-- --------------------------------------------------------- инфраструктура
local M = { S = 1 }
local regions = {}
local osd = mp.create_osd_overlay('ass-events')
osd.z = 100

local render -- forward declaration
local toggle_mini, toggle_subs

-- --- Коалесценция перерисовок -------------------------------------------
-- Windows присылает mouse_move до 125+ раз в секунду, а полная пересборка
-- ASS-кадра (сотни событий) заметно дороже одного кадра 60 Гц. Складываем
-- все движения в одно отложенное обновление (~12 мс): визуальная плавность
-- не меняется, а Lua/GC получают в 2-4 раза меньше работы.
RT.timer = mp.add_timeout(0.012, function()
    RT.pending = false
    render()
end)
RT.timer:stop()

local function request_render()
    if RT.pending then return end
    RT.pending = true
    RT.timer:resume()
end

local function get_dims()
    local d = mp.get_property_native('osd-dimensions')
    if not d then return 0, 0 end
    return d.w or 0, d.h or 0
end

local function scale_for(H)
    local s = H / 720
    if s < 0.45 then s = 0.45 end
    if s > 3.0 then s = 3.0 end
    return s
end

local function mouse()
    if sim then return sim.x, sim.y end
    -- Курсор запрашивается из ядра mpv до 5 раз за кадр (подвал, шапка,
    -- кнопки пропуска/эндинга, меню). Кэшируем на один кадр.
    if RT.mok then return RT.mx, RT.my end
    RT.mx, RT.my = mp.get_mouse_pos()
    RT.mok = true
    return RT.mx, RT.my
end

local function poke()
    last_activity = mp.get_time()
    -- Любая активность (мышь/клавиши/меню) будит остановленный таймер
    -- панелей. В простое таймер спит: скрипт вообще не просыпается.
    if RT.tick and not RT.tick:is_enabled() then
        RT.tick:resume()
    end
end

local function inside(r, x, y)
    return r and x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2
end

local function reg(x1, y1, x2, y2, down, up)
    regions[#regions + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, down = down, up = up }
end

local function hit(x, y)
    for i = #regions, 1, -1 do
        local r = regions[i]
        if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 then
            return r
        end
    end
    return nil
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- --------------------------------------------------------- аудио: только озвучки
-- В онлайн-потоках (HLS/DASH) mpv показывает каждую muxed-вариацию как
-- отдельную «аудиодорожку» вида "hls-2856 - 1920x1080 muxed-39". Для
-- пользователя это технический мусор, поэтому оставляем только реальные
-- звуковые дорожки (озвучки), а если поток отдаёт один общий звук —
-- одну строку «Основная дорожка».
local function track_is_muxed(t)
    local title = tostring(t.title or ''):lower()
    if title:find('muxed', 1, true) then return true end
    if (tonumber(t['demux-w']) or 0) > 0 then return true end
    if (tonumber(t['demux-h']) or 0) > 0 then return true end
    return false
end

-- Убираем служебный текст: hls-4512, hls_fmp4-12_3-Audio, dash_sep-11,
-- dash_webm-8, "1920x1080", "muxed-39", "(Audio, high)", "(DASH audio)",
-- "(medium)" и т.п. Названия реальных озвучек («Дубляж», «LostFilm»,
-- «English») при этом сохраняются.
local PROTO_PREFIX = {
    'hls_fmp4', 'dash_webm', 'dash_sep', 'm3u8',
    'hls', 'dash', 'url', 'm4a', 'mp4', 'webm', 'avc1',
    'av01', 'av1', 'vp09', 'opus',
}

-- Срезает протокольный префикс с числовым id и разделителем:
-- "hls_fmp4-12_3-Audio" -> "Audio", "dash_webm-8" -> "".
local function strip_proto_prefix(s)
    for _ = 1, 4 do
        local low = s:lower()
        local cut = false
        for _, p in ipairs(PROTO_PREFIX) do
            if low:sub(1, #p) == p then
                local rest = s:sub(#p + 1)
                local _, tail = rest:match('^([%d_%.%-]*)(.*)$')
                tail = tail:gsub('^%s*[%-–—]?%s*', '')
                if tail ~= s then cut = true; s = tail end
                break
            end
        end
        if not cut then break end
    end
    return s
end

local function strip_technical(s)
    s = tostring(s or '')
    s = s:gsub('%b()', function(p)
        local inner = p:sub(2, -2):lower()
        if inner:find('audio') or inner:find('video') or inner:find('dash')
            or inner:find('hls') or inner:find('muxed') or inner:find('drc')
            or inner:find('default') or inner:find('medium') or inner:find('high')
            or inner:find('low') or inner:match('^%s*%d+[xх×]%d+%s*$')
            or inner:match('^%s*%d+p%s*$') then
            return ''
        end
        return p
    end)
    -- Сначала размеры, потом протокольный префикс: иначе "hls-720p" срежется
    -- до огрызка "p".
    s = s:gsub('%s*%-?%s*%d+[xх×]%d+%s*', ' ') -- 1920x1080
    s = s:gsub('%f[%d]%d+[pP]%f[%A]', ' ')     -- 1080p
    s = strip_proto_prefix(s)
    s = s:gsub('%f[%a]muxed[%w%._%-]*', '')
    s = s:gsub('%-?%s*%f[%a]drc%f[%A]', '')     -- 251-drc -> 251 (DRC-дубль)
    s = s:gsub('%f[%a]audio only%f[%A]', '')
    s = s:gsub('%f[%a]video only%f[%A]', '')
    -- «Audio», «Audio 1», «Audio track» без языка — не название озвучки.
    if s:match('^%s*[Aa]udio[%s%d%-_]*$') or s:match('^%s*[Aa]udio track%s*$') then s = '' end
    s = s:gsub('%s*%-%s*%d+%s*$', '')          -- хвост вида "- 43"
    s = strip_proto_prefix(s)
    s = s:gsub('%s+', ' ')
    s = s:gsub('^[%s%-–—·:]+', ''):gsub('[%s%-–—·:]+$', '')
    -- Расширение файла-дорожки (mt_audio2.mka -> mt_audio2) — это не название.
    s = s:gsub('%.%w%w%w?%w?$', '')
    return s
end

-- Язык дорожки человекочитаемо: «Русский», «Японский», «Английский» …
local function audio_lang_name(t)
    local l = tostring(t.lang or ''):lower()
    if l == '' or l == 'und' or l == 'unknown' or l == 'mul' then return nil end
    return LANG[l] or l:upper()
end

-- Название студии/озвучки из метаданных (AniLibria, Дубляж, Original …).
-- Технические подписи (кодеки, muxed, id вида 251) и просто название языка
-- студией не считаются.
local function audio_studio_name(t)
    local s = strip_technical(t.title)
    if s == '' or s:match('^[%d%s_%.%-]*$') then return nil end
    local ln = audio_lang_name(t)
    if ln and s:lower() == ln:lower() then return nil end
    if t.lang and t.lang ~= '' and s:lower() == tostring(t.lang):lower() then return nil end
    local low = s:lower()
    if low:find('оригинал') or low:find('original') then return 'Оригинал' end
    return s
end

-- Красивое имя дорожки: «Русский (AniLibria)», «Японский (Оригинал)»,
-- «Английский». Если метаданных нет — nil, вызывающий сам решит, что писать.
local function audio_display_name(t)
    local ln = audio_lang_name(t)
    local stn = audio_studio_name(t)
    if stn and ln then return ln .. ' (' .. stn .. ')' end
    if stn then return stn end
    if ln then return ln end
    return nil
end

local function audio_items()
    local tracks = {}
    for _, t in ipairs(st.track_list or {}) do
        if t.type == 'audio' and not t.albumart then tracks[#tracks + 1] = t end
    end

    local real = {}
    for _, t in ipairs(tracks) do
        if not track_is_muxed(t) then real[#real + 1] = t end
    end
    local use = (#real > 0) and real or tracks

    local function make_item(name, t, selected)
        return {
            name     = name,
            label    = clean(name),
            selected = selected == true,
            action   = function() mp.set_property_number('aid', t.id) end,
        }
    end

    local out = {}

    -- В сети mpv отдаёт каждую HLS/DASH-вариацию как отдельную «дорожку»
    -- (av1-6 · opus, hls-…, dash_…). Группируем по человекочитаемому имени,
    -- чтобы технические дубли схлопнулись в один пункт.
    local function grouped()
        local groups, order = {}, {}
        for _, t in ipairs(use) do
            local key = audio_display_name(t) or ''
            local g = groups[key]
            if not g then
                g = { key = key, rep = t, selected = false }
                groups[key] = g
                order[#order + 1] = g
            end
            if t.selected == true then g.selected, g.rep = true, t end
        end
        for _, t in ipairs(tracks) do
            if t.selected == true then
                local g = groups[audio_display_name(t) or '']
                if g then g.selected = true end
            end
        end
        return order
    end

    if mp.get_property_bool('demuxer-via-network') == true then
        local order = grouped()
        if #order <= 1 then
            -- одна основная дорожка или технические дубли без метаданных —
            -- показываем один понятный пункт вместо списка кодеков
            local rep = order[1] and order[1].rep or tracks[1]
            if rep then out[#out + 1] = make_item('Основная дорожка (Оригинал)', rep, true) end
        else
            for _, g in ipairs(order) do
                out[#out + 1] = make_item(g.key ~= '' and g.key or 'Дорожка', g.rep, g.selected)
            end
        end
    else
        local n = 0
        for _, t in ipairs(use) do
            n = n + 1
            local name = audio_display_name(t)
            if not name then
                name = (#use == 1) and 'Основная дорожка (Оригинал)' or ('Дорожка ' .. n)
            end
            out[#out + 1] = make_item(name, t, t.selected)
        end
    end
    return out
end

local function audio_label_current()
    local items = audio_items()
    for _, it in ipairs(items) do
        if it.selected then return it.name end
    end
    if items[1] then return items[1].name end
    return 'нет'
end

-- --------------------------------------------------------- качество видео
local function res_label(w, h)
    local p = 0
    if w > 0 and h > 0 then p = math.min(w, h) else p = h end
    if p <= 0 then return nil end
    if p >= 2160 then return '2160p (4K)' end
    if p >= 1440 then return '1440p (2K)' end
    if p >= 1080 then return '1080p (Full HD)' end
    if p >= 720 then return '720p (HD)' end
    return p .. 'p'
end

-- --------------------------------------------------------- качество (vid / ytdl)
-- Онлайн (YouTube, VK Видео, RuTube): видео и звук часто идут отдельными
-- DASH-потоками, а HLS отдаёт несколько muxed-вариаций.
-- Переключение двухэтапное:
--   А) если в потоке уже есть видеодорожка нужной высоты (demux-h) —
--      просто переключаем vid, без перезагрузки;
--   Б) если поток загружен одним файлом (yt-dlp/HLS) — задаём ytdl-format
--      и перезагружаем поток с той же секунды.
-- Локальные файлы не перезагружаются: в меню только их разрешение.
local QUALITY_PRESETS = {
    { label = 'Авто (Максимальное)', fmt = 'bestvideo+bestaudio/best', auto = true },
    { label = '1080p (Full HD)', h = 1080, fmt = 'bestvideo[height<=?1080]+bestaudio/best[height<=?1080]' },
    { label = '720p (HD)',       h = 720,  fmt = 'bestvideo[height<=?720]+bestaudio/best[height<=?720]' },
    { label = '480p',            h = 480,  fmt = 'bestvideo[height<=?480]+bestaudio/best[height<=?480]' },
    { label = '360p',            h = 360,  fmt = 'bestvideo[height<=?360]+bestaudio/best[height<=?360]' },
}

-- Что восстановить после перезагрузки потока (loadfile replace).
local pending_reload = nil
-- Выбранное пользователем качество до подтверждения реальной высотой кадра:
-- { label = ..., h = <высота или nil>, at = <время>, reload = bool, loaded = bool }
local quality_target = nil
-- Ручной выбор из меню «Качество». Он главнее video-params/h: широкий поток
-- 854x360, помеченный как 480p, не должен сам превращаться в «360p».
-- { label, h, url = <адрес варианта>, path = <адрес ролика>, at }
local quality_pick = nil
-- Максимальное качество, реально виденное у текущего ролика. Список в меню
-- не должен предлагать варианты выше источника, но и не должен «схлопываться»
-- после временного понижения качества (иначе с 720p нельзя вернуться на 1080p).
local quality_seen_max = 0
local quality_seen_path = nil
-- Объявлено заранее: нужно функции перезагрузки потока (ниже идёт SOUND).
local sound_mode = 1

-- Нормализация пути/URL для сравнения (Windows-слэши, file://).
local function quality_norm_url(s)
    s = tostring(s or '')
    s = s:gsub('^file:///', '')
    s = s:gsub('\\', '/')
    return s
end

-- Запомнить ручной выбор. url задан для готового HLS-варианта (AniLiberty),
-- иначе качество применяется к текущему пути (yt-dlp / смена дорожки).
local function quality_pick_apply(label, h, url)
    local cur = quality_norm_url(mp.get_property('path'))
    quality_pick = {
        label = label,
        h     = tonumber(h) or nil,
        url   = url and quality_norm_url(url) or nil,
        path  = quality_norm_url(url or cur),
        at    = mp.get_time(),
    }
    -- Запоминаем качество для переключения серий: клик по номеру 1, 2, 3…
    -- запускает серию в этом же качестве, пока пользователь не выберет другое.
    local hh = tonumber(h)
    if hh and hh > 0 then EPISODES.quality_h = hh end
end

local function quality_pick_clear()
    quality_pick = nil
end

-- Ограничение по высоте внутри строки ytdl-format ("height<=?720" -> 720).
local function fmt_height(fmt)
    local s = tostring(fmt or '')
    local h = s:match('height<=%s*%?(%d+)') or s:match('height<=%s*(%d+)')
    return h and tonumber(h) or nil
end

-- Какой пункт списка соответствует текущему ytdl-format. mpv.conf задаёт
-- свой формат (height<=?1080), поэтому сравниваем не только строки целиком,
-- но и ограничение по высоте — иначе в меню не было бы ни одной галочки.
local function preset_is_current(p, cur)
    if cur == p.fmt then return true end
    local ph, ch = fmt_height(p.fmt), fmt_height(cur)
    if p.auto then return ch == nil end
    return ph ~= nil and ch ~= nil and ph == ch
end

local function quality_format_label(fmt)
    local cur = tostring(fmt or '')
    if cur == '' then return nil end
    for _, p in ipairs(QUALITY_PRESETS) do
        if preset_is_current(p, cur) then return p.label end
    end
    return nil
end

-- После смены видеовариации звук не должен пропасть. Смена HLS/DASH-вариации
-- пересобирает список дорожек, поэтому проверяем aid несколько раз:
--  • aid указывает на несуществующую дорожку — берём первую реальную;
--  • aid выключен (false/'no'/'auto') — включаем первую реальную.
local function ensure_audio()
    local tracks = mp.get_property_native('track-list') or {}
    local first_audio, has_audio, aid_valid = nil, false, false
    local aid = mp.get_property_native('aid')
    for _, t in ipairs(tracks) do
        if t.type == 'audio' and not t.albumart then
            has_audio = true
            first_audio = first_audio or t.id
            if t.selected == true then return end -- звук уже играет
            if t.id == aid then aid_valid = true end
        end
    end
    if not has_audio then return end
    if not aid_valid then
        mp.set_property_number('aid', first_audio)
    end
end

-- Несколько попыток: HLS/DASH перестраивают дорожки не мгновенно.
local function ensure_audio_soon()
    for _, d in ipairs({ 0.05, 0.20, 0.60, 1.20 }) do
        mp.add_timeout(d, ensure_audio)
    end
end

-- Уведомление о смене качества: 2 секунды в левом верхнем углу.
-- Отдельный ASS-overlay: глобальные настройки OSD (и чужие сообщения mpv)
-- не трогаем, позиция — только у этого сообщения.
local qnotify_osd = mp.create_osd_overlay('ass-events')
qnotify_osd.z = 110
local qnotify_token = 0
local function quality_notify(label)
    if not label or label == '' then return end
    local W, H = get_dims()
    if W <= 0 or H <= 0 then return end
    qnotify_token = qnotify_token + 1
    local token = qnotify_token
    local S = scale_for(H)
    local fs = math.max(14, math.floor(16 * S + 0.5))
    qnotify_osd.res_x = W
    qnotify_osd.res_y = H
    qnotify_osd.data = string.format(
        '{\\an7\\pos(%d,%d)\\fs%d\\bord2.2\\shad0\\c&HFFFFFF&}Качество видео: %s',
        math.floor(20 * S), math.floor(96 * S), fs, label)
    qnotify_osd:update()
    mp.add_timeout(2.0, function()
        if token ~= qnotify_token then return end
        qnotify_osd.data = ''
        qnotify_osd:update()
    end)
end

-- Размер кадра текущего видео: ширина и высота.
local function quality_actual_wh()
    local w, h = 0, 0
    local cur = mp.get_property_native('current-tracks/video')
    if cur then
        w = tonumber(cur['demux-w']) or tonumber(cur.width) or 0
        h = tonumber(cur['demux-h']) or tonumber(cur.height) or 0
    end
    if h <= 0 then
        w = mp.get_property_number('video-params/w') or 0
        h = mp.get_property_number('video-params/h') or 0
    end
    if h <= 0 then
        for _, t in ipairs(mp.get_property_native('track-list') or {}) do
            if t.type == 'video' and not t.albumart and t.selected then
                w = tonumber(t['demux-w']) or 0
                h = tonumber(t['demux-h']) or 0
                break
            end
        end
    end
    return w > 0 and w or 0, h > 0 and h or 0
end

-- Короткая сторона кадра (для выбора дорожки и допусков).
local function quality_actual_h()
    local w, h = quality_actual_wh()
    if w > 0 and h > 0 then return math.min(w, h) end
    return h > 0 and h or 0
end

-- «Авто»-подпись качества. Учитываем и ширину, и высоту: широкоформатный
-- поток 854x360 должен называться 480p, а не 360p. Для вертикальных роликов
-- (Shorts) качество определяется по ширине кадра.
local function quality_auto_label(w, h)
    w, h = tonumber(w) or 0, tonumber(h) or 0
    if w <= 0 and h <= 0 then return nil end
    if w > 0 and h > 0 and h > w * 1.15 then
        if w >= 1000 then return '1080p' end
        if w >= 700  then return '720p'  end
        if w >= 460  then return '480p'  end
        if w >= 340  then return '360p'  end
        return '240p'
    end
    if w >= 1900 or h >= 1000 then return '1080p' end
    if w >= 1200 or h >= 700  then return '720p'  end
    if w >= 800  or h >= 460  then return '480p'  end
    if w >= 620  or h >= 330  then return '360p'  end
    return '240p'
end

local function quality_preset_for_h(h)
    if not h or h <= 0 then return nil end
    for _, p in ipairs(QUALITY_PRESETS) do
        if p.h and math.abs(p.h - h) <= math.max(8, p.h * 0.04) then return p end
    end
    return nil
end

-- Допуск при сравнении высот кадра (кодеки/масштабирование дают ±1–2 px).
local function quality_tol(h)
    h = tonumber(h) or 0
    return math.max(8, h * 0.04)
end

-- Запоминаем максимальную реальную высоту для текущего пути. Путь изменился —
-- значит, открыли другой ролик, и потолок качества сбрасывается.
local function quality_note_seen(h)
    local path = tostring(mp.get_property('path') or '')
    -- Пустой path бывает в момент перезагрузки потока — максимум не сбрасываем.
    if path ~= '' and path ~= quality_seen_path then
        quality_seen_path = path
        quality_seen_max = 0
    end
    if h and h > quality_seen_max then quality_seen_max = h end
    return quality_seen_max
end

-- Понятная подпись пункта меню для конкретной высоты.
local function quality_label_for_h(h)
    if not h or h <= 0 then return nil end
    local p = quality_preset_for_h(h)
    if p then return p.label end
    return res_label(0, h) or (math.floor(h + 0.5) .. 'p')
end

-- Строка ytdl-format для произвольной (не пресетной) высоты.
local function quality_fmt_for_h(h)
    local p = quality_preset_for_h(h)
    if p then return p.fmt end
    local hh = math.floor(h + 0.5)
    return string.format('bestvideo[height<=?%d]+bestaudio/best[height<=?%d]', hh, hh)
end

-- Верхняя плашка: ручной выбор не перезаписывается фактической высотой
-- кадра (широкий 854x360 остаётся «480p»). Без ручного выбора — «Авто»:
-- разрешение определяется и по ширине, и по высоте.
local function quality_label_current()
    if st.vid == 'no' then return 'выкл' end

    local path = mp.get_property('path')
    if not path or path == '' then return '—' end   -- ничего не загружено

    local w, h = quality_actual_wh()
    quality_note_seen(quality_actual_h())

    -- Ручной выбор из меню главнее video-params/h.
    if quality_pick and quality_pick.label then
        local want = quality_pick.url or quality_pick.path
        if not want or quality_norm_url(path) == quality_norm_url(want) then
            return quality_pick.label
        end
    end

    local t = quality_target
    if t and t.h then
        local now = mp.get_time()
        local matched = h > 0 and math.abs(h - t.h) <= quality_tol(t.h)
        local deadline = (t.at or 0) + 10
        if t.reload and t.loaded_at then
            deadline = math.min(deadline, t.loaded_at + 2.0)
        end
        if matched or now >= deadline then
            quality_target = nil
        else
            return math.floor(t.h + 0.5) .. 'p'
        end
    end

    local auto = quality_auto_label(w, h)
    if auto then return auto end
    if h > 0 then return math.floor(h + 0.5) .. 'p' end
    return '—'
end

-- Вариант Б: перезагрузка текущего онлайн-потока с новым ytdl-format.
-- playlist-play-index перезапускает ТОЛЬКО текущую серию, не трогая плейлист:
-- плашка сезона и лента серий 1, 2, 3… остаются на месте.
local function quality_reload(p)
    local path = mp.get_property('path')
    if not path or path == '' or not p or not p.fmt then return false end
    local pos = mp.get_property_number('time-pos') or 0
    local was_paused = mp.get_property_native('pause') == true
    quality_pick_apply(p.label, p.h, nil)
    quality_target = { label = p.label, h = p.h, at = mp.get_time(), reload = true, loaded = false }
    -- Шейдеры/паузу/позицию вернём после события file-loaded (см. обработчик ниже).
    pending_reload = { mode = current_mode(), paused = was_paused, pos = pos }
    -- ytdl-format — опция конкретного файла, а не глобальная настройка:
    -- выбранное качество не «переезжает» на следующие видео.
    local plpos = mp.get_property_number('playlist-pos')
    if plpos and plpos >= 0 then
        mp.set_property('file-local-options/ytdl-format', p.fmt)
        mp.set_property('file-local-options/auto-window-resize', 'no')
        mp.commandv('playlist-play-index', 'current', 'yes')
    else
        mp.commandv('loadfile', path, 'replace', -1,
            'ytdl-format=' .. p.fmt .. ',auto-window-resize=no')
    end
    return true
end

-- --------------------------------------------------------- качество: HLS-варианты
-- Лаунчер пишет рядом с плейлистом temp_playlist_meta.json:
--   episodes = { { url, qualities = { ['1080']=..., ['720']=..., ['480']=... } } }
-- Для AniLiberty это отдельные HLS-ссылки одной серии, поэтому качество
-- переключается перезагрузкой нужного варианта с той же секунды.
-- Лаунчер запускает mpv с рабочим каталогом проекта (папка, где лежат
-- launcher.py и portable_config), поэтому метаданные лежат рядом с
-- плейлистом: ./temp_playlist_meta.json — и на Windows, и на Unix.
local function quality_meta_path()
    local cwd = mp.get_property('working-directory') or ''
    cwd = cwd:gsub('[/\\]+$', '')
    if cwd ~= '' then return cwd .. '/temp_playlist_meta.json' end
    return 'temp_playlist_meta.json'
end

-- В этом mpv нет utils.read_file — читаем напрямую (как seasons_refresh).
local function quality_meta_slurp(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    if s then s = s:gsub('^\239\187\191', '') end
    return s
end

-- Кэш по времени/размеру файла: меню рисуется каждый кадр, лишний диск не нужен.
local quality_meta_cache, quality_meta_sig = nil, nil
local function quality_meta_read()
    local path = quality_meta_path()
    if path == '' then return nil end
    -- stat() (utils.file_info) — системный вызов. Раньше он делался несколько
    -- раз в секунду на каждый кадр шапки. Метаданные меняются только при
    -- запуске новой серии/сезона, поэтому проверяем файл не чаще раза в секунду.
    local now = mp.get_time()
    if quality_meta_cache and (now - RT.qmeta) < 1.0 then
        return quality_meta_cache
    end
    RT.qmeta = now
    local info = utils.file_info and utils.file_info(path)
    local sig = ''
    if info then sig = tostring(info.mtime or 0) .. ':' .. tostring(info.size or 0) end
    if quality_meta_cache and sig ~= '' and sig == quality_meta_sig then
        return quality_meta_cache
    end
    local raw = quality_meta_slurp(path)
    if not raw or raw == '' then
        quality_meta_cache, quality_meta_sig = nil, nil
        return nil
    end
    local ok, data = pcall(utils.parse_json, raw)
    if not ok or type(data) ~= 'table' or type(data.episodes) ~= 'table' then
        quality_meta_cache, quality_meta_sig = nil, nil
        return nil
    end
    quality_meta_cache, quality_meta_sig = data, sig
    return data
end

-- Серия из метаданных, которой соответствует текущий путь (любое качество).
local function quality_meta_episode()
    local cur = quality_norm_url(mp.get_property('path'))
    if cur == '' then return nil end
    local data = quality_meta_read()
    if not data then return nil end
    for _, ep in ipairs(data.episodes) do
        if type(ep) == 'table' then
            local match = quality_norm_url(ep.url) == cur
            if not match and type(ep.qualities) == 'table' then
                for _, u in pairs(ep.qualities) do
                    if quality_norm_url(u) == cur then match = true; break end
                end
            end
            if match then return ep end
        end
    end
    return nil
end

-- --------------------------------------------------------- мастер-список серий
-- URL записи плейлиста (нормализованный) по порядковому номеру 1..N.
local function playlist_entry_url(i)
    local e = (st.playlist or {})[i]
    if not e then return '' end
    return quality_norm_url(e.filename or e.title or '')
end

-- Пересобрать мастер-список серий. Номера строго 1..N; качества — из метаданных.
-- Смена качества меняет URL записи, но не число и не порядок серий.
-- Метаданные индексируются один раз (URL любого качества -> серия), чтобы
-- пересборка 35-60 серий не делала тысячи сравнений строк.
local function episodes_refresh()
    local pl = st.playlist or {}
    local index = {}
    local data = quality_meta_read()
    if data and type(data.episodes) == 'table' then
        for _, ep in ipairs(data.episodes) do
            if type(ep) == 'table' then
                local u = quality_norm_url(ep.url)
                if u ~= '' then index[u] = ep end
                if type(ep.qualities) == 'table' then
                    for _, q in pairs(ep.qualities) do
                        local qu = quality_norm_url(q)
                        if qu ~= '' then index[qu] = ep end
                    end
                end
            end
        end
    end
    local list = {}
    for i, e in ipairs(pl) do
        local url = tostring(e.filename or e.title or '')
        local meta = index[quality_norm_url(url)]
        list[i] = {
            -- Номер строго порядковый: сохранённый episode_num (если есть)
            -- или индекс записи в плейлисте. Никаких цифр из URL.
            num       = tonumber(e.episode_num) or i,
            title     = tostring((meta and meta.title) or e.title or ''),
            url       = url,
            qualities = (meta and type(meta.qualities) == 'table') and meta.qualities or nil,
            meta      = meta,
        }
    end
    EPISODES.list = list
    EPISODES.cur = clamp((st.playlist_pos or 0) + 1, 1, math.max(1, #list))
end

-- Текущее качество для запуска серии: ручной выбор, иначе фактическое.
local function episode_want_h()
    local h = EPISODES.quality_h
    if (not h or h <= 0) and quality_pick and quality_pick.h then h = quality_pick.h end
    if not h or h <= 0 then h = quality_actual_h() end
    return h or 0
end

-- Ближайший доступный вариант качества серии (ключ 1080/720/480 и URL).
local function episode_quality(meta, want_h)
    if not meta or type(meta.qualities) ~= 'table' then return nil, nil end
    local best_k, best_u, best_d
    for k, u in pairs(meta.qualities) do
        local kh = tonumber(k)
        if kh and kh > 0 and tostring(u or '') ~= '' then
            local d = math.abs(kh - (want_h or 0))
            if not best_d or d < best_d then
                best_k, best_u, best_d = kh, tostring(u), d
            end
        end
    end
    return best_k, best_u
end

-- Заменить URL записи плейлиста (1-based), не меняя число/порядок серий.
-- insert-at ставит новую запись на место старой, затем старая удаляется.
local function replace_playlist_entry(i, url)
    local pi = i - 1
    mp.commandv('loadfile', url, 'insert-at', tostring(pi), 'auto-window-resize=no')
    mp.commandv('playlist-remove', tostring(pi + 1))
end

-- Переключение на серию по порядковому номеру 1..N в текущем качестве.
local function play_episode(i)
    local pl = st.playlist or {}
    if not i or i < 1 or i > #pl then return end
    local cur = (st.playlist_pos or 0) + 1
    if i == cur then return end
    local ep = EPISODES.list[i] or { num = i }
    local key, url = episode_quality(ep.meta, episode_want_h())
    if url and quality_norm_url(url) ~= playlist_entry_url(i) then
        replace_playlist_entry(i, url)
        local lab = res_label(0, key) or (math.floor(key + 0.5) .. 'p')
        quality_pick_apply(lab, key, url)
        quality_target = nil
    elseif url and key then
        -- Запись уже указывает на нужный вариант — просто фиксируем подпись.
        local lab = res_label(0, key) or (math.floor(key + 0.5) .. 'p')
        quality_pick_apply(lab, key, url)
        quality_target = nil
    end
    mp.set_property_number('playlist-pos', i - 1)
    poke(); render()
end

-- Перезагрузка выбранного HLS-варианта без потери позиции и паузы.
-- Важно: НЕ loadfile replace (он затирал плейлист серий одиночным потоком).
-- Вставляем новый URL следующей записью и удаляем старую текущую запись —
-- список серий, playlist-pos и плашка сезона сохраняются.
local function quality_switch_stream(url, label, h)
    url = tostring(url or '')
    if url == '' then return false end
    local cur = quality_norm_url(mp.get_property('path'))
    if cur == quality_norm_url(url) then
        quality_pick_apply(label, h, url)
        quality_target = nil
        quality_notify(label)
        poke(); render()
        return true
    end
    local pos = mp.get_property_number('time-pos') or 0
    local was_paused = mp.get_property_native('pause') == true
    quality_pick_apply(label, h, url)
    quality_target = { label = label, h = h, at = mp.get_time(), reload = true, loaded = false }
    pending_reload = { mode = current_mode(), paused = was_paused, pos = pos }
    local plpos = mp.get_property_number('playlist-pos')
    local pln = mp.get_property_number('playlist-count', 0) or 0
    if plpos and plpos >= 0 and pln > 0 then
        -- Окно не должно менять размер из-за другого разрешения того же видео.
        mp.commandv('loadfile', url, 'insert-next', -1, 'auto-window-resize=no')
        -- Удаление текущей (играющей) записи сразу запускает вставленную выше.
        mp.commandv('playlist-remove', plpos)
    else
        mp.commandv('loadfile', url, 'replace', -1, 'auto-window-resize=no')
    end
    return true
end

-- Список «Качество» из метаданных. Возвращает nil, если для текущей серии
-- метаданных нет (тогда работает обычная логика ytdl/видеодорожек).
local function quality_meta_items()
    local ep = quality_meta_episode()
    if not ep or type(ep.qualities) ~= 'table' then return nil end
    local keys = {}
    for k, u in pairs(ep.qualities) do
        local h = tonumber(k)
        if h and h > 0 and tostring(u or '') ~= '' then
            keys[#keys + 1] = { h = h, url = tostring(u) }
        end
    end
    if #keys == 0 then return nil end
    table.sort(keys, function(a, b) return a.h > b.h end)

    local cur = quality_norm_url(mp.get_property('path'))
    local sel_h = quality_actual_h()
    if quality_pick and quality_pick.h then sel_h = quality_pick.h end
    local out = {}
    local marked = false
    for _, k in ipairs(keys) do
        local lab = res_label(0, k.h) or (math.floor(k.h + 0.5) .. 'p')
        local selected = (quality_norm_url(k.url) == cur)
        if not selected and quality_pick and quality_pick.url
            and quality_norm_url(quality_pick.url) == quality_norm_url(k.url) then
            selected = true
        end
        if not selected and not marked and sel_h > 0
            and math.abs(sel_h - k.h) <= quality_tol(k.h) then
            selected = true
        end
        if selected then marked = true end
        out[#out + 1] = {
            label    = lab,
            h        = k.h,
            url      = k.url,
            selected = selected,
            action   = function() quality_switch_stream(k.url, lab, k.h) end,
        }
    end
    if #out == 1 then
        out[1].label = out[1].label .. ' (Единственное доступное)'
        out[1].selected = true
    end
    return out
end

local function video_track_current()
    for _, t in ipairs(st.track_list or {}) do
        if t.type == 'video' and not t.albumart and t.selected == true then return t end
    end
    return nil
end

local function video_tracks()
    local list = {}
    for _, t in ipairs(st.track_list or {}) do
        if t.type == 'video' and not t.albumart then list[#list + 1] = t end
    end
    return list
end

-- Реально существующие высоты видеодорожек (короткая сторона кадра),
-- по убыванию. Несколько дорожек одной высоты (разные кодеки) — одна запись.
local function video_heights()
    local seen, out = {}, {}
    for _, t in ipairs(video_tracks()) do
        local w = tonumber(t['demux-w']) or 0
        local h = tonumber(t['demux-h']) or 0
        local side = (w > 0 and h > 0) and math.min(w, h) or h
        if side > 0 and not seen[side] then
            seen[side] = true
            out[#out + 1] = { h = side, id = t.id, w = w, dh = h }
        end
    end
    table.sort(out, function(a, b) return a.h > b.h end)
    return out
end

local function vid_is_auto()
    local v = st.vid
    if v == nil or v == false or v == 'auto' or v == 'no' then return true end
    if type(v) == 'string' and not v:match('^%d+$') then return true end
    return false
end

-- Двухэтапное применение выбранного качества.
local function quality_apply(p)
    if not p then return end
    local online = mp.get_property_native('demuxer-via-network') == true

    -- Локальный файл: выбора качества нет — ничего не перезагружаем.
    if not online then
        quality_target = nil
        quality_pick_clear()
        quality_notify(quality_label_for_h(p.h) or quality_label_current())
        poke(); render()
        return
    end

    -- Вариант А: в потоке уже есть эта видеодорожка — просто включаем её.
    local track
    if p.id then
        for _, t in ipairs(video_tracks()) do
            if t.id == p.id then track = t; break end
        end
    end
    if not track and p.h then
        local bestd
        for _, t in ipairs(video_tracks()) do
            local w = tonumber(t['demux-w']) or 0
            local hh = tonumber(t['demux-h']) or 0
            local side = (w > 0 and hh > 0) and math.min(w, hh) or hh
            if side > 0 then
                local d = math.abs(side - p.h)
                if d <= quality_tol(p.h) and (bestd == nil or d < bestd) then
                    track, bestd = t, d
                end
            end
        end
    end
    if track then
        local w = tonumber(track['demux-w']) or 0
        local hh = tonumber(track['demux-h']) or 0
        local side = p.h or ((w > 0 and hh > 0) and math.min(w, hh) or hh)
        local label = p.label or quality_label_for_h(side) or (math.floor(side + 0.5) .. 'p')
        quality_pick_apply(label, side, nil)
        quality_target = { label = label, h = side, at = mp.get_time(),
            reload = false, loaded = true }
        mp.set_property_number('vid', track.id)
        ensure_audio_soon()
        quality_notify(label)
        poke(); render()
        return
    end

    -- Нечего переключать/перезагружать (единственное реальное качество).
    if not p.fmt then
        local label = p.label or quality_label_for_h(p.h)
        if label and p.h then quality_pick_apply(label, p.h, nil) end
        quality_target = nil
        quality_notify(label or quality_label_current())
        poke(); render()
        return
    end

    -- Вариант Б: поток загружен одним файлом — перезагружаем с ytdl-format.
    local cur_fmt = tostring(mp.get_property('file-local-options/ytdl-format')
        or mp.get_property('ytdl-format') or '')
    if preset_is_current(p, cur_fmt) then
        -- Этот формат уже действует: перезагрузка ничего не изменит.
        if p.h then
            quality_pick_apply(p.label or quality_label_for_h(p.h), p.h, nil)
        else
            quality_pick_clear()
        end
        quality_target = nil
        quality_notify(p.label or quality_label_for_h(p.h) or quality_label_current())
        poke(); render()
        return
    end

    if quality_reload(p) then
        quality_notify(p.label)
    end
    poke(); render()
end

-- Список меню «Качество»: только реально доступные варианты.
--  • несколько видеодорожек — ровно их высоты (без выдуманных ступеней);
--  • один поток — ступени не выше реально виденного максимума;
--  • локальный файл или единственное качество — один пункт с галочкой.
-- Высота карточки меню считается от фактического числа пунктов (см. render).
local function quality_items()
    -- AniLiberty: готовые HLS-варианты серии из temp_playlist_meta.json.
    local meta_items = quality_meta_items()
    if meta_items then return meta_items end

    local online = mp.get_property_native('demuxer-via-network') == true
    local cur_h = quality_actual_h()
    local mx = quality_note_seen(cur_h)

    -- Локальный файл: единственный пункт — реальное разрешение.
    if not online then
        local hh = (cur_h > 0) and (math.floor(cur_h + 0.5) .. 'p') or 'Разрешение неизвестно'
        return { {
            label    = hh .. ' (Оригинал)',
            h        = cur_h,
            selected = true,
            action   = function()
                quality_notify(hh)
                poke(); render()
            end,
        } }
    end

    local tracks = video_heights()
    for _, t in ipairs(tracks) do
        if t.h > mx then mx = t.h end
    end

    local sel_h = cur_h
    if quality_pick and quality_pick.h then sel_h = quality_pick.h end
    if quality_target and quality_target.h then sel_h = quality_target.h end

    local out = {}

    -- Приоритет 1: в потоке несколько реальных видеодорожек.
    if #tracks >= 2 then
        for _, t in ipairs(tracks) do
            if t.h <= mx + 1 then
                local th, tid = t.h, t.id
                local lab = res_label(t.w, t.dh) or (math.floor(th + 0.5) .. 'p')
                out[#out + 1] = {
                    label    = lab,
                    h        = th,
                    id       = tid,
                    selected = sel_h > 0 and math.abs(sel_h - th) <= quality_tol(th),
                    action   = function()
                        quality_apply({ label = lab, h = th, id = tid })
                    end,
                }
            end
        end
        if #out > 0 then return out end
    end

    -- Приоритет 2: поток один. Показываем ступени не выше максимума источника
    -- и всегда — само реальное максимальное качество.
    local heights, seen = {}, {}
    for _, p in ipairs(QUALITY_PRESETS) do
        if p.h and p.h <= mx + 1 then heights[#heights + 1] = p.h end
    end
    if mx > 0 then heights[#heights + 1] = mx end
    table.sort(heights, function(a, b) return a > b end)
    for _, hh in ipairs(heights) do
        if not seen[hh] then
            seen[hh] = true
            local lab = quality_label_for_h(hh) or (math.floor(hh + 0.5) .. 'p')
            local fmt = quality_fmt_for_h(hh)
            out[#out + 1] = {
                label    = lab,
                h        = hh,
                fmt      = fmt,
                selected = sel_h > 0 and math.abs(sel_h - hh) <= quality_tol(hh),
                action   = function()
                    quality_apply({ label = lab, h = hh, fmt = fmt })
                end,
            }
        end
    end

    -- Единственный реальный вариант — ровно один пункт с зелёной галочкой.
    if #out == 1 then
        local it = out[1]
        it.label = it.label .. ' (Единственное доступное)'
        it.selected = true
        it.action = function()
            quality_target = nil
            quality_pick_clear()
            quality_notify(it.label)
            poke(); render()
        end
    end

    -- Нет ни одной видеодорожки (аудио-поток, ролик ещё грузится) — пустой
    -- карточки быть не должно: показываем один честный пункт-заглушку.
    if #out == 0 then
        out[1] = {
            label    = (st.vid == 'no') and 'Видео выключено' or 'Нет видеодорожки',
            h        = 0,
            selected = true,
            action   = function()
                quality_notify(quality_label_current())
                poke(); render()
            end,
        }
    end
    return out
end

-- --------------------------------------------------------- звук: режимы улучшения
-- af set "..." — те же строки, что продублированы на ALT+5..ALT+8 в input.conf.
local SOUND = {
    {
        short = 'Оригинал',
        label = 'Оригинал (Без обработки)',
        af    = '',
        osd   = 'Звук: Оригинал',
    },
    {
        short = 'Четкий голос',
        label = 'Четкий голос (Приглушение фона)',
        af    = 'lavfi=[pan=stereo|c0=0.8*c0-0.2*c1|c1=0.8*c1-0.2*c0,highpass=f=120,lowpass=f=7500,acompressor=threshold=-20dB:ratio=3:attack=10:release=100]',
        osd   = 'Звук: Четкий голос',
    },
    {
        short = 'Улучшение',
        label = 'Улучшение плохого звука',
        af    = 'lavfi=[highpass=f=80,lowpass=f=14000,afftdn=nf=-25,dynaudnorm=f=150:g=15]',
        osd   = 'Звук: Улучшение плохого звука',
    },
    {
        short = 'Кинотеатр',
        label = 'Кинотеатр / Объемный звук',
        af    = 'lavfi=[dynaudnorm=f=200:g=10,equalizer=f=65:width_type=o:width=2:g=3,equalizer=f=12000:width_type=o:width=2:g=2.5]',
        osd   = 'Звук: Кинотеатр / Объемный',
    },
}

-- sound_mode объявлен выше (в блоке «качество»), здесь только начальное значение.
sound_mode = 1

local function apply_sound(i, notify)
    local m = SOUND[i]
    if not m then return end
    sound_mode = i
    mp.commandv('af', 'set', m.af)
    if notify then mp.osd_message(m.osd, 2) end
    poke()
    render()
end

local function sound_items()
    local out = {}
    for i, m in ipairs(SOUND) do
        out[#out + 1] = {
            label    = m.label,
            selected = (i == sound_mode),
            action   = function() apply_sound(i, false) end,
        }
    end
    return out
end

-- --------------------------------------------------------- главы / thumbfast
local function chapter_at(t)
    local cur = nil
    for _, ch in ipairs(st.chapters or {}) do
        if (ch.time or 0) <= t then cur = ch else break end
    end
    return cur
end

local function current_chapter_index()
    local idx = 0
    local t = st.time_pos or 0
    for i, ch in ipairs(st.chapters or {}) do
        if (ch.time or 0) <= t then idx = i end
    end
    return idx
end

local function overlay_remove_thumb()
    if thumb_visible and thumb_img then
        mp.command_native_async({ 'overlay-remove', thumb_img.id or 42 }, function() end)
        thumb_visible = false
    end
end

local function overlay_add_thumb(x, y)
    if not thumb_img or not thumb_img.path then return end
    mp.command_native_async({
        'overlay-add', thumb_img.id or 42,
        math.floor(x + 0.5), math.floor(y + 0.5),
        thumb_img.path, 0, 'bgra',
        thumb_img.w, thumb_img.h, thumb_img.w * 4,
    }, function() end)
    thumb_visible = true
end

local function thumb_clear()
    if thumb_shown then
        mp.commandv('script-message-to', 'thumbfast', 'clear')
        thumb_shown = false
    end
    overlay_remove_thumb()
    thumb_pos = nil
    thumb_req_t = nil
    thumb_req_at = nil
    thumb_card = nil
    thumb_freeze = nil
end

local function do_seek(x)
    local b = M.seek
    local dur = st.duration or 0
    if not b or dur <= 0 then return end
    local f = clamp((x - b.x0) / math.max(1, b.x1 - b.x0), 0, 1)
    mp.commandv('seek', string.format('%.3f', f * dur), 'absolute+exact')
    st.time_pos = f * dur
end

local function do_vol(x)
    local b = M.vol
    if not b then return end
    local f = clamp((x - b.x0) / math.max(1, b.x1 - b.x0), 0, 1)
    local v = math.floor(f * 100 + 0.5)
    mp.set_property_number('volume', v)
    if v > 0 and st.mute then
        mp.set_property('mute', 'no')
        st.mute = false
    end
    st.volume = v
end

-- --------------------------------------------------------- сезоны
-- Лаунчер пишет portable_config/season_manifest.json рядом с плейлистами
-- сезонов. Здесь только читаем его и показываем компактный селектор:
-- «Сезон 1 ▾» слева от ленты серий. Для одиночного фильма/ролика
-- манифеста нет — селектор не рисуется вообще.
local SEASONS = { list = {}, active = 0 }

local function seasons_manifest_path()
    local p = mp.command_native({ 'expand-path', '~~/season_manifest.json' })
    if type(p) == 'string' and p ~= '' then return p end
    return nil
end

local function file_read_all(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    if not s then return nil end
    s = s:gsub('^\239\187\191', '')
    return s
end

local function seasons_refresh()
    SEASONS.list = {}
    SEASONS.active = 0
    local path = seasons_manifest_path()
    if not path then return end
    local raw = file_read_all(path)
    if not raw or raw == '' then return end
    local ok, data = pcall(utils.parse_json, raw)
    if not ok or type(data) ~= 'table' or type(data.seasons) ~= 'table' then return end

    local pl = st.playlist or {}
    local first = pl[1]
    local cur = ''
    if first then cur = first.filename or first.title or '' end

    local list = {}
    for _, s in ipairs(data.seasons) do
        if type(s) == 'table' and type(s.playlist) == 'string' and s.playlist ~= '' then
            local n = #list + 1
            list[n] = {
                name = tostring(s.name or s.short or ('Сезон ' .. n)),
                short = tostring(s.short or s.name or ('Сезон ' .. n)),
                playlist = s.playlist,
                count = tonumber(s.count) or 0,
                first = tostring(s.first or ''),
            }
        end
    end
    if #list < 2 then return end

    -- Активный сезон определяем по текущему плейлисту: количество серий
    -- и первый URL. Так селектор сам подхватывает сезон после loadlist.
    local function norm_url(s)
        s = tostring(s or '')
        s = s:gsub('^file:///', '')
        s = s:gsub('\\', '/')
        return s
    end
    local cur_n = norm_url(cur)
    local active = 0
    for i, s in ipairs(list) do
        if (s.count <= 0 or s.count == #pl) and norm_url(s.first) == cur_n then
            active = i
            break
        end
    end
    if active == 0 then
        -- Первый ролик плейлиста мог быть заменён на другой HLS-вариант
        -- качества. Ищем его канонический (1080) URL в temp_playlist_meta.json
        -- и по нему определяем сезон — плашка сезона не пропадает.
        local meta = quality_meta_read()
        if meta and type(meta.episodes) == 'table' then
            local canonical
            for _, ep in ipairs(meta.episodes) do
                if type(ep) == 'table' then
                    local hit = quality_norm_url(ep.url) == cur_n
                    if not hit and type(ep.qualities) == 'table' then
                        for _, u in pairs(ep.qualities) do
                            if quality_norm_url(u) == cur_n then hit = true; break end
                        end
                    end
                    if hit and type(ep.url) == 'string' and ep.url ~= '' then
                        canonical = norm_url(ep.url)
                        break
                    end
                end
            end
            if canonical then
                for i, s in ipairs(list) do
                    if (s.count <= 0 or s.count == #pl) and norm_url(s.first) == canonical then
                        active = i
                        break
                    end
                end
            end
        end
    end
    if active == 0 then
        -- Резерв: mpv мог нормализовать путь (слэши/регистр), поэтому если
        -- по количеству серий подходит ровно один сезон — считаем его текущим.
        local only, n = 0, 0
        for i, s in ipairs(list) do
            if s.count > 0 and s.count == #pl then n = n + 1; only = i end
        end
        if n == 1 then active = only end
    end
    if active == 0 then return end

    SEASONS.list = list
    SEASONS.active = active
end

local function seasons_visible()
    return #SEASONS.list >= 2 and SEASONS.active > 0
end

local function seasons_switch(i)
    local s = SEASONS.list[i]
    if not s or not s.playlist then return end
    SEASONS.active = i
    menu = nil
    -- Новый сезон — новая лента: окно серий начинаем с первой серии.
    pl_win_start = 1
    pl_win_cur = nil
    pl_win_vis = nil
    mp.osd_message('Сезон: ' .. s.short, 3)
    mp.commandv('loadlist', s.playlist, 'replace')
    poke()
    render()
end

local function season_items()
    local items = {}
    for i, s in ipairs(SEASONS.list) do
        items[#items + 1] = {
            label = s.name,
            selected = (i == SEASONS.active),
            action = function() seasons_switch(i) end,
        }
    end
    return items
end

local function clear_osd()
    if last_data ~= '' then
        osd.data = ''
        osd:update()
        last_data = ''
    end
end

local function grad_top(ass, W, height, hex)
    local steps = 12
    for i = 0, steps - 1 do
        local a = 0x9e * (1 - i / steps) ^ 1.55
        local y0 = height * i / steps
        local y1 = height * (i + 1) / steps + 0.5
        rr(ass, 0, y0, W, y1, 0, hex, math.floor(a))
    end
end

local function grad_bottom(ass, W, H, height, hex)
    local steps = 14
    for i = 0, steps - 1 do
        local a = 0xcc * ((i + 0.6) / steps) ^ 1.35
        local y0 = H - height + height * i / steps
        local y1 = H - height + height * (i + 1) / steps + 0.5
        rr(ass, 0, y0, W, y1, 0, hex, math.floor(a))
    end
end

-- --------------------------------------------------------- превью таймлайна
-- Карточка в палитре интерфейса: кадр сверху, под ним — название главы
-- (если есть) и точное время MM:SS. Кадр рисует thumbfast (overlay-add),
-- карточка и текст — наш ASS-слой. Позиция всегда зажата в границы окна.
local function draw_timeline_preview(ass, W, H, bar_y, S, mx, dur, pad)
    local b = M.seek
    if not b or dur <= 0 then return end

    local t = clamp((mx - b.x0) / math.max(1, b.x1 - b.x0), 0, 1) * dur
    local ch = chapter_at(t)
    local chname = ch and clean(ch.title or '') or ''
    local time_s = fmt_time_floor(t)

    local use_thumb = thumb.available and not thumb.disabled
        and (thumb.width or 0) > 0 and (thumb.height or 0) > 0

    local pad_in  = 8 * S
    local gap     = 5 * S
    local line_h  = 16 * S
    local fs_ch   = 12 * S
    local fs_time = 12.5 * S
    local radius  = 9 * S

    if use_thumb then
        local iw, ih = thumb.width, thumb.height
        local text_w = math.max(tw(time_s, fs_time),
            chname ~= '' and tw(chname, fs_ch) or 0)
        local cw = math.max(iw, text_w) + pad_in * 2
        if cw > W - pad * 2 then use_thumb = false end

        if use_thumb then
            local chh = pad_in + ih + gap
                + (chname ~= '' and line_h or 0) + line_h + pad_in
            local cx = clamp(mx - cw / 2, pad, W - pad - cw)
            local cy = bar_y - 16 * S - chh
            if cy < 4 * S then cy = 4 * S end
            -- Прямоугольник карточки (информационно; удержание кадра по нему
            -- больше не выполняется — превью привязано только к полосе).
            thumb_card = { x1 = cx, y1 = cy, x2 = cx + cw, y2 = cy + chh }

            rr(ass, cx + 3 * S, cy + 4 * S, cx + cw + 3 * S, cy + chh + 4 * S,
                radius, '000000', 0x70)
            rr(ass, cx, cy, cx + cw, cy + chh, radius, COL.bg, 0x08)
            rr_ring(ass, cx, cy, cx + cw, cy + chh, radius, 1.2 * S, COL.border, 0x90)

            -- Кадр строго над полосой прогресса и не выходит за края окна.
            local ix = clamp(cx + (cw - iw) / 2, 2 * S, math.max(2 * S, W - iw - 2 * S))
            local iy = clamp(cy + pad_in, 2 * S, math.max(2 * S, H - ih - 2 * S))
            local ty = iy + ih + gap
            if chname ~= '' then
                txt(ass, cx + cw / 2, ty + line_h / 2, 5, fs_ch, COL.text, 0x10,
                    fit(chname, cw - pad_in * 2, fs_ch))
                ty = ty + line_h
            end
            txt(ass, cx + cw / 2, ty + line_h / 2, 5, fs_time, COL.muted, 0x20,
                time_s, true)

            -- Просим thumbfast кадр при смене времени (x/y пустые -> рисуем сами).
            -- Троттлинг: не чаще 1 раза в THUMB_REQ_MIN_WALL секунды и только
            -- если время под курсором сдвинулось на THUMB_REQ_MIN_DT секунды.
            -- Так очередь команд подпроцесса не забивается.
            local now = mp.get_time()
            if (thumb_req_t == nil or math.abs(thumb_req_t - t) >= THUMB_REQ_MIN_DT)
                and (thumb_req_at == nil or now - thumb_req_at >= THUMB_REQ_MIN_WALL) then
                thumb_req_t = t
                thumb_req_at = now
                -- Координаты НЕ передаём: с пустыми x/y thumbfast отдаёт кадр
                -- нам (thumbfast-render), и мы рисуем его сами ровно над
                -- карточкой и полосой прогресса. Если передать x/y, thumbfast
                -- начнёт рисовать сам и перестанет убирать кадр — он «залипает».
                mp.commandv('script-message-to', 'thumbfast', 'thumb',
                    string.format('%.3f', t), '', '', 'yummy_ui')
                thumb_shown = true
            end
            local tr = thumb_pos
            local same = thumb_visible and tr
                and math.floor(tr.x + 0.5) == math.floor(ix + 0.5)
                and math.floor(tr.y + 0.5) == math.floor(iy + 0.5)
            thumb_pos = { x = ix, y = iy }
            if not same then overlay_add_thumb(ix, iy) end
            return
        end
    end

    -- Резервная карточка без кадра (аудио / thumbfast недоступен)
    -- Если кадр был на экране, убираем его, чтобы не висел поверх меню.
    -- Позицию «заморозки» сохраняем: карточка со временем тоже должна
    -- оставаться на месте, когда курсор уходит с бара вверх.
    local frz = thumb_freeze
    thumb_clear()
    thumb_freeze = frz
    local label = time_s
    if chname ~= '' then
        label = time_s .. '  ·  ' .. fit(chname, 220 * S, 12 * S)
    end
    local bpx = 13 * S
    local bw = tw(label, bpx) + 22 * S
    local bh = 25 * S
    local bx = clamp(mx - bw / 2, pad, W - pad - bw)
    local by = bar_y - 16 * S - bh
    thumb_card = { x1 = bx, y1 = by, x2 = bx + bw, y2 = by + bh }
    rr(ass, bx + 2 * S, by + 3 * S, bx + bw + 2 * S, by + bh + 3 * S, 7 * S, '000000', 0x70)
    rr(ass, bx, by, bx + bw, by + bh, 7 * S, COL.bg, 0x08)
    rr_ring(ass, bx, by, bx + bw, by + bh, 7 * S, 1.2 * S, COL.border, 0x90)
    txt(ass, bx + bw / 2, by + bh / 2 + 0.5, 5, bpx, COL.text, 0x08, label)
end

-- --------------------------------------------------------- подвал
local function draw_footer(ass, W, H, S)
    local pad = PAD * S
    local row_y = H - 64 * S
    local bar_y = H - 24 * S
    local x0, x1 = pad, W - pad
    local dur = st.duration or 0
    local pos = st.time_pos or 0
    M.seek = { x0 = x0, x1 = x1 }
    M.vol = { x0 = pad + 88 * S, x1 = pad + 184 * S, y0 = row_y - 16 * S, y1 = row_y + 16 * S }
    local mx, my = -1, -1
    if hovering then mx, my = mouse() end

    grad_bottom(ass, W, H, 178 * S, COL.bg)

    -- ---- play / pause
    local pcx = pad + 16 * S
    local phr = 18 * S
    local hov_play = inside({ x1 = pcx - phr, y1 = row_y - phr, x2 = pcx + phr, y2 = row_y + phr }, mx, my)
    if hov_play then rr(ass, pcx - phr, row_y - phr, pcx + phr, row_y + phr, 9 * S, 'ffffff', 0x14) end
    if st.pause then
        ic_play(ass, pcx, row_y, 20 * S, hov_play and COL.green or COL.text, hov_play and 0 or 0x18)
    else
        ic_pause(ass, pcx, row_y, 20 * S, hov_play and COL.green or COL.text, hov_play and 0 or 0x18)
    end
    reg(pcx - phr, row_y - phr, pcx + phr, row_y + phr, nil, function()
        mp.commandv('cycle', 'pause')
    end)

    -- ---- громкость
    local vcx = pad + 64 * S
    local vx0, vx1 = pad + 88 * S, pad + 184 * S
    local hov_vicon = inside({ x1 = vcx - 17 * S, y1 = row_y - 17 * S, x2 = vcx + 17 * S, y2 = row_y + 17 * S }, mx, my)
    local hov_vbar = inside({ x1 = vx0 - 8 * S, y1 = row_y - 16 * S, x2 = vx1 + 8 * S, y2 = row_y + 16 * S }, mx, my)
    local muted = st.mute or (st.volume or 0) <= 0.5
    ic_volume(ass, vcx, row_y, 18 * S, (hov_vicon or hov_vbar) and COL.green or COL.text,
        (hov_vicon or hov_vbar) and 0 or 0x18, muted)
    reg(vcx - 17 * S, row_y - 17 * S, vcx + 17 * S, row_y + 17 * S, nil, function()
        mp.commandv('cycle', 'mute')
    end)

    local vfrac = clamp((muted and 0 or (st.volume or 0)) / 100, 0, 1)
    rr(ass, vx0, row_y - 2 * S, vx1, row_y + 2 * S, 2 * S, 'ffffff', 0x30)
    if vfrac > 0 then
        rr(ass, vx0, row_y - 2 * S, vx0 + (vx1 - vx0) * vfrac, row_y + 2 * S, 2 * S, COL.text, 0x20)
    end
    if hov_vbar or drag == 'vol' then
        local kx = vx0 + (vx1 - vx0) * vfrac
        rr(ass, kx - 5 * S, row_y - 5 * S, kx + 5 * S, row_y + 5 * S, 5 * S, 'ffffff', 0)
    end
    reg(vx0 - 8 * S, row_y - 16 * S, vx1 + 8 * S, row_y + 16 * S,
        function(x) drag = 'vol'; do_vol(x) end, nil)

    -- ---- время
    local tx = pad + 198 * S
    local tpos = fmt_time(pos)
    local ttot = (dur > 0) and fmt_time(dur) or '--:--'
    local ttw = tw(tpos, 15 * S)
    txt(ass, tx, row_y, 4, 15 * S, COL.text, 0x08, tpos, true)
    txt(ass, tx + ttw + 2 * S, row_y, 4, 15 * S, COL.muted, 0x20, '/ ' .. ttot)
    ttw = ttw + 2 * S + tw('/ ' .. ttot, 15 * S)

    -- ---- правые кнопки
    local step = 42 * S
    local fcx = W - pad - 15 * S
    local function icon_btn(cx, drawfn, onclick)
        local half = 17 * S
        local hov = inside({ x1 = cx - half, y1 = row_y - half, x2 = cx + half, y2 = row_y + half }, mx, my)
        if hov then rr(ass, cx - half, row_y - half, cx + half, row_y + half, 8 * S, 'ffffff', 0x14) end
        drawfn(hov)
        reg(cx - half, row_y - half, cx + half, row_y + half, nil, onclick)
    end

    icon_btn(fcx, function(hov)
        ic_fullscreen(ass, fcx, row_y, 18 * S, hov and COL.green or COL.text, hov and 0 or 0x18)
    end, function()
        mp.commandv('cycle', 'fullscreen')
    end)

    local mcx = fcx - step
    icon_btn(mcx, function(hov)
        ic_mini(ass, mcx, row_y, 18 * S, hov and COL.green or COL.text, hov and 0 or 0x18)
    end, function()
        toggle_mini()
    end)

    local gcx = fcx - step * 2
    icon_btn(gcx, function(hov)
        ic_gear(ass, gcx, row_y, 21 * S, hov and COL.green or COL.text, hov and 0 or 0x18)
    end, function()
        if menu and menu.kind == 'settings' then menu = nil else menu = { kind = 'settings' } end
        poke()
        render()
    end)

    local ccx = fcx - step * 3
    local subs_on = subs_enabled()
    if subs_on then
        rr(ass, ccx - 16 * S, row_y - 14 * S, ccx + 16 * S, row_y + 14 * S, 6 * S, COL.green, 0)
    end
    icon_btn(ccx, function(hov)
        local fg = subs_on and COL.dark or (hov and COL.green or COL.text)
        txt(ass, ccx, row_y, 5, 14 * S, fg, 0, 'CC', true)
    end, function()
        toggle_subs()
    end)

    -- ---- компактная кнопка «Эпизоды / Таймкоды» (рядом с таймером)
    local chs = st.chapters or {}
    if #chs > 0 then
        local cbw, cbh = 104 * S, 30 * S
        local cbx0 = tx + ttw + 18 * S
        local cbx1 = cbx0 + cbw
        local right_limit = ccx - 27 * S
        if cbx1 <= right_limit then
            local open = (menu ~= nil and menu.kind == 'chapters')
            local hov = inside({ x1 = cbx0, y1 = row_y - cbh / 2,
                                 x2 = cbx1, y2 = row_y + cbh / 2 }, mx, my)
            rr(ass, cbx0, row_y - cbh / 2, cbx1, row_y + cbh / 2, 7 * S,
                (hov or open) and COL.bg3 or COL.bg2, 0x48)
            rr_ring(ass, cbx0, row_y - cbh / 2, cbx1, row_y + cbh / 2, 7 * S, 1.1 * S,
                open and COL.green or COL.border, open and 0x40 or 0xa0)
            txt(ass, cbx0 + 12 * S, row_y, 4, 12.5 * S, COL.text, 0x10,
                fit('Эпизоды', cbw - 36 * S, 12.5 * S))
            txt(ass, cbx1 - 11 * S, row_y, 6, 10.5 * S,
                open and COL.green or COL.muted, 0x20, '▾')
            reg(cbx0, row_y - cbh / 2, cbx1, row_y + cbh / 2, nil, function()
                if menu and menu.kind == 'chapters' then
                    menu = nil
                else
                    menu = { kind = 'chapters' }
                    ch_win_start = 1
                    ch_win_cur = nil
                end
                poke()
                render()
            end)
        end
    end

    -- ---- прогресс-бар
    -- Подсветка полосы (утолщение + бегунок) ровно там же, где живёт превью:
    -- по вертикали — в пределах полосы с допуском ±7 px, по горизонтали —
    -- с небольшим запасом у краёв, чтобы за них можно было взяться мышью.
    local hov_seek = (mx >= x0 - 8 * S and mx <= x1 + 8 * S
        and my >= bar_y - 7 * S and my <= bar_y + 7 * S)
    local thick = (hov_seek or drag == 'seek') and 6 * S or 4 * S
    rr(ass, x0, bar_y - thick / 2, x1, bar_y + thick / 2, thick / 2, 'ffffff', 0x28)
    local frac = (dur > 0) and clamp(pos / dur, 0, 1) or 0
    local pxc = x0 + (x1 - x0) * frac
    if frac > 0 then
        rr(ass, x0, bar_y - thick / 2, pxc, bar_y + thick / 2, thick / 2, COL.blue, 0)
    end

    -- ---- засечки глав: тонкие разделители с разрывом сегментов
    if #chs > 1 and dur > 0 then
        for i = 2, #chs do
            local cf = clamp((chs[i].time or 0) / dur, 0, 1)
            if cf > 0.002 and cf < 0.998 then
                local cxp = x0 + (x1 - x0) * cf
                -- В ASS альфа — это прозрачность: 0x00 = непрозрачно.
                -- Тёмный «просвет» в баре + тонкая светлая засечка по центру.
                rr(ass, cxp - 1.7 * S, bar_y - thick / 2 - 1.4 * S,
                    cxp + 1.7 * S, bar_y + thick / 2 + 1.4 * S, 1.7 * S, COL.bg, 0x0C)
                rr(ass, cxp - 0.5 * S, bar_y - thick / 2 - 2.4 * S,
                    cxp + 0.5 * S, bar_y + thick / 2 + 2.4 * S, 0.5 * S, COL.muted, 0x68)
            end
        end
    end

    if hov_seek or drag == 'seek' then
        rr(ass, pxc - 5 * S, bar_y - 5 * S, pxc + 5 * S, bar_y + 5 * S, 5 * S, 'ffffff', 0)
    end
    reg(x0 - 8 * S, bar_y - 16 * S, x1 + 8 * S, bar_y + 14 * S,
        function(x) drag = 'seek'; do_seek(x) end, nil)

    -- ---- всплывающая карточка: превью-кадр + глава + точное время
    -- Показываем её ТОЛЬКО пока курсор на самой полосе: по горизонтали строго
    -- от начала до конца, по вертикали — в пределах полосы с допуском ±7 px.
    -- Выход за эти границы (вверх к карточке, вниз к кнопкам, в сторону)
    -- мгновенно убирает превью (см. render).
    local ptol = 7 * S
    local on_bar = (mx >= x0 and mx <= x1
        and my >= bar_y - ptol and my <= bar_y + ptol)
    M.hover_seek = on_bar
    if on_bar then
        thumb_freeze = { x = mx }
        M.preview = { x = mx, y = my, bar_y = bar_y, dur = dur, pad = pad }
    else
        thumb_freeze = nil
        M.preview = nil
    end
end

-- --------------------------------------------------------- шапка
local function draw_header(ass, W, H, S)
    local pad = PAD * S
    local cy = 32 * S
    grad_top(ass, W, 86 * S, COL.bg)

    local mx, my = -1, -1
    if hovering then mx, my = mouse() end

    -- ---- три плашки-селектора справа: Аудио / Субтитры / Качество
    local gap = 8 * S
    local n_pill = 3
    local pw = math.min(206 * S, math.max(92 * S, (W * 0.55 - (n_pill - 1) * gap) / n_pill))
    local block_w = n_pill * pw + (n_pill - 1) * gap
    local pills_left = W - pad - block_w
    local px = pills_left
    M.pills = {}

    local function pill(kind, label, is_open, onclick)
        local x0, x1 = px, px + pw
        local hov = inside({ x1 = x0, y1 = cy - 17 * S, x2 = x1, y2 = cy + 17 * S }, mx, my) or is_open
        rr(ass, x0, cy - 17 * S, x1, cy + 17 * S, 8 * S, hov and COL.bg3 or COL.bg2, 0x48)
        rr_ring(ass, x0, cy - 17 * S, x1, cy + 17 * S, 8 * S, 1.1 * S,
            is_open and COL.green or COL.border, is_open and 0x40 or 0xa0)
        local fs = 13.5 * S
        txt(ass, x1 - 11 * S, cy, 6, 11.5 * S, is_open and COL.green or COL.muted, 0x20,
            is_open and '▴' or '▾')
        txt(ass, x0 + 14 * S, cy, 4, fs, COL.text, is_open and 0 or 0x10,
            fit(label, x1 - x0 - 46 * S, fs))
        M.pills[kind] = { x0 = x0, x1 = x1 }
        reg(x0, cy - 18 * S, x1, cy + 18 * S, nil, onclick)
        px = px + pw + gap
    end

    local function toggle_menu(kind)
        return function()
            if menu and menu.kind == kind then menu = nil else menu = { kind = kind } end
            poke(); render()
        end
    end

    pill('audio', 'Аудио · ' .. audio_label_current(),
        menu ~= nil and menu.kind == 'audio', toggle_menu('audio'))
    pill('sub', 'Субтитры · ' .. current_track_label('sub'),
        menu ~= nil and menu.kind == 'sub', toggle_menu('sub'))
    pill('quality', 'Качество · ' .. quality_label_current(),
        menu ~= nil and menu.kind == 'quality', toggle_menu('quality'))

    -- ---- заголовок: название текущего видео/серии строго слева,
    --      с безопасным зазором до плашек (обрезается троеточием)
    local left_x0 = pad
    local left_x1 = pills_left - 12 * S
    local left_w = math.max(80 * S, left_x1 - left_x0)
    local pl = st.playlist or {}
    local title = st.media_title
    -- После смены качества запись плейлиста может потерять EXTINF-название,
    -- и mpv подставляет хеш из URL. В режиме серий берём название серии из
    -- мастер-списка; для одиночного файла оставляем штатный media-title.
    local cur_ep = clamp((st.playlist_pos or 0) + 1, 1, math.max(1, #pl))
    local ep_info = (#pl > 1) and EPISODES.list[cur_ep] or nil
    if ep_info and ep_info.title and ep_info.title ~= '' then
        title = ep_info.title
    elseif not title or title == '' then
        local e = pl[1]
        title = e and (e.title or e.filename) or ''
    end

    local area_x0, area_x1, area_w
    if #pl <= 1 then
        area_x0, area_x1 = left_x0, left_x1
        area_w = math.max(60 * S, area_x1 - area_x0)
        if title and title ~= '' then
            txt(ass, area_x0, cy, 4, 13.5 * S, COL.muted, 0x20, fit(title, area_w, 13.5 * S))
        end
    else
        -- название слева + компактный список серий сразу за ним
        local title_w = math.min(left_w * 0.42, 260 * S)
        if title and title ~= '' and title_w > 40 * S then
            txt(ass, left_x0, cy, 4, 13.5 * S, COL.muted, 0x20, fit(title, title_w, 13.5 * S))
            area_x0 = left_x0 + title_w + 14 * S
        else
            area_x0 = left_x0
        end
        area_x1 = left_x1
        area_w = math.max(60 * S, area_x1 - area_x0)
        local chip_w, gap, arrow_w = 40 * S, 6 * S, 24 * S

        -- Компактный селектор сезонов: только если в манифесте реально
        -- 2+ сезона и текущий плейлист совпал с одним из них.
        local chips_x0 = area_x0
        if seasons_visible() then
            local sw = math.min(132 * S, math.max(92 * S, area_w * 0.30))
            local sx0, sx1 = area_x0, area_x0 + sw
            local open = (menu ~= nil and menu.kind == 'seasons')
            local hov = open or inside({ x1 = sx0, y1 = cy - 15 * S, x2 = sx1, y2 = cy + 15 * S }, mx, my)
            rr(ass, sx0, cy - 15 * S, sx1, cy + 15 * S, 7 * S, 'ffffff', hov and 0x1e or 0x12)
            local sshort = SEASONS.list[SEASONS.active].short
            if not sshort or sshort == '' then sshort = 'Сезон ' .. SEASONS.active end
            txt(ass, sx1 - 12 * S, cy, 6, 11.5 * S,
                open and COL.green or COL.muted, open and 0x10 or 0x30,
                open and '▴' or '▾')
            txt(ass, sx0 + 12 * S, cy, 4, 14 * S,
                hov and COL.text or COL.muted, hov and 0 or 0x18,
                fit(sshort, sw - 36 * S, 14 * S))
            M.pills.seasons = { x0 = sx0, x1 = sx1 }
            reg(sx0, cy - 16 * S, sx1, cy + 16 * S, nil, function()
                if menu and menu.kind == 'seasons' then menu = nil
                else menu = { kind = 'seasons' } end
                poke()
                render()
            end)
            chips_x0 = sx1 + gap
        end
        local chips_w = math.max(40 * S, area_x1 - chips_x0)

        local function count(a, arrows)
            local avail = a - (arrows and arrow_w * 2 or 0)
            return math.max(1, math.floor((avail + gap) / (chip_w + gap)))
        end
        -- Стрелки ‹ › — только прокрутка ленты серий (когда серий больше
        -- одной). Крайние положения жёстко блокируются, см. can_left/can_right:
        -- лента не листается по кругу. Хитбоксы не перекрываются квадратами
        -- и плашками.
        local arrows = #pl > 1
        local vis = count(chips_w, arrows)
        local cur = clamp((st.playlist_pos or 0) + 1, 1, #pl)

        -- Окно подъезжает к текущей серии только при её смене (чип,
        -- автопереход) или изменении ширины. Ручная прокрутка стрелками
        -- больше не сбрасывается на первый элемент при каждом рендере.
        if pl_win_cur ~= cur then
            pl_win_cur = cur
            if pl_win_start > cur then pl_win_start = cur end
            if cur > pl_win_start + vis - 1 then pl_win_start = cur - vis + 1 end
        elseif pl_win_vis ~= vis then
            if cur < pl_win_start then pl_win_start = cur end
            if cur > pl_win_start + vis - 1 then pl_win_start = cur - vis + 1 end
        end
        pl_win_vis = vis
        pl_win_start = clamp(pl_win_start, 1, math.max(1, #pl - vis + 1))

        local last_start = math.max(1, #pl - vis + 1)
        -- Стрелки — только прокрутка ленты. Жёсткие границы: слева начало
        -- списка (серия 1), справа его конец (серия N). Никакого перехода
        -- по кругу: в крайних положениях клик по стрелке ничего не делает.
        local can_left  = pl_win_start > 1
        local can_right = pl_win_start < last_start

        if arrows then
            txt(ass, chips_x0 + arrow_w / 2, cy, 5, 17 * S,
                can_left and COL.text or COL.border, 0x10, '‹')
            -- Область клика регистрируется и в неактивном состоянии, чтобы
            -- клик по приглушённой стрелке просто «гасился», а не проваливался
            -- в фон (иначе он срабатывал бы как клик по пустому месту).
            reg(chips_x0, cy - 16 * S, chips_x0 + arrow_w, cy + 16 * S, nil, function()
                if pl_win_start <= 1 then return end
                pl_win_start = math.max(1, pl_win_start - vis)
                render()
            end)
        end

        local x = chips_x0 + (arrows and arrow_w or 0)
        local idx = pl_win_start
        while idx <= #pl and idx < pl_win_start + vis do
            local ep_data = EPISODES.list[idx]
            -- Строго порядковый номер: 1, 2, 3… Никаких цифр из URL/хеша
            -- HLS-ссылки — после смены качества номер не «прыгает» в 149/534.
            local label = tostring(ep_data and ep_data.num or ep_number(pl[idx], idx))
            local sel = (idx == cur)
            local hov = inside({ x1 = x, y1 = cy - 15 * S, x2 = x + chip_w, y2 = cy + 15 * S }, mx, my)
            if sel then
                rr(ass, x, cy - 15 * S, x + chip_w, cy + 15 * S, 7 * S, COL.green, 0)
                txt(ass, x + chip_w / 2, cy, 5, 14 * S, COL.dark, 0, label, true)
            else
                rr(ass, x, cy - 15 * S, x + chip_w, cy + 15 * S, 7 * S, 'ffffff', hov and 0x1e or 0x12)
                -- Квадраты неактивных серий светлые, поэтому цифры рисуем
                -- тёмными (как на зелёном активном) — не сливаются с фоном.
                txt(ass, x + chip_w / 2, cy, 5, 14 * S,
                    COL.dark, hov and 0 or 0x20, label, false)
            end
            local epi = idx
            reg(x, cy - 16 * S, x + chip_w, cy + 16 * S, nil, function()
                play_episode(epi)
            end)
            x = x + chip_w + gap
            idx = idx + 1
        end

        if arrows then
            txt(ass, area_x1 - arrow_w / 2, cy, 5, 17 * S,
                can_right and COL.text or COL.border, 0x10, '›')
            reg(area_x1 - arrow_w, cy - 16 * S, area_x1, cy + 16 * S, nil, function()
                if pl_win_start >= last_start then return end
                pl_win_start = math.min(last_start, pl_win_start + vis)
                render()
            end)
        end
    end
end

-- --------------------------------------------------------- «Пропустить заставку»
local function skip_state()
    if st.skip_used then return false, nil end
    local tp = st.time_pos or 0
    local op = current_op()
    if op and tp >= (op.start - 1) and tp < (op.stop - 2) then
        return true, op
    end
    if tp >= 0 and tp < 270 then
        return true, nil
    end
    return false, nil
end

local function draw_skip(ass, W, H, S)
    local show, op = skip_state()
    if not show then return end

    local mx, my = -1, -1
    if hovering then mx, my = mouse() end

    local bw, bh = 214 * S, 40 * S
    local x0 = PAD * S
    local y1 = H - 96 * S
    local x1, y0 = x0 + bw, y1 - bh
    local hov = inside({ x1 = x0, y1 = y0, x2 = x1, y2 = y1 }, mx, my)

    rr(ass, x0 + 2 * S, y0 + 3 * S, x1 + 2 * S, y1 + 3 * S, 9 * S, '000000', 0x70)
    rr(ass, x0, y0, x1, y1, 9 * S, COL.bg, 0x20)
    rr_ring(ass, x0, y0, x1, y1, 9 * S, 1.2 * S,
        hov and COL.green or COL.border, hov and 0x20 or 0x90)
    ic_skip(ass, x0 + 24 * S, (y0 + y1) / 2, 18 * S,
        hov and COL.green or COL.text, hov and 0 or 0x10)
    txt(ass, x0 + 46 * S, (y0 + y1) / 2, 4, 13.5 * S,
        hov and COL.green or COL.text, hov and 0 or 0x10,
        fit('Пропустить заставку', bw - 60 * S, 13.5 * S))

    reg(x0, y0, x1, y1, nil, function()
        local tp = st.time_pos or 0
        local target = (op and op.stop) or (tp + 85)
        if target <= tp then target = tp + 85 end
        mp.commandv('seek', string.format('%.3f', target), 'absolute')
        st.skip_used = true
        poke()
        render()
    end)
end

-- --------------------------------------------------------- «Пропустить эндинг»
-- Зеркальная кнопка слева над панелью управления. Появляется только
-- в последние 135 секунд или внутри главы Ending/ED. Сама не срабатывает.
local ENDING_WINDOW = 135
local ENDING_STEP   = 85

local function ending_state()
    if st.ending_used then return false, nil end
    local dur = st.duration or 0
    if dur <= 0 then return false, nil end
    local tp = st.time_pos or 0
    local ed = current_ed()
    if ed and tp >= (ed.start - 1) and tp < (ed.stop or dur) then
        return true, ed
    end
    if (dur - tp) <= ENDING_WINDOW then
        return true, ed
    end
    return false, nil
end

local function skip_ending()
    local dur = st.duration or 0
    local tp  = st.time_pos or 0
    local remain = dur - tp
    local pl  = st.playlist or {}
    local pos = st.playlist_pos or 0
    if pos < 0 then pos = 0 end

    -- Меньше 85 с до конца и есть следующая серия — сразу переключаем.
    if remain < ENDING_STEP and #pl > 0 and pos < (#pl - 1) then
        st.ending_used = true
        poke()
        render()
        mp.commandv('playlist-next')
        return
    end

    local target = tp + ENDING_STEP
    if dur > 0 and target > dur - 0.5 then target = dur - 0.5 end
    if target < tp then target = tp end
    mp.commandv('seek', string.format('%.3f', target), 'absolute')
    st.ending_used = true
    poke()
    render()
end

local function draw_ending(ass, W, H, S)
    local show = ending_state()
    if not show then return end

    local mx, my = -1, -1
    if hovering then mx, my = mouse() end

    -- Зеркально кнопке заставки: справа, иконка справа, текст слева.
    local bw, bh = 214 * S, 40 * S
    local x1 = W - PAD * S
    local y1 = H - 96 * S
    local x0, y0 = x1 - bw, y1 - bh
    local hov = inside({ x1 = x0, y1 = y0, x2 = x1, y2 = y1 }, mx, my)

    rr(ass, x0 + 2 * S, y0 + 3 * S, x1 + 2 * S, y1 + 3 * S, 9 * S, '000000', 0x70)
    rr(ass, x0, y0, x1, y1, 9 * S, COL.bg, 0x20)
    rr_ring(ass, x0, y0, x1, y1, 9 * S, 1.2 * S,
        hov and COL.green or COL.border, hov and 0x20 or 0x90)
    ic_skip(ass, x1 - 24 * S, (y0 + y1) / 2, 18 * S,
        hov and COL.green or COL.text, hov and 0 or 0x10)
    txt(ass, x0 + 14 * S, (y0 + y1) / 2, 4, 13.5 * S,
        hov and COL.green or COL.text, hov and 0 or 0x10,
        fit('Пропустить эндинг', bw - 60 * S, 13.5 * S))

    reg(x0, y0, x1, y1, nil, function()
        skip_ending()
    end)
end

-- --------------------------------------------------------- меню дорожек
local function draw_list_menu(ass, W, H, S, kind)
    local items, title
    if kind == 'audio' then
        items, title = audio_items(), 'Аудиодорожки'
    elseif kind == 'quality' then
        items, title = quality_items(), 'Качество видео'
    elseif kind == 'seasons' then
        items, title = season_items(), 'Сезоны'
    else
        items, title = sub_items(), 'Субтитры'
    end
    local w = math.min(330 * S, W - 2 * PAD * S)
    local row_h, head, pad_in = 31 * S, 34 * S, 8 * S
    local p = M.pills and M.pills[kind]
    local ax = (p and p.x0) or (W - PAD * S - w)
    -- Строго под своей плашкой; если справа не влезает (крайняя «Качество») —
    -- прижимаем к правому краю плашки, чтобы карточка не вылезла за окно.
    if p and ax + w > W - PAD * S then ax = p.x1 - w end
    local x0 = clamp(ax, PAD * S, W - PAD * S - w)
    local y0 = 72 * S
    local rows = math.max(1, #items)
    local h = head + pad_in * 2 + rows * row_h
    M.menu_rect = { x1 = x0, y1 = y0, x2 = x0 + w, y2 = y0 + h }

    rr(ass, x0 + 3 * S, y0 + 5 * S, x0 + w + 3 * S, y0 + h + 5 * S, 11 * S, '000000', 0x70)
    rr(ass, x0, y0, x0 + w, y0 + h, 11 * S, COL.bg2, 0x08)
    rr_ring(ass, x0, y0, x0 + w, y0 + h, 11 * S, 1.2 * S, COL.border, 0x80)
    txt(ass, x0 + 16 * S, y0 + head / 2 + 1 * S, 4, 13 * S, COL.muted, 0x10, title, true)

    local mx, my = -1, -1
    if hovering then mx, my = mouse() end

    if #items == 0 then
        txt(ass, x0 + w / 2, y0 + head + pad_in + row_h / 2, 5, 13 * S,
            COL.muted, 0x30, 'Нет доступных дорожек')
        return
    end

    for i, it in ipairs(items) do
        local iy = y0 + head + pad_in + (i - 1) * row_h
        local hov = inside({ x1 = x0 + 6 * S, y1 = iy, x2 = x0 + w - 6 * S, y2 = iy + row_h }, mx, my)
        if hov then
            rr(ass, x0 + 6 * S, iy + 1 * S, x0 + w - 6 * S, iy + row_h - 1 * S, 6 * S, 'ffffff', 0x10)
        end
        if it.selected then
            txt(ass, x0 + 16 * S, iy + row_h / 2, 5, 12 * S, COL.green, 0, '✓', true)
        end
        txt(ass, x0 + 34 * S, iy + row_h / 2, 4, 13 * S,
            it.ai and COL.blue2 or (it.selected and COL.green or COL.text),
            (it.ai or it.selected) and 0 or 0x18,
            fit(it.label, w - 56 * S, 13 * S))
        reg(x0 + 6 * S, iy, x0 + w - 6 * S, iy + row_h, nil, function()
            it.action()
            menu = nil
            poke()
            render()
        end)
    end
end

-- --------------------------------------------------------- ИИ-субтитры (whisper.cpp)
-- Запускает whisper.cpp в фоне. Windows: VBS-обёртка извлекает
-- 16 кГц mono WAV через mpv и распознаёт речь (NVIDIA CUDA, а без неё —
-- автоматически на CPU). Linux/macOS: та же логика в POSIX-скрипте
-- ai_subs.sh, бинарники ищутся локально, затем в PATH. Затем SRT
-- подключается сам.
-- Поля таблицы AI вместо отдельных local-переменных: у главного чанка
-- Lua жёсткий лимит в 200 локальных переменных, а скрипт большой.
local AI = { busy = false, srt = nil, marker = nil, log = nil }
AI.is_windows = package.config:sub(1, 1) == "\\"
AI.sep = AI.is_windows and "\\" or "/"

local function file_exists(p)
    local f = io.open(p, 'rb')
    if f then f:close(); return true end
    return false
end

local function dir_exists(p)
    local info = mp.utils.file_info(p)
    return info ~= nil and info.is_dir == true
end

local function ai_say(text, sec)
    mp.osd_message(text, sec or 3)
end

AI.which = function(name)
    if AI.is_windows then return nil end
    local p = io.popen('command -v ' .. name .. ' 2>/dev/null')
    if not p then return nil end
    local out = p:read('*a')
    p:close()
    out = (out or ''):gsub('%s+$', '')
    if out ~= '' and file_exists(out) then return out end
    return nil
end

local function ai_dir()
    local d = mp.command_native({ 'expand-path', '~~/whisper/' }) or ''
    return (d:gsub('[/\\]+$', ''))
end

-- Язык берём из выбранной аудиодорожки (для дабов), иначе — автоопределение.
local AI_LANG = {
    ja = 'ja', jpn = 'ja', ru = 'ru', rus = 'ru', en = 'en', eng = 'en',
    uk = 'uk', ukr = 'uk', de = 'de', deu = 'de', ger = 'de', fr = 'fr',
    fra = 'fr', fre = 'fr', es = 'es', spa = 'es', it = 'it', ita = 'it',
    ko = 'ko', kor = 'ko', zh = 'zh', chi = 'zh', zho = 'zh', pt = 'pt',
    por = 'pt', pl = 'pl', pol = 'pl', tr = 'tr', tur = 'tr',
}

local function ai_lang()
    for _, t in ipairs(st.track_list or {}) do
        if t.type == 'audio' and t.selected then
            local l = (t.lang or ''):lower()
            if l ~= '' then return AI_LANG[l] or 'auto' end
        end
    end
    return 'auto'
end

function ai_generate()
    if AI.busy then
        ai_say('✨ Распознавание уже идёт, подождите…', 2)
        return
    end
    local raw = mp.get_property('path')
    if not raw or raw == '' then
        ai_say('✨ Сначала откройте видеофайл', 2)
        return
    end
    if raw:find('://', 1, true) then
        ai_say('✨ ИИ-субтитры доступны только для локальных файлов', 3)
        return
    end
    local media = mp.command_native({ 'expand-path', raw })
    if media and not media:match('^%a:[/\\]') and not media:match('^[/\\]') then
        local cwd = mp.get_property('working-directory') or ''
        if cwd ~= '' then media = cwd .. AI.sep .. media end
    end
    if not media or not file_exists(media) then
        ai_say('✨ Файл недоступен для распознавания', 3)
        return
    end
    local wdir = ai_dir()
    local script = wdir .. AI.sep .. (AI.is_windows and 'ai_subs.vbs' or 'ai_subs.sh')
    local model = wdir .. AI.sep .. 'ggml-base.bin'
    -- whisper-cli может лежать в portable_config/whisper, в корне проекта
    -- (на уровень выше ~~/) или быть установленным в систему (PATH).
    local whisper = wdir .. AI.sep .. (AI.is_windows and 'whisper-cli.exe' or 'whisper-cli')
    if not file_exists(whisper) then
        local root = wdir:match('^(.*)[/\\][^/\\]+$')
        local alt = root and (root .. AI.sep .. (AI.is_windows and 'whisper-cli.exe' or 'whisper-cli')) or nil
        if alt and file_exists(alt) then whisper = alt end
    end
    if not file_exists(whisper) and not AI.is_windows then
        local sys = AI.which('whisper-cli')
        if sys then whisper = sys end
    end
    if not file_exists(script) or not file_exists(model) then
        ai_say('✨ whisper.cpp не найден в portable_config/whisper', 4)
        return
    end
    if not file_exists(whisper) and AI.is_windows then
        -- На Windows VBS сам поищет whisper-cli.exe в PATH; не блокируем запуск.
        msg.warn('ai: whisper-cli.exe не найден локально, проверяю PATH')
    end

    local dir, base = media:match('^(.*)[/\\]([^/\\]+)$')
    if not dir then dir, base = '.', media end
    local stem = base:match('^(.*)%.[^%.]+$') or base
    local prefix = dir .. AI.sep .. stem .. '.ai'
    local srt    = prefix .. '.srt'
    local marker = prefix .. '.done'
    local log    = prefix .. '.log'
    local wav    = dir .. AI.sep .. stem .. '.ai.wav'

    os.remove(marker)
    os.remove(log)
    local lang = ai_lang()
    AI.busy, AI.srt, AI.marker, AI.log, AI.wav = true, srt, marker, log, wav
    msg.verbose('ai: media=' .. tostring(media) .. ' srt=' .. srt)
    msg.verbose('ai: whisper dir=' .. wdir .. ' lang=' .. lang)

    local ok, err = pcall(function()
        mp.command_native_async({
            name = 'subprocess',
            args = AI.is_windows
                and { 'wscript.exe', script, media, wav, prefix, marker, log, lang }
                or  { 'sh', script, media, wav, prefix, marker, log, lang },
            detach = true,
        }, function(success, _result, aerr)
            if not success and AI.busy then
                AI.busy, AI.srt, AI.marker, AI.log, AI.wav = false, nil, nil, nil, nil
                ai_say('✨ Не удалось запустить whisper.cpp: ' .. tostring(aerr), 4)
            end
        end)
    end)
    if not ok then
        AI.busy, AI.srt, AI.marker, AI.log, AI.wav = false, nil, nil, nil, nil
        ai_say('✨ Не удалось запустить whisper.cpp: ' .. tostring(err), 4)
        return
    end
    ai_say('✨ Распознавание речи… это может занять несколько минут', 4)
end

local function ai_poll()
    if not AI.busy then return end
    local f = io.open(AI.marker, 'rb')
    if not f then return end
    local data = f:read('*a') or ''
    f:close()
    os.remove(AI.marker)
    AI.busy = false

    local srt = AI.srt
    local sf = io.open(srt, 'rb')
    local size = 0
    if sf then size = sf:seek('end') or 0; sf:close() end

    if size > 32 then
        mp.commandv('sub-add', srt, 'select')
        mp.set_property('sub-visibility', 'yes')
        ai_say('✨ ИИ-субтитры готовы и включены', 3)
        msg.verbose('ai: subtitles added: ' .. srt)
    else
        ai_say('✨ Не удалось распознать речь (' .. (data:gsub('%s+$', '')) ..
            '). Лог: ' .. AI.log, 5)
        msg.warn('ai: failed, marker=' .. data:gsub('%s+$', ''))
    end
    if AI.wav then os.remove(AI.wav) end
    AI.srt, AI.marker, AI.log, AI.wav = nil, nil, nil, nil
    if render then render() end
end

mp.add_periodic_timer(1.0, ai_poll)

-- --------------------------------------------------------- меню настроек
local SPEEDS = { 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0 }

local function speed_label(v)
    if v == 1 or v == 2 then return string.format('%d×', v) end
    return tostring(v) .. '×'
end

local function settings_rows(S)
    local rows = {}
    rows[#rows + 1] = { t = 'title', text = 'Настройки', h = 32 }
    rows[#rows + 1] = { t = 'section', text = 'КАЧЕСТВО ИЗОБРАЖЕНИЯ', h = 23 }
    local cm = current_mode()
    for i, m in ipairs(MODES) do
        rows[#rows + 1] = { t = 'mode', idx = i, label = m.label, sel = (i == cm), h = 27 }
    end

    rows[#rows + 1] = { t = 'section', text = 'СКОРОСТЬ', right = speed_label(st.speed or 1), h = 27 }
    rows[#rows + 1] = { t = 'speed', h = 34 }

    rows[#rows + 1] = { t = 'section', text = 'СУБТИТРЫ', h = 23 }
    rows[#rows + 1] = { t = 'ai', text = '✨ Сгенерировать ИИ-субтитры', h = 30 }
    local subs = sub_items()
    local shown = 0
    for i = 1, #subs do
        if not subs[i].ai and shown < 4 then
            rows[#rows + 1] = { t = 'track', item = subs[i], h = 26 }
            shown = shown + 1
        end
    end

    -- Звук: режимы обработки аудио (внизу окна). Выбор аудиодорожек живёт
    -- в верхней плашке «Аудио», поэтому здесь только улучшайзер звука.
    rows[#rows + 1] = { t = 'section', text = 'ЗВУК', h = 23 }
    for i, m in ipairs(SOUND) do
        rows[#rows + 1] = { t = 'sound', idx = i, label = m.label, sel = (i == sound_mode), h = 27 }
    end

    rows[#rows + 1] = { t = 'hint', text = 'Ctrl+1…5 · Ctrl+0 — шейдеры', h = 25 }
    return rows
end

local function rows_height(rows, S, pad_in)
    local h = pad_in * 2
    for _, r in ipairs(rows) do h = h + r.h * S end
    return h
end

local function draw_settings(ass, W, H, S)
    local base_bottom = H - 150 * S
    local top_min = 84 * S
    local maxh = base_bottom - top_min
    local x1 = W - PAD * S
    local w = math.min(340 * S, W - 2 * PAD * S)
    local x0 = clamp(x1 - w, PAD * S, W - PAD * S - w)
    local pad_in = 10 * S
    local rows = settings_rows(S)
    local h = rows_height(rows, S, pad_in)

    local guard = 0
    while h > maxh and guard < 30 do
        guard = guard + 1
        local removed = false
        for i = #rows, 1, -1 do
            local r = rows[i]
            local removable = (r.t == 'track' or r.t == 'hint'
                or (r.t == 'section' and r.text == 'СУБТИТРЫ'))
            if removable then
                table.remove(rows, i)
                removed = true
                break
            end
        end
        if not removed then break end
        h = rows_height(rows, S, pad_in)
    end

    local y0 = base_bottom - h
    if y0 < top_min then y0 = top_min end
    -- Защита от переполнения: карточка «Настройки» всегда укладывается между
    -- шапкой (top_min) и нижней панелью управления (base_bottom). Если после
    -- удаления необязательных подписей строки всё ещё не влезают (очень
    -- маленькое окно), аккуратно поджимаем их высоту, сохраняя раздел ЗВУК.
    if y0 + h > base_bottom and h > 0 then
        local inner_now = h - pad_in * 2
        local inner_target = base_bottom - y0 - pad_in * 2
        if inner_now > 0 and inner_target > 0 and inner_target < inner_now then
            local k = inner_target / inner_now
            for _, r in ipairs(rows) do r.h = r.h * k end
            h = inner_target + pad_in * 2
        end
    end
    M.menu_rect = { x1 = x0, y1 = y0, x2 = x0 + w, y2 = y0 + h }

    rr(ass, x0 + 3 * S, y0 + 5 * S, x0 + w + 3 * S, y0 + h + 5 * S, 11 * S, '000000', 0x70)
    rr(ass, x0, y0, x0 + w, y0 + h, 11 * S, COL.bg2, 0x08)
    rr_ring(ass, x0, y0, x0 + w, y0 + h, 11 * S, 1.2 * S, COL.border, 0x80)

    local mx, my = -1, -1
    if hovering then mx, my = mouse() end
    local px = 16 * S
    local y = y0 + pad_in

    for _, r in ipairs(rows) do
        local rh = r.h * S
        if r.t == 'title' then
            txt(ass, x0 + px, y + rh / 2, 4, 16 * S, COL.text, 0, r.text, true)
            local cx, cy = x0 + w - 18 * S, y + rh / 2
            txt(ass, cx, cy, 5, 15 * S, COL.muted, 0x20, '✕')
            reg(cx - 12 * S, cy - 12 * S, cx + 12 * S, cy + 12 * S, nil, function()
                menu = nil
                poke()
                render()
            end)
        elseif r.t == 'section' then
            txt(ass, x0 + px, y + rh / 2, 4, 10.5 * S, COL.subtle, 0x10, r.text, true)
            if r.right then
                txt(ass, x0 + w - px, y + rh / 2, 6, 11 * S, COL.green, 0x10, r.right, true)
            end
        elseif r.t == 'mode' then
            local hov = inside({ x1 = x0 + 8 * S, y1 = y, x2 = x0 + w - 8 * S, y2 = y + rh }, mx, my)
            if hov then rr(ass, x0 + 8 * S, y + 1 * S, x0 + w - 8 * S, y + rh - 1 * S, 6 * S, 'ffffff', 0x12) end
            if r.sel then txt(ass, x0 + px, y + rh / 2, 5, 12 * S, COL.green, 0, '✓', true) end
            txt(ass, x0 + px + 22 * S, y + rh / 2, 4, 13 * S,
                r.sel and COL.green or COL.text, r.sel and 0 or 0x18,
                fit(r.label, w - 62 * S, 13 * S))
            local idx = r.idx
            reg(x0 + 8 * S, y, x0 + w - 8 * S, y + rh, nil, function()
                apply_mode(idx)
                poke()
                render()
            end)
        elseif r.t == 'sound' then
            local hov = inside({ x1 = x0 + 8 * S, y1 = y, x2 = x0 + w - 8 * S, y2 = y + rh }, mx, my)
            if hov then rr(ass, x0 + 8 * S, y + 1 * S, x0 + w - 8 * S, y + rh - 1 * S, 6 * S, 'ffffff', 0x12) end
            if r.sel then txt(ass, x0 + px, y + rh / 2, 5, 12 * S, COL.green, 0, '✓', true) end
            txt(ass, x0 + px + 22 * S, y + rh / 2, 4, 13 * S,
                r.sel and COL.green or COL.text, r.sel and 0 or 0x18,
                fit(r.label, w - 62 * S, 13 * S))
            local idx = r.idx
            reg(x0 + 8 * S, y, x0 + w - 8 * S, y + rh, nil, function()
                apply_sound(idx, true)
                poke()
                render()
            end)
        elseif r.t == 'speed' then
            local gap = 6 * S
            local cw = (w - 2 * px - gap * (#SPEEDS - 1)) / #SPEEDS
            for i, sp in ipairs(SPEEDS) do
                local cx = x0 + px + (i - 1) * (cw + gap)
                local on = math.abs((st.speed or 1) - sp) < 0.01
                local hov = inside({ x1 = cx, y1 = y + 2 * S, x2 = cx + cw, y2 = y + rh - 2 * S }, mx, my)
                rr(ass, cx, y + 2 * S, cx + cw, y + rh - 2 * S, 5 * S,
                    on and COL.green or 'ffffff', on and 0 or (hov and 0x1e or 0x12))
                txt(ass, cx + cw / 2, y + rh / 2, 5, 11.5 * S,
                    on and COL.dark or (hov and COL.text or COL.muted), 0, speed_label(sp), on)
                local val = sp
                reg(cx, y + 2 * S, cx + cw, y + rh - 2 * S, nil, function()
                    mp.set_property_number('speed', val)
                    poke()
                    render()
                end)
            end
        elseif r.t == 'track' then
            local it = r.item
            local hov = inside({ x1 = x0 + 8 * S, y1 = y, x2 = x0 + w - 8 * S, y2 = y + rh }, mx, my)
            if hov then rr(ass, x0 + 8 * S, y + 1 * S, x0 + w - 8 * S, y + rh - 1 * S, 6 * S, 'ffffff', 0x12) end
            if it.selected then txt(ass, x0 + px, y + rh / 2, 5, 11 * S, COL.green, 0, '✓', true) end
            txt(ass, x0 + px + 20 * S, y + rh / 2, 4, 12.5 * S,
                it.selected and COL.green or COL.text, it.selected and 0 or 0x18,
                fit(it.label, w - 58 * S, 12.5 * S))
            reg(x0 + 8 * S, y, x0 + w - 8 * S, y + rh, nil, function()
                it.action()
                poke()
                render()
            end)
        elseif r.t == 'ai' then
            local hov = inside({ x1 = x0 + 8 * S, y1 = y, x2 = x0 + w - 8 * S, y2 = y + rh }, mx, my)
            if hov then rr(ass, x0 + 8 * S, y + 1 * S, x0 + w - 8 * S, y + rh - 1 * S, 6 * S, 'ffffff', 0x12) end
            txt(ass, x0 + px, y + rh / 2, 4, 12.5 * S,
                COL.blue2, 0,
                fit(r.text, w - 2 * px, 12.5 * S))
            reg(x0 + 8 * S, y, x0 + w - 8 * S, y + rh, nil, function()
                menu = nil
                ai_generate()
                poke()
                render()
            end)
        elseif r.t == 'hint' then
            txt(ass, x0 + w / 2, y + rh / 2, 5, 10.5 * S, COL.subtle, 0x30, r.text)
        end
        y = y + rh
    end
end

-- --------------------------------------------------------- меню глав
local function draw_chapters(ass, W, H, S)
    local chs = st.chapters or {}
    local w = math.min(360 * S, W - 2 * PAD * S)
    local row_h, head, pad_in = 30 * S, 34 * S, 8 * S
    local x1 = W - PAD * S
    local x0 = clamp(x1 - w, PAD * S, W - PAD * S - w)
    local base_bottom = H - 150 * S
    local top_min = 84 * S
    local max_h = math.max(head + pad_in * 2 + row_h * 3, base_bottom - top_min)
    local max_rows = math.max(3, math.floor((max_h - head - pad_in * 2) / row_h))
    local vis = clamp(#chs, 1, max_rows)
    local h = head + pad_in * 2 + vis * row_h

    local cur = current_chapter_index()
    -- Окно подъезжает к текущей главе только при её смене (или при открытии
    -- меню). Иначе ручная прокрутка стрелками сразу откатывалась бы назад.
    if cur > 0 and cur ~= ch_win_cur then
        ch_win_cur = cur
        if cur < ch_win_start then ch_win_start = cur end
        if cur > ch_win_start + vis - 1 then ch_win_start = cur - vis + 1 end
    end
    ch_win_start = clamp(ch_win_start, 1, math.max(1, #chs - vis + 1))

    local y0 = base_bottom - h
    if y0 < top_min then y0 = top_min end
    M.menu_rect = { x1 = x0, y1 = y0, x2 = x0 + w, y2 = y0 + h }

    rr(ass, x0 + 3 * S, y0 + 5 * S, x0 + w + 3 * S, y0 + h + 5 * S, 11 * S, '000000', 0x70)
    rr(ass, x0, y0, x0 + w, y0 + h, 11 * S, COL.bg2, 0x08)
    rr_ring(ass, x0, y0, x0 + w, y0 + h, 11 * S, 1.2 * S, COL.border, 0x80)
    txt(ass, x0 + 16 * S, y0 + head / 2 + 1 * S, 4, 13 * S,
        COL.muted, 0x10, 'Эпизоды / Таймкоды', true)

    local mx, my = -1, -1
    if hovering then mx, my = mouse() end

    if #chs == 0 then
        txt(ass, x0 + w / 2, y0 + head + pad_in + row_h / 2, 5, 13 * S,
            COL.muted, 0x30, 'В этом видео нет глав')
        return
    end

    -- правая часть шапки: счётчик и стрелки прокрутки
    local cyh = y0 + head / 2 + 1 * S
    local prev_on = ch_win_start > 1
    local next_on = (ch_win_start + vis - 1) < #chs
    if #chs > vis then
        local axl, axr = x0 + w - 78 * S, x0 + w - 16 * S
        txt(ass, x0 + w - 47 * S, cyh, 5, 10.5 * S, COL.subtle, 0x40,
            string.format('%d/%d', cur > 0 and cur or 1, #chs))
        txt(ass, axl, cyh, 5, 14 * S, prev_on and COL.text or COL.subtle,
            prev_on and 0x10 or 0x70, '‹')
        txt(ass, axr, cyh, 5, 14 * S, next_on and COL.text or COL.subtle,
            next_on and 0x10 or 0x70, '›')
        if prev_on then
            reg(axl - 12 * S, cyh - 12 * S, axl + 12 * S, cyh + 12 * S, nil, function()
                ch_win_start = math.max(1, ch_win_start - vis)
                poke(); render()
            end)
        end
        if next_on then
            reg(axr - 12 * S, cyh - 12 * S, axr + 12 * S, cyh + 12 * S, nil, function()
                ch_win_start = math.min(math.max(1, #chs - vis + 1), ch_win_start + vis)
                poke(); render()
            end)
        end
    else
        txt(ass, x0 + w - 16 * S, cyh, 6, 10.5 * S, COL.subtle, 0x40,
            string.format('%d глав', #chs))
    end

    for row = 1, vis do
        local i = ch_win_start + row - 1
        local ch = chs[i]
        if ch then
            local iy = y0 + head + pad_in + (row - 1) * row_h
            local is_cur = (i == cur)
            local hov = inside({ x1 = x0 + 6 * S, y1 = iy,
                                 x2 = x0 + w - 6 * S, y2 = iy + row_h }, mx, my)
            if is_cur then
                -- Мягкая зелёная подсветка (альфа в ASS — прозрачность) +
                -- акцентная полоска слева, чтобы текст оставался читаемым.
                rr(ass, x0 + 6 * S, iy + 1 * S, x0 + w - 6 * S, iy + row_h - 1 * S,
                    6 * S, COL.green, 0xD8)
                rr(ass, x0 + 6 * S, iy + 5 * S, x0 + 9 * S, iy + row_h - 5 * S,
                    1.5 * S, COL.green, 0)
            elseif hov then
                rr(ass, x0 + 6 * S, iy + 1 * S, x0 + w - 6 * S, iy + row_h - 1 * S,
                    6 * S, 'ffffff', 0x10)
            end
            txt(ass, x0 + 14 * S, iy + row_h / 2, 4, 11.5 * S,
                is_cur and COL.green or COL.muted, is_cur and 0 or 0x30,
                fmt_time_floor(ch.time or 0))
            txt(ass, x0 + 72 * S, iy + row_h / 2, 4, 13 * S,
                is_cur and COL.green or COL.text, is_cur and 0 or 0x18,
                fit(ch.title or ('Глава ' .. i), w - 86 * S, 13 * S))
            local seek_to = ch.time or 0
            reg(x0 + 6 * S, iy, x0 + w - 6 * S, iy + row_h, nil, function()
                mp.commandv('seek', string.format('%.3f', seek_to), 'absolute+exact')
                st.time_pos = seek_to
                menu = nil
                poke()
                render()
            end)
        end
    end
end

-- --------------------------------------------------------- отрисовка кадра
function render()
    RT.mok = false
    local W, H = get_dims()
    if not visible or W <= 0 or H <= 0 or st.idle then
        clear_osd()
        regions = {}
        thumb_clear()
        return
    end
    local S = scale_for(H)
    M = { S = S }
    regions = {}
    st.time_pos = mp.get_property_number('time-pos') or st.time_pos or 0
    st.duration = mp.get_property_number('duration') or st.duration or 0

    local ass = assdraw.ass_new()
    draw_footer(ass, W, H, S)
    -- Превью живёт только пока курсор на полосе прогресса. Как только он ушёл
    -- (в том числе вверх — на саму карточку превью), карточку и кадр убираем
    -- мгновенно: карточка не «ловит» мышь и не удерживает себя на экране.
    if not M.hover_seek then
        thumb_card = nil
        thumb_freeze = nil
        if thumb_shown or thumb_visible then thumb_clear() end
        M.preview = nil
    end
    -- В мини-режиме (окно < ~400p) шапку и кнопку заставки не рисуем:
    -- текст там всё равно нечитаем, остаётся только нижняя панель.
    if S > 0.55 then
        draw_header(ass, W, H, S)
        draw_skip(ass, W, H, S)
        draw_ending(ass, W, H, S)
    end
    -- Превью рисуем после кнопок пропуска, чтобы карточка была поверх них
    if M.preview and M.preview.dur > 0 then
        draw_timeline_preview(ass, W, H, M.preview.bar_y, S, M.preview.x,
            M.preview.dur, M.preview.pad)
    end
    if menu then
        if menu.kind == 'audio' or menu.kind == 'sub'
            or menu.kind == 'quality' or menu.kind == 'seasons' then
            draw_list_menu(ass, W, H, S, menu.kind)
        elseif menu.kind == 'settings' then
            draw_settings(ass, W, H, S)
        elseif menu.kind == 'chapters' then
            draw_chapters(ass, W, H, S)
        end
    end

    -- ASS-оверлей может быть сброшен mpv при смене файла/плейлиста,
    -- поэтому раз в 0.4 с отправляем кадр заново даже без изменений.
    local now = mp.get_time()
    if osd.res_x ~= W or osd.res_y ~= H or osd.data ~= ass.text or (now - last_push) > 0.4 then
        osd.data = ass.text
        osd.res_x = W
        osd.res_y = H
        last_data = ass.text
        last_push = now
        osd:update()
    end

    -- Отладочная карта кликабельных зон (используется yummy-debug). Публикуем
    -- не чаще 5 раз в секунду: раньше на каждый кадр создавалась сотня
    -- временных таблиц, которые тут же собирал GC.
    if now - RT.regpush >= 0.2 then
        RT.regpush = now
        local dbg = {}
        for i, r in ipairs(regions) do
            dbg[i] = { x1 = math.floor(r.x1), y1 = math.floor(r.y1),
                       x2 = math.floor(r.x2), y2 = math.floor(r.y2) }
        end
        mp.set_property_native('user-data/yummy/regions', dbg)
    end
end

function toggle_subs()
    if subs_enabled() then
        mp.set_property('sid', 'no')
        mp.osd_message('Субтитры выключены', 2.5)
    else
        local found = false
        for _, t in ipairs(st.track_list or {}) do
            if t.type == 'sub' then
                mp.set_property_number('sid', t.id)
                found = true
                break
            end
        end
        if found then
            mp.osd_message('Субтитры включены', 2.5)
        else
            mp.osd_message('Субтитры не найдены', 2.5)
        end
    end
    poke()
    render()
end

-- Переключение дорожек субтитров по кругу (клавиша j)
function cycle_subs()
    local list = {}
    for _, t in ipairs(st.track_list or {}) do
        if t.type == 'sub' then list[#list + 1] = t end
    end
    if #list == 0 then
        mp.osd_message('Субтитры не найдены', 2.5)
        return
    end

    local cur = 0
    for i, t in ipairs(list) do
        if t.selected then cur = i end
    end

    if cur >= #list then
        mp.set_property('sid', 'no')
        mp.osd_message('Субтитры выключены', 2.5)
    else
        local t = list[cur + 1]
        mp.set_property_number('sid', t.id)
        local name = t.title
        if not name or name == '' then
            name = (t.lang and t.lang ~= '' and (LANG[t.lang] or t.lang:upper())) or ('Дорожка ' .. (cur + 1))
        end
        mp.osd_message('Субтитры: ' .. clean(name), 2.5)
    end
    poke()
    render()
end

local mini_state = nil

function toggle_mini()
    if mini_state then
        mp.set_property_number('window-scale', mini_state.scale)
        mp.set_property('ontop', mini_state.ontop and 'yes' or 'no')
        mini_state = nil
    else
        mini_state = {
            scale = mp.get_property_number('window-scale', 1),
            ontop = mp.get_property_bool('ontop'),
        }
        menu = nil
        mp.set_property('ontop', 'yes')
        mp.set_property_number('window-scale', 0.4)
    end
    poke()
    render()
end

-- --------------------------------------------------------- события мыши
local function on_move(px, py)
    local x, y
    if px then
        x, y = px, py
    else
        sim = nil
        x, y = mp.get_mouse_pos()
    end
    hovering = true
    visible = true
    cursor_sync(true)
    poke()
    if drag == 'seek' then
        do_seek(x)
    elseif drag == 'vol' then
        do_vol(x)
    end
    request_render()
end

local function on_leave()
    hovering = false
    drag = nil
    active_region = nil
    pending_click = nil
    menu = nil
    visible = false
    cursor_sync(false)
    clear_osd()
    regions = {}
    thumb_clear()
end

local function on_down(px, py)
    local x, y
    if px then
        x, y = px, py
    else
        sim = nil
        x, y = mp.get_mouse_pos()
    end
    hovering = true
    visible = true
    cursor_sync(true)
    poke()

    if menu then
        if M.menu_rect and not inside(M.menu_rect, x, y) then
            menu = nil
            render()
            return
        end
        local r = hit(x, y)
        if r then
            active_region = r
            if r.down then r.down(x, y) end
            render()
        end
        return
    end

    local r = hit(x, y)
    if r then
        active_region = r
        if r.down then r.down(x, y) end
    else
        pending_click = { x = x, y = y }
    end
    render()
end

local function on_up(px, py)
    local x, y
    if px then
        x, y = px, py
    else
        x, y = mp.get_mouse_pos()
    end

    if drag then
        drag = nil
        render()
        return
    end

    if active_region then
        local r = active_region
        active_region = nil
        if r.up and inside(r, x, y) then r.up(x, y) end
        render()
        return
    end

    if pending_click then
        local pc = pending_click
        pending_click = nil
        if math.abs(x - pc.x) <= 6 and math.abs(y - pc.y) <= 6 then
            if dbl_timer then
                dbl_timer:kill()
                dbl_timer = nil
            else
                dbl_timer = mp.add_timeout(0.22, function()
                    dbl_timer = nil
                    mp.commandv('cycle', 'pause')
                end)
            end
        end
    end
end

local function on_dbl(px, py)
    if dbl_timer then
        dbl_timer:kill()
        dbl_timer = nil
    end
    pending_click = nil
    local x, y
    if px then
        x, y = px, py
    else
        sim = nil
        x, y = mp.get_mouse_pos()
    end
    hovering = true
    poke()
    if menu then
        menu = nil
        render()
        return
    end
    if hit(x, y) then return end
    mp.commandv('cycle', 'fullscreen')
    render()
end

local function on_wheel(dir, px, py)
    local x, y
    if px then
        x, y = px, py
    else
        sim = nil
        x, y = mp.get_mouse_pos()
    end
    hovering = true
    visible = true
    poke()
    if M.vol and x >= M.vol.x0 - 8 * M.S and x <= M.vol.x1 + 8 * M.S
        and y >= M.vol.y0 and y <= M.vol.y1 then
        mp.commandv('add', 'volume', dir > 0 and '5' or '-5')
    else
        mp.commandv('seek', dir > 0 and '10' or '-10')
    end
    request_render()
end

-- --------------------------------------------------------- наблюдатели
local function bind(name, kind, key, extra)
    mp.observe_property(name, kind, function(_, v)
        if key then st[key] = v end
        if extra then extra(v) end
        render()
    end)
end

bind('pause', 'bool', 'pause')
bind('volume', 'number', 'volume')
bind('mute', 'bool', 'mute')
bind('aid', 'native', 'aid')
bind('sid', 'native', 'sid')
bind('vid', 'native', 'vid')
bind('speed', 'number', 'speed')
bind('track-list', 'native', 'track_list')
bind('playlist', 'native', 'playlist', function()
    seasons_refresh()
    episodes_refresh()
end)
bind('playlist-pos', 'number', 'playlist_pos', function()
    EPISODES.cur = clamp((st.playlist_pos or 0) + 1, 1, math.max(1, #(st.playlist or {})))
end)
bind('chapter-list', 'native', 'chapters')
bind('fullscreen', 'bool', 'fullscreen')
bind('media-title', 'string', 'media_title')
bind('idle-active', 'bool', 'idle', function()
    if st.idle then
        visible = false
        clear_osd()
        regions = {}
        thumb_clear()
    end
end)
bind('osd-dimensions', 'native', nil, function() end)

mp.register_event('file-loaded', function()
    st.skip_used = false
    st.ending_used = false
    st.time_pos = 0
    st.duration = mp.get_property_number('duration') or 0
    -- pl_win_start не сбрасываем: иначе прокрутка/выбор серии откатывались бы
    -- на первый квадрат при каждом переключении. Окно само подъедет к серии.
    ch_win_start = 1
    ch_win_cur = nil
    -- Выбранный режим улучшения звука переносим на новый файл/поток.
    if sound_mode ~= 1 then
        mp.commandv('af', 'set', SOUND[sound_mode].af)
    end
    -- Возврат после переключения качества: шейдеры, звук, пауза, уведомление.
    if pending_reload then
        local pr = pending_reload
        pending_reload = nil
        -- loadfile не сбрасывает glsl-shaders, поэтому при нераспознанном
        -- режиме (0) ничего не трогаем: цепочка шейдеров остаётся как была.
        if pr.mode and pr.mode > 0 then
            apply_mode(pr.mode, true)          -- без OSD «Режим: ...»
        end
        if pr.paused then mp.set_property('pause', 'yes') end
        -- Вернуть ту же секунду, что была до переключения качества.
        if pr.pos and pr.pos > 0.5 then
            local target = pr.pos
            mp.add_timeout(0.05, function()
                local dur = mp.get_property_number('duration') or 0
                if dur <= 0 or target < dur - 1 then
                    mp.commandv('seek', target, 'absolute')
                end
            end)
        end
        if quality_target and quality_target.reload then
            quality_target.loaded = true
            quality_target.loaded_at = mp.get_time()
        end
        -- Показываем ровно то качество, что выбрал пользователь (не «съезжаем»
        -- на фактическую высоту широкого кадра).
        mp.add_timeout(0.25, function()
            quality_notify(quality_label_current())
        end)
    else
        -- Файл сменился не из-за качества (плейлист, открытие) — цель сбрасываем.
        quality_target = nil
        -- Ручной выбор относился к конкретной серии/потоку. Новая серия —
        -- снова «Авто», пока пользователь не выберет качество для неё.
        if quality_pick then
            local cur = quality_norm_url(mp.get_property('path'))
            local want = quality_pick.url or quality_pick.path
            if want and cur ~= quality_norm_url(want) then
                quality_pick_clear()
            end
        end
    end
    thumb_clear()
    thumb_img = nil
    -- Новая серия/сезон: заставляем перечитать метаданные качества сразу,
    -- не дожидаясь секундного окна кэша.
    RT.qmeta = 0
    seasons_refresh()
    episodes_refresh()
    poke()
    render()
end)

mp.register_event('end-file', function()
    clear_osd()
    last_data = ''
    thumb_clear()
    thumb_img = nil
    -- Файл сменился/остановился: фоновое распознавание к нему больше не относится.
    if AI.busy then
        AI.busy, AI.srt, AI.marker, AI.log, AI.wav = false, nil, nil, nil, nil
    end
end)

-- --------------------------------------------------------- таймер видимости
-- Таймер живёт только пока панели могут быть на экране. Как только они
-- спрятаны по таймауту (или файл не открыт), он останавливается: в простое
-- скрипт не просыпается вообще (0% CPU), а будит его реальное движение мыши,
-- клик или нажатие клавиши с действием интерфейса (через poke()).
RT.tick = mp.add_periodic_timer(0.2, function()
    if st.idle then
        cursor_sync(false)
        if visible then
            visible = false
            clear_osd()
            regions = {}
            thumb_clear()
        end
        if RT.tick:is_enabled() then RT.tick:stop() end
        return
    end
    st.time_pos = mp.get_property_number('time-pos') or st.time_pos or 0
    local now = mp.get_time()
    local want = ((hovering and (now - last_activity) < HIDE_SEC)
        or (menu ~= nil) or (drag ~= nil)) and true or false
    -- Курсор живёт по тому же таймеру, что и панели: виден, пока двигают
    -- мышь/открыто меню, и гарантированно исчезает вместе с интерфейсом.
    cursor_sync(want)
    if want ~= visible then
        visible = want
        if not visible then
            clear_osd()
            regions = {}
            thumb_clear()
        end
    end
    if visible then
        request_render()
    elseif RT.tick:is_enabled() then
        -- Панели спрятаны (таймаут, уход курсора из окна, закрытое меню):
        -- таймер больше не нужен. Следующее движение мыши/клавиша разбудит
        -- его через poke() — до тех пор скрипт не потребляет CPU.
        RT.tick:stop()
    end
end)
-- Стартуем «спящими»: первый кадр покажет первое движение мыши.
RT.tick:stop()

-- --------------------------------------------------------- привязки мыши
mp.set_key_bindings({
    { 'mouse_move', function() on_move() end },
    { 'mouse_leave', on_leave },
}, 'yummy_showhide', 'force')
mp.enable_key_bindings('yummy_showhide', 'allow-hide-cursor')

mp.set_key_bindings({
    { 'mbtn_left', function() on_up() end, function() on_down() end },
    { 'mbtn_left_dbl', function() on_dbl() end },
    { 'wheel_up', function() on_wheel(1) end },
    { 'wheel_down', function() on_wheel(-1) end },
}, 'yummy_input', 'force')
mp.enable_key_bindings('yummy_input')

-- Отладочные сообщения: script-message-to yummy_ui yummy-debug click 640 680
mp.register_script_message('yummy-debug', function(cmd, a, b)
    cmd = tostring(cmd or '')
    local x, y = tonumber(a), tonumber(b)
    if cmd == 'move' and x then
        sim = { x = x, y = y }
        on_move(x, y)
    elseif cmd == 'down' and x then
        sim = { x = x, y = y }
        on_down(x, y)
    elseif cmd == 'up' and x then
        sim = { x = x, y = y }
        on_up(x, y)
    elseif cmd == 'click' and x then
        sim = { x = x, y = y }
        on_down(x, y)
        on_up(x, y)
    elseif cmd == 'dbl' and x then
        sim = { x = x, y = y }
        on_dbl(x, y)
    elseif cmd == 'wheel' then
        on_wheel(tonumber(a) or 1)
    elseif cmd == 'show' then
        hovering = true
        visible = true
        poke()
        render()
    elseif cmd == 'hide' then
        on_leave()
    elseif cmd == 'menu' then
        menu = { kind = tostring(a or 'settings') }
        hovering = true
        visible = true
        poke()
        render()
    elseif cmd == 'dump' then
        local W, H = get_dims()
        local tmp = AI.is_windows and (os.getenv('TEMP') or '.')
            or (os.getenv('TMPDIR') or '/tmp')
        tmp = tmp:gsub('[/\\]+$', '')
        local f = io.open(tmp .. AI.sep .. 'yummy_ui_dump.txt', 'w')
        if f then
            f:write(string.format('W=%d H=%d S=%.3f visible=%s menu=%s drag=%s\n',
                W, H, scale_for(H), tostring(visible), menu and menu.kind or 'none', tostring(drag)))
            f:write(string.format('time=%.3f duration=%.3f pause=%s vol=%.1f mute=%s aid=%s sid=%s speed=%.2f\n',
                st.time_pos or 0, st.duration or 0, tostring(st.pause),
                st.volume or 0, tostring(st.mute), tostring(st.aid), tostring(st.sid), st.speed or 1))
            local pl = st.playlist or {}
            f:write(string.format('playlist=%d pos=%s\n', #pl, tostring(st.playlist_pos)))
            f:write(string.format('first_entry=%s\n', tostring(pl[1] and (pl[1].filename or pl[1].title) or '')))
            f:write(string.format('seasons=%d active=%d visible=%s\n',
                #SEASONS.list, SEASONS.active, tostring(seasons_visible())))
            for si, sv in ipairs(SEASONS.list) do
                f:write(string.format('season %d: %s | count=%d | %s\n',
                    si, tostring(sv.short), tonumber(sv.count) or 0, tostring(sv.playlist)))
            end
            f:write(string.format('mode=%d glsl=%s\n', current_mode(), tostring(mp.get_property('glsl-shaders'))))
            local sw = skip_state() and true or false
            local ew = ending_state() and true or false
            f:write(string.format('skip_show=%s ending_show=%s ending_used=%s ai_busy=%s\n',
                tostring(sw), tostring(ew), tostring(st.ending_used), tostring(AI.busy)))
            -- Отладочный список пунктов меню: '*' — выбранный, '-' — обычный.
            local function dump_items(name, items)
                local acc = {}
                for _, it in ipairs(items or {}) do
                    acc[#acc + 1] = (it.selected and '*' or '-') .. tostring(it.label)
                end
                f:write(string.format('%s [%d]: %s\n', name, #(items or {}), table.concat(acc, ' | ')))
            end
            f:write(string.format('pill_quality=%s\n', tostring(quality_label_current())))
            f:write(string.format('cursor=%s pick=%s\n',
                tostring(mp.get_property('cursor-autohide')),
                tostring(quality_pick and quality_pick.label or 'none')))
            f:write(string.format('episodes=%d cur=%d win_start=%d win_vis=%s qh=%s\n',
                #EPISODES.list, tonumber(EPISODES.cur) or 0, tonumber(pl_win_start) or 0,
                tostring(pl_win_vis), tostring(EPISODES.quality_h)))
            local chip_labels = {}
            local vis_n = tonumber(pl_win_vis) or 0
            for ci = pl_win_start, math.min(#(st.playlist or {}), pl_win_start + vis_n - 1) do
                local ce = EPISODES.list[ci]
                chip_labels[#chip_labels + 1] = tostring(ce and ce.num or ci)
            end
            f:write(string.format('chip_labels=%s\n', table.concat(chip_labels, ',')))
            if M.menu_rect then
                f:write(string.format('menu_rect=%.0f,%.0f - %.0f,%.0f\n',
                    M.menu_rect.x1, M.menu_rect.y1, M.menu_rect.x2, M.menu_rect.y2))
            end
            f:write(string.format('ytdl_format=%s\n', tostring(mp.get_property('ytdl-format'))))
            f:write(string.format('video_h=%d online=%s\n', quality_actual_h(),
                tostring(mp.get_property_native('demuxer-via-network'))))
            f:write(string.format('preview=%s hover_seek=%s thumb_shown=%s thumb_visible=%s\n',
                tostring(M.preview ~= nil), tostring(M.hover_seek == true),
                tostring(thumb_shown), tostring(thumb_visible)))
            dump_items('audio', audio_items())
            dump_items('quality', quality_items())
            dump_items('sound', sound_items())
            for i, r in ipairs(regions) do
                f:write(string.format('%d: %.0f,%.0f - %.0f,%.0f\n', i, r.x1, r.y1, r.x2, r.y2))
            end
            f:close()
        end
    elseif cmd == 'reset' then
        sim = nil
        hovering = false
        visible = false
        clear_osd()
        regions = {}
    elseif cmd == 'region' then
        local n = tonumber(a)
        local r = regions[n]
        if r then
            local cx, cy = (r.x1 + r.x2) / 2, (r.y1 + r.y2) / 2
            sim = { x = cx, y = cy }
            hovering = true
            visible = true
            poke()
            on_down(cx, cy)
            on_up(cx, cy)
        end
    end
end)

seasons_refresh()
msg.verbose('yummy_ui: loaded (custom UI)')

-- Ручной запуск ИИ-субтитров: script-message ai-subs
mp.register_script_message('ai-subs', function() ai_generate() end)

-- --------------------------------------------------------- режимы шейдеров
-- Ctrl+1..5 и Ctrl+0 из input.conf приходят сюда: скрипт сам выбирает
-- HQ (_VL) или быструю (_M/_S) цепочку по профилю видеокарты.
mp.register_script_message('shader-mode', function(v)
    local idx = tonumber(v) or 1
    if idx == 0 then idx = #MODES end
    apply_mode(idx)
end)

-- --------------------------------------------------------- субтитры (v / j)
mp.register_script_message('subs-toggle', function() toggle_subs() end)
mp.register_script_message('subs-cycle', function() cycle_subs() end)

-- --------------------------------------------------------- звук (ALT+5..ALT+8)
-- 1 — Оригинал, 2 — Четкий голос, 3 — Улучшение, 4 — Кинотеатр.
mp.register_script_message('sound-mode', function(v)
    apply_sound(tonumber(v) or 1, true)
end)

-- --------------------------------------------------------- thumbfast
-- thumbfast присылает актуальные размеры кадра (JSON). Пока кадр не готов
-- или скрипт отключён (аудио/сеть), показываем текстовую карточку.
mp.register_script_message('thumbfast-info', function(json)
    local ok, data = pcall(utils.parse_json, json)
    if not ok or type(data) ~= 'table' or not data.width or not data.height then
        msg.error('thumbfast-info: некорректный JSON')
        return
    end
    thumb.width = tonumber(data.width) or 0
    thumb.height = tonumber(data.height) or 0
    thumb.disabled = (data.disabled == true)
    thumb.available = (data.available ~= false)
    render()
end)

-- Полный контроль отрисовки: thumbfast отдал готовый кадр (JSON).
-- Рисуем его сами через overlay-add в точке thumb_pos.
mp.register_script_message('thumbfast-render', function(json)
    local ok, data = pcall(utils.parse_json, json)
    if not ok or type(data) ~= 'table' or not data.thumbnail then
        msg.error('thumbfast-render: некорректный JSON')
        return
    end
    local w = tonumber(data.width) or thumb.width
    local h = tonumber(data.height) or thumb.height
    thumb.width, thumb.height = w, h
    thumb_img = {
        -- thumbfast отдаёт базовый путь; готовый BGRA-кадр лежит рядом
        -- с суффиксом .bgra (как и в его собственной отрисовке).
        path = tostring(data.thumbnail) .. '.bgra',
        w = w,
        h = h,
        id = tonumber(data.overlay_id) or 42,
    }
    if thumb_shown and thumb_pos then
        overlay_add_thumb(thumb_pos.x, thumb_pos.y)
    end
end)

mp.register_event('shutdown', function() thumb_clear() end)

