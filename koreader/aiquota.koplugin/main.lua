-- AI Quota Dashboard for KOReader
-- Version 5: KPW1 landscape layout (1024 x 758), monochrome e-ink friendly.

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local NetworkMgr = require("ui/network/manager")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Screen = Device.screen
local TextWidget = require("ui/widget/textwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local json = require("json")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")

local REFRESH_SECONDS = 300
local LOW_BATTERY_REFRESH_SECONDS = 900
local REQUEST_BLOCK_TIMEOUT = 8
local REQUEST_TOTAL_TIMEOUT = 15
local MAX_RESPONSE_BYTES = 256 * 1024
local CACHE_FILE = DataStorage:getDataDir() .. "/aiquota-dashboard-cache.json"
local S = function(value) return Screen:scaleBySize(value) end

local function text_value(value, fallback)
    if value == nil or value == "" then
        return fallback or "-"
    end
    return tostring(value)
end

local function number_or_nil(value)
    local number = tonumber(value)
    if number then
        return math.max(0, math.min(100, number))
    end
    return nil
end

local function compact_timestamp(value, short_date)
    local text = text_value(value, "-")
    local date, time = text:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
    if not date then
        date, time = text:match("^(%d%d%d%d%-%d%d%-%d%d) (%d%d:%d%d)")
    end
    if not date then
        return text
    end
    if short_date then
        return date:sub(6) .. " " .. time
    end
    return date .. " " .. time
end

local function timestamp_epoch(value)
    if type(value) ~= "string" then
        return nil
    end
    local year, month, day, hour, minute, second =
        value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):?(%d*)")
    if not year then
        return nil
    end
    return os.time{
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(minute),
        sec = tonumber(second) or 0,
    }
end

local function age_text(value)
    local epoch = timestamp_epoch(value)
    if not epoch then
        return "时间未知"
    end
    local age = math.max(0, os.time() - epoch)
    if age < 90 then
        return "刚刚"
    elseif age < 3600 then
        return string.format("%d 分钟前", math.floor(age / 60))
    elseif age < 86400 then
        return string.format("%d 小时前", math.floor(age / 3600))
    end
    return string.format("%d 天前", math.floor(age / 86400))
end

local function calendar_text(data)
    local calendar = type(data.calendar) == "table" and data.calendar or {}
    local weekdays = {
        ["0"] = "星期日",
        ["1"] = "星期一",
        ["2"] = "星期二",
        ["3"] = "星期三",
        ["4"] = "星期四",
        ["5"] = "星期五",
        ["6"] = "星期六",
    }
    local solar = calendar.solar
    if not solar then
        solar = os.date("%Y年%m月%d日 ") .. text_value(weekdays[os.date("%w")], "")
    end
    return solar, text_value(calendar.lunar, "农历日期不可用")
end

local function text_widget(value, size, max_width, bold)
    return TextWidget:new{
        text = text_value(value),
        -- Font:getFace performs Screen:scaleBySize internally.
        face = Font:getFace("cfont", size),
        max_width = max_width,
        padding = 0,
        bold = bold == true,
    }
end

local function fixed_content(children, width, height)
    local args = { align = "left" }
    table.insert(args, HorizontalSpan:new{ width = width })
    local natural_height = 0
    for _, child in ipairs(children) do
        table.insert(args, child)
        natural_height = natural_height + child:getSize().h
    end
    if natural_height < height then
        table.insert(args, VerticalSpan:new{ width = height - natural_height })
    end
    return VerticalGroup:new(args)
end

local function spacer(height)
    return VerticalSpan:new{ width = height }
end

local function left_cell(widget, width, height)
    return LeftContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = width, h = height },
        allow_mirroring = false,
        widget,
    }
end

local function right_cell(widget, width, height)
    return RightContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = width, h = height },
        allow_mirroring = false,
        widget,
    }
end

local function card(children, width, height, border_size)
    local border = border_size or S(2)
    local padding = S(12)
    local inner_width = width - 2 * (border + padding)
    local inner_height = height - 2 * (border + padding)
    return FrameContainer:new{
        width = width,
        height = height,
        padding = padding,
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE,
        fixed_content(children, inner_width, inner_height),
    }
end

local WeatherIcon = Widget:extend{
    width = S(34),
    height = S(34),
    kind = "sun",
}

function WeatherIcon:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function WeatherIcon:paintSun(bb, x, y)
    local cx = x + math.floor(self.width / 2)
    local cy = y + math.floor(self.height / 2)
    local radius = math.max(S(5), math.floor(self.width / 6))
    local line = math.max(1, S(1))
    local ray = math.max(S(4), math.floor(self.width / 7))
    bb:paintCircle(cx, cy, radius, Blitbuffer.COLOR_BLACK, line)
    bb:paintRect(cx - line, y, line * 2, ray, Blitbuffer.COLOR_BLACK)
    bb:paintRect(cx - line, y + self.height - ray, line * 2, ray, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, cy - line, ray, line * 2, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + self.width - ray, cy - line, ray, line * 2, Blitbuffer.COLOR_BLACK)
    for offset = 0, math.max(1, S(3)) do
        bb:setPixelClamped(x + S(5) + offset, y + S(5) + offset, Blitbuffer.COLOR_BLACK)
        bb:setPixelClamped(x + self.width - S(6) - offset, y + S(5) + offset, Blitbuffer.COLOR_BLACK)
        bb:setPixelClamped(x + S(5) + offset, y + self.height - S(6) - offset, Blitbuffer.COLOR_BLACK)
        bb:setPixelClamped(
            x + self.width - S(6) - offset,
            y + self.height - S(6) - offset,
            Blitbuffer.COLOR_BLACK
        )
    end
end

function WeatherIcon:paintCloud(bb, x, y)
    local base_y = y + math.floor(self.height * 0.58)
    local left = x + S(4)
    local width = self.width - S(8)
    bb:paintCircle(left + S(7), base_y, S(6), Blitbuffer.COLOR_BLACK, S(2))
    bb:paintCircle(left + S(14), base_y - S(4), S(8), Blitbuffer.COLOR_BLACK, S(2))
    bb:paintCircle(left + S(22), base_y, S(6), Blitbuffer.COLOR_BLACK, S(2))
    bb:paintRect(left + S(4), base_y + S(5), width - S(8), S(2), Blitbuffer.COLOR_BLACK)
end

function WeatherIcon:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    if self.kind == "sun" then
        self:paintSun(bb, x, y)
        return
    end
    self:paintCloud(bb, x, y)
    if self.kind == "rain" then
        local rain_y = y + math.floor(self.height * 0.76)
        for i = 0, 2 do
            bb:paintRect(x + S(9) + i * S(7), rain_y, S(2), S(6), Blitbuffer.COLOR_BLACK)
        end
    elseif self.kind == "snow" then
        local snow_y = y + math.floor(self.height * 0.82)
        for i = 0, 2 do
            local snow_x = x + S(9) + i * S(7)
            bb:paintRect(snow_x - S(2), snow_y, S(5), S(1), Blitbuffer.COLOR_BLACK)
            bb:paintRect(snow_x, snow_y - S(2), S(1), S(5), Blitbuffer.COLOR_BLACK)
        end
    end
end

local function weather_kind(weather)
    local key = string.lower(text_value(weather.iconKey, ""))
    local description = string.lower(text_value(weather.description, ""))
    local combined = key .. " " .. description
    if combined:find("snow", 1, true) or combined:find("雪", 1, true) then
        return "snow"
    elseif combined:find("rain", 1, true) or combined:find("shower", 1, true)
            or combined:find("雨", 1, true) then
        return "rain"
    elseif combined:find("cloud", 1, true) or combined:find("overcast", 1, true)
            or combined:find("阴", 1, true) or combined:find("云", 1, true) then
        return "cloud"
    end
    return "sun"
end

local function metric(label, value, width, height)
    local group = VerticalGroup:new{
        align = "left",
        text_widget(label, 10, width, false),
        spacer(S(2)),
        text_widget(value, 13, width, true),
    }
    return left_cell(group, width, height)
end

local function quota_label(window)
    local name = text_value(window.name, "周")
    if name:find("周", 1, true) then
        return "周"
    elseif name:find("月", 1, true) then
        return "月"
    end
    return name
end

local function battery_capacity()
    local ok, value = pcall(function()
        return Device:getPowerDevice():getCapacity()
    end)
    if ok and tonumber(value) then
        return math.max(0, math.min(100, math.floor(tonumber(value) + 0.5)))
    end
    return nil
end

local function device_status()
    local capacity = battery_capacity()
    local battery = capacity and ("电量 " .. capacity .. "%") or "电量 --"
    local wifi = "Wi-Fi 关闭"
    local ok_on, is_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if ok_on and is_on then
        local ok_connected, connected = pcall(function() return NetworkMgr:isConnected() end)
        wifi = ok_connected and connected and "Wi-Fi 在线" or "Wi-Fi 未联网"
    end
    return battery .. " · " .. wifi
end

local function quota_card(window, width, height)
    local inner_width = width - S(28)
    local used = number_or_nil(window.usedPct)
    local used_text = used and string.format("%d%% used", math.floor(used + 0.5)) or "-- used"
    local provider_width = S(110)
    local value_width = S(190)
    local row_height = S(35)
    local bar = ProgressWidget:new{
        width = inner_width,
        height = S(18),
        percentage = used and used / 100 or 0,
        bordersize = S(2),
        margin_h = S(3),
        margin_v = S(1),
        radius = 0,
        bordercolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_WHITE,
        fillcolor = Blitbuffer.COLOR_BLACK,
    }
    local top_row = HorizontalGroup:new{
        allow_mirroring = false,
        left_cell(
            text_widget("QUOTA", 13, inner_width - provider_width, true),
            inner_width - provider_width,
            S(22)
        ),
        right_cell(text_widget("Codex", 13, provider_width, true), provider_width, S(22)),
    }
    local value_row = HorizontalGroup:new{
        allow_mirroring = false,
        left_cell(
            text_widget(quota_label(window), 14, inner_width - value_width, true),
            inner_width - value_width,
            row_height
        ),
        right_cell(text_widget(used_text, 27, value_width, true), value_width, row_height),
    }
    return card({
        top_row,
        spacer(S(8)),
        value_row,
        spacer(S(8)),
        bar,
        spacer(S(7)),
        text_widget("Reset: " .. compact_timestamp(window.resetAt, true), 11, inner_width, false),
    }, width, height)
end

local function load_cache()
    local file = io.open(CACHE_FILE, "r")
    if not file then
        return nil
    end
    local body = file:read("*a")
    file:close()
    local ok, data = pcall(json.decode, body)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

local function save_cache(data)
    local ok, encoded = pcall(json.encode, data)
    if ok and type(encoded) == "string" then
        return util.writeToFile(encoded, CACHE_FILE, true)
    end
    return false
end

local function capped_sink(target)
    local received = 0
    return function(chunk, err)
        if chunk then
            received = received + #chunk
            if received > MAX_RESPONSE_BYTES then
                return nil, "response too large"
            end
            target[#target + 1] = chunk
        end
        return 1, err
    end
end

local DashboardView = InputContainer:extend{
    covers_fullscreen = true,
}

function DashboardView:init()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local is_landscape = screen_width > screen_height
    local outer = is_landscape and S(26) or S(18)
    local gap = S(12)
    local content_width = screen_width - 2 * outer
    local data = self.data or {}
    local state = self.view_state or {}
    local sources = data.sources or {}
    local codex = sources.codex or {}
    local weather = data.weather or {}
    local solar_date, lunar_date = calendar_text(data)

    local header_height = is_landscape and S(62) or S(78)
    local status_height = is_landscape and S(34) or S(38)
    local top_height = is_landscape and S(166) or S(182)
    local quota_height = is_landscape and S(166) or S(184)
    local footer_height = S(31)

    local header_right_width = math.floor(content_width * 0.36)
    local title_width = content_width - header_right_width
    local right_header = VerticalGroup:new{
        align = "right",
        text_widget(os.date("%H:%M"), 21, header_right_width, true),
        spacer(S(1)),
        text_widget(solar_date, 10, header_right_width, true),
        text_widget(lunar_date, 10, header_right_width, true),
        text_widget(device_status(), 9, header_right_width, false),
    }
    local header = is_landscape and fixed_content({
        HorizontalGroup:new{
            allow_mirroring = false,
            left_cell(
                text_widget("KINDLE AI QUOTA DASHBOARD", 19, title_width, true),
                title_width,
                header_height
            ),
            right_cell(right_header, header_right_width, header_height),
        },
        },
        content_width,
        header_height
    ) or fixed_content({
        text_widget("KINDLE AI QUOTA DASHBOARD", 18, content_width, true),
        spacer(S(3)),
        text_widget(os.date("%H:%M  ") .. solar_date, 13, content_width, true),
        text_widget(lunar_date .. " · " .. device_status(), 10, content_width, false),
    }, content_width, header_height)

    local last_success = state.last_success_at or data.updatedAt
    local status_text
    if state.mode == "loading" then
        status_text = "正在连接数据源…"
    elseif state.mode == "cached" then
        status_text = "正在使用离线缓存 · 更新 " .. compact_timestamp(last_success, true)
            .. " · " .. age_text(last_success)
    elseif state.mode == "error" then
        status_text = "更新失败 · " .. text_value(state.message, "未知错误")
    else
        status_text = "数据已同步 · 更新 " .. compact_timestamp(last_success, true)
            .. " · " .. age_text(last_success)
    end
    local status = card({
        text_widget(status_text, 10, content_width - S(22), true),
    }, content_width, status_height, S(2))

    local card_gap = S(14)
    local now_width = math.floor((content_width - card_gap) * 0.43)
    local weather_width = content_width - card_gap - now_width
    local inner_now = now_width - S(28)
    local inner_weather = weather_width - S(28)
    local weather_place = text_value(weather.place, "扬州")
    local weather_description = text_value(weather.description, "--")
    local weather_temp = text_value(weather.tempC, "--") .. " C"
    local weather_feels = "体感 " .. text_value(weather.feelsLikeC, "--") .. " C"
    local weather_humidity = "湿度 " .. text_value(weather.humidity, "--") .. "%"
    local weather_wind = "风 " .. text_value(weather.windKph, "--") .. " km/h"
    local weather_title = HorizontalGroup:new{
        allow_mirroring = false,
        left_cell(
            WeatherIcon:new{ kind = weather_kind(weather) },
            S(42),
            S(34)
        ),
        left_cell(
            text_widget(weather_place .. "  " .. weather_description, 16, inner_weather - S(42), true),
            inner_weather - S(42),
            S(34)
        ),
    }
    local metric_gap = S(12)
    local metric_width = math.floor((inner_weather - metric_gap) / 2)
    local metric_height = S(35)
    local weather_metrics_1 = HorizontalGroup:new{
        allow_mirroring = false,
        metric("温度", weather_temp, metric_width, metric_height),
        HorizontalSpan:new{ width = metric_gap },
        metric("体感", weather_feels, metric_width, metric_height),
    }
    local weather_metrics_2 = HorizontalGroup:new{
        allow_mirroring = false,
        metric("湿度", weather_humidity, metric_width, metric_height),
        HorizontalSpan:new{ width = metric_gap },
        metric("风速", weather_wind, metric_width, metric_height),
    }
    local now_card = card({
        text_widget("NOW", 13, inner_now, true),
        spacer(S(11)),
        text_widget(os.date("%H:%M"), 37, inner_now, true),
        spacer(S(2)),
        text_widget(solar_date, 11, inner_now, true),
        text_widget(lunar_date, 11, inner_now, true),
    }, now_width, top_height)
    local weather_card = card({
        text_widget("WEATHER", 13, inner_weather, true),
        spacer(S(4)),
        weather_title,
        spacer(S(4)),
        weather_metrics_1,
        spacer(S(3)),
        weather_metrics_2,
    }, weather_width, top_height)
    local top_row = HorizontalGroup:new{
        allow_mirroring = false,
        now_card,
        HorizontalSpan:new{ width = card_gap },
        weather_card,
    }

    local quota_window
    if codex.ok and type(codex.windows) == "table" then
        for _, window in ipairs(codex.windows) do
            if not quota_window or quota_label(window) == "周" then
                quota_window = window
            end
        end
    end
    local quota
    if quota_window then
        quota = quota_card(quota_window, content_width, quota_height)
    else
        local reason = state.message or codex.error or "暂时无法取得额度数据"
        quota = card({
            text_widget("QUOTA", 13, content_width - S(28), true),
            spacer(S(13)),
            text_widget("暂时无法取得额度数据", 17, content_width - S(28), true),
            spacer(S(5)),
            text_widget(reason, 10, content_width - S(28), false),
        }, content_width, quota_height)
    end

    local footer_updated = last_success or data.updatedAt
    local footer = fixed_content({
        text_widget(
            "更新: " .. compact_timestamp(footer_updated, false) .. " · " .. age_text(footer_updated),
            10,
            content_width,
            false
        ),
        spacer(S(2)),
        text_widget("每 5 分钟检查更新 · 点击屏幕关闭", 10, content_width, false),
    }, content_width, footer_height)

    local children = { header, spacer(gap), status, spacer(gap), top_row, spacer(gap), quota }
    local fixed_height = header_height + status_height + top_height + quota_height + footer_height + gap * 3
    local available_height = screen_height - 2 * outer
    local bottom_fill = available_height - fixed_height
    table.insert(children, spacer(bottom_fill > 0 and bottom_fill or gap))
    table.insert(children, footer)

    self.dimen = Geom:new{ x = 0, y = 0, w = screen_width, h = screen_height }
    self[1] = FrameContainer:new{
        width = screen_width,
        height = screen_height,
        padding = outer,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left", unpack(children) },
    }

    self.ges_events.TapClose = {
        GestureRange:new{
            ges = "tap",
            range = function() return self.dimen end,
        }
    }
    self.ges_events.SwipeClose = {
        GestureRange:new{
            ges = "swipe",
            range = function() return self.dimen end,
        }
    }
    UIManager:setDirty(self, function()
        return self.refresh_type or "ui", self.dimen
    end)
end

function DashboardView:onTapClose()
    return self:onClose()
end

function DashboardView:onSwipeClose()
    return self:onClose()
end

function DashboardView:onClose()
    if self.on_close then
        self.on_close()
    end
    UIManager:close(self)
    return true
end

DashboardView.onAnyKeyPressed = DashboardView.onClose

local AiQuota = WidgetContainer:extend{
    name = "ai_quota_dashboard",
    is_doc_only = false,
    endpoint = "https://liyu900810-dot.github.io/kindle-ai-quota-dashboard/data.json",
    dashboard_message = nil,
    refresh_task = nil,
    rotation_mode_backup = nil,
    rebuilding = false,
    request_sequence = 0,
    refresh_count = 0,
    last_good_data = nil,
    last_signature = nil,
    last_render_at = 0,
    etag = nil,
    last_modified = nil,
}

function AiQuota:onDispatcherRegisterActions()
    Dispatcher:registerAction("ai_quota_refresh", {
        category = "none",
        event = "AIQuotaRefresh",
        title = _("Refresh AI quota"),
        general = true,
    })
end

function AiQuota:init()
    self.last_good_data = load_cache()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function AiQuota:addToMainMenu(menu_items)
    menu_items.ai_quota_dashboard = {
        text = _("AI quota dashboard"),
        sorting_hint = "more_tools",
        callback = function() self:openDashboard() end,
    }
end

function AiQuota:onAIQuotaRefresh()
    if self.dashboard_message then
        self:refresh(false)
    else
        self:openDashboard()
    end
end

function AiQuota:stopAutoRefresh()
    if self.refresh_task then
        UIManager:unschedule(self.refresh_task)
        self.refresh_task = nil
    end
end

function AiQuota:refreshInterval()
    local capacity = battery_capacity()
    if capacity and capacity <= 15 then
        return LOW_BATTERY_REFRESH_SECONDS
    end
    return REFRESH_SECONDS
end

function AiQuota:startAutoRefresh()
    self:stopAutoRefresh()
    self.refresh_task = function()
        self.refresh_task = nil
        if self.dashboard_message then
            self:refresh(true)
        end
    end
    UIManager:scheduleIn(self:refreshInterval(), self.refresh_task)
end

function AiQuota:enterLandscape()
    local current_mode = Screen:getRotationMode()
    if current_mode % 2 == 0 then
        self.rotation_mode_backup = current_mode
        Screen:setRotationMode(Screen.DEVICE_ROTATED_CLOCKWISE)
        UIManager:onRotation()
    end
end

function AiQuota:restoreRotation()
    if self.rotation_mode_backup ~= nil
            and Screen:getRotationMode() ~= self.rotation_mode_backup then
        Screen:setRotationMode(self.rotation_mode_backup)
        UIManager:onRotation()
    end
    self.rotation_mode_backup = nil
end

function AiQuota:dataSignature(data, state)
    return table.concat({
        text_value(data and data.updatedAt, ""),
        text_value(state and state.mode, ""),
        text_value(state and state.message, ""),
    }, "|")
end

function AiQuota:showDashboard(data, view_state, force)
    data = data or {}
    view_state = view_state or { mode = "online" }
    local signature = self:dataSignature(data, view_state)
    if not force and self.dashboard_message and signature == self.last_signature
            and os.time() - self.last_render_at < 900 then
        self:startAutoRefresh()
        return
    end

    if self.dashboard_message then
        self.rebuilding = true
        UIManager:close(self.dashboard_message)
        self.dashboard_message = nil
        self.rebuilding = false
    end
    self:enterLandscape()
    self.refresh_count = self.refresh_count + 1
    local refresh_type = self.refresh_count % 4 == 0 and "full" or "ui"
    local message
    message = DashboardView:new{
        data = data,
        view_state = view_state,
        refresh_type = refresh_type,
        on_close = function()
            if self.dashboard_message == message then
                self.dashboard_message = nil
                self:stopAutoRefresh()
            end
            if not self.rebuilding then
                self.request_sequence = self.request_sequence + 1
                self:restoreRotation()
            end
        end,
    }
    self.dashboard_message = message
    self.last_signature = signature
    self.last_render_at = os.time()
    UIManager:show(message)
    self:startAutoRefresh()
end

function AiQuota:showCachedError(message)
    if self.last_good_data then
        self:showDashboard(self.last_good_data, {
            mode = "error",
            message = message,
            last_success_at = self.last_good_data.updatedAt,
        })
    else
        self:showDashboard({
            updatedAt = nil,
            sources = { codex = { ok = false, error = message } },
            weather = { ok = false, place = "扬州" },
        }, {
            mode = "error",
            message = message,
        })
    end
end

function AiQuota:openDashboard()
    if self.last_good_data then
        self:showDashboard(self.last_good_data, {
            mode = "cached",
            last_success_at = self.last_good_data.updatedAt,
        }, true)
    else
        self:showDashboard({
            sources = { codex = { ok = false } },
            weather = { ok = false, place = "扬州" },
        }, {
            mode = "loading",
        }, true)
    end
    self:refresh(false)
end

function AiQuota:fetchAndShow(request_id)
    local body = {}
    local request_headers = {
        ["accept"] = "application/json",
        ["cache-control"] = "no-cache",
    }
    if self.etag then
        request_headers["if-none-match"] = self.etag
    end
    if self.last_modified then
        request_headers["if-modified-since"] = self.last_modified
    end

    socketutil:set_timeout(REQUEST_BLOCK_TIMEOUT, REQUEST_TOTAL_TIMEOUT)
    local request_ok, ok, code, headers = pcall(http.request, {
        url = self.endpoint,
        method = "GET",
        headers = request_headers,
        sink = capped_sink(body),
    })
    socketutil:reset_timeout()

    if request_id ~= self.request_sequence or not self.dashboard_message then
        return
    end
    if not request_ok then
        self:showCachedError("网络请求异常")
        return
    end
    if tonumber(code) == 304 and self.last_good_data then
        self:showDashboard(self.last_good_data, {
            mode = "online",
            last_success_at = self.last_good_data.updatedAt,
        })
        return
    end
    if not ok or tonumber(code) ~= 200 then
        self:showCachedError("网络请求失败：HTTP " .. text_value(code, "error"))
        return
    end

    local decoded, data = pcall(json.decode, table.concat(body))
    if not decoded or type(data) ~= "table" then
        self:showCachedError("收到的数据无法读取")
        return
    end
    if type(data.sources) ~= "table" or type(data.sources.codex) ~= "table" then
        self:showCachedError("数据格式不完整")
        return
    end

    if type(headers) == "table" then
        self.etag = headers.etag or headers.ETag
        self.last_modified = headers["last-modified"] or headers["Last-Modified"]
    end
    self.last_good_data = data
    save_cache(data)
    self:showDashboard(data, {
        mode = "online",
        last_success_at = data.updatedAt,
    })
end

function AiQuota:refresh(is_automatic)
    if is_automatic then
        local ok, connected = pcall(function() return NetworkMgr:isConnected() end)
        if not ok or not connected then
            self:showCachedError("Wi-Fi 未联网")
            self:startAutoRefresh()
            return
        end
    end

    self.request_sequence = self.request_sequence + 1
    local request_id = self.request_sequence
    NetworkMgr:runWhenOnline(function()
        if request_id ~= self.request_sequence or not self.dashboard_message then
            return
        end
        Trapper:wrap(function() self:fetchAndShow(request_id) end)
    end)
end

return AiQuota
