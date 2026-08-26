-- AI Quota Dashboard for KOReader
-- Version 7.7: show the Codex five-hour and weekly quotas side by side.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local logger = require("logger")
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

local REFRESH_SECONDS = 60
local LOW_BATTERY_REFRESH_SECONDS = 300
local ONLINE_RETRY_SECONDS = 5
local ONLINE_RETRY_ATTEMPTS = 12
local CLOSE_GUARD_SECONDS = 3
local REQUEST_BLOCK_TIMEOUT = 8
local REQUEST_TOTAL_TIMEOUT = 15
local MAX_RESPONSE_BYTES = 256 * 1024
local DATA_SCHEMA_VERSION = 3
local CACHE_FILE = DataStorage:getDataDir() .. "/aiquota-dashboard-cache.json"
local HEALTH_FILE = DataStorage:getDataDir() .. "/aiquota-health.json"
local MEMORY_CHECK_EVERY_REFRESHES = 5
local MEMORY_THRESHOLD_MB = 100
local MEMORY_HIGH_SAMPLES = 2
local MEMORY_RESTART_COOLDOWN_SECONDS = 6 * 60 * 60
local REOPEN_MAX_AGE_SECONDS = 10 * 60
local REOPEN_DELAY_SECONDS = 5
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

local function rounded_text(value)
    local number = tonumber(value)
    if not number then
        return "--"
    end
    if number >= 0 then
        return tostring(math.floor(number + 0.5))
    end
    return tostring(math.ceil(number - 0.5))
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

function WeatherIcon:paintMoon(bb, x, y)
    local cx = x + math.floor(self.width * 0.46)
    local cy = y + math.floor(self.height * 0.50)
    local radius = math.max(3, math.floor(math.min(self.width, self.height) * 0.34))
    bb:paintCircle(cx, cy, radius, Blitbuffer.COLOR_BLACK)
    bb:paintCircle(
        cx + math.max(2, math.floor(radius * 0.48)),
        cy - math.max(1, math.floor(radius * 0.18)),
        math.max(2, math.floor(radius * 0.82)),
        Blitbuffer.COLOR_WHITE
    )
end

function WeatherIcon:paintUnknown(bb, x, y)
    local cx = x + math.floor(self.width / 2)
    local cy = y + math.floor(self.height / 2)
    local radius = math.max(3, math.floor(math.min(self.width, self.height) * 0.34))
    local line = math.max(1, math.floor(self.width * 0.07))
    bb:paintCircle(cx, cy, radius, Blitbuffer.COLOR_BLACK, line)
    bb:paintRect(
        cx - math.floor(line / 2),
        cy - math.floor(radius * 0.52),
        line,
        math.max(2, math.floor(radius * 0.60)),
        Blitbuffer.COLOR_BLACK
    )
    bb:paintRect(cx - math.floor(line / 2), cy + math.floor(radius * 0.42), line, line,
        Blitbuffer.COLOR_BLACK)
end

function WeatherIcon:paintCloud(bb, x, y)
    local base_y = y + math.floor(self.height * 0.58)
    local line = math.max(1, math.floor(self.width * 0.06))
    local small_radius = math.max(2, math.floor(self.width * 0.17))
    local large_radius = math.max(3, math.floor(self.width * 0.23))
    bb:paintCircle(
        x + math.floor(self.width * 0.29),
        base_y,
        small_radius,
        Blitbuffer.COLOR_BLACK,
        line
    )
    bb:paintCircle(
        x + math.floor(self.width * 0.50),
        base_y - math.floor(self.height * 0.12),
        large_radius,
        Blitbuffer.COLOR_BLACK,
        line
    )
    bb:paintCircle(
        x + math.floor(self.width * 0.72),
        base_y,
        small_radius,
        Blitbuffer.COLOR_BLACK,
        line
    )
    bb:paintRect(
        x + math.floor(self.width * 0.20),
        base_y + small_radius - line,
        math.floor(self.width * 0.62),
        line,
        Blitbuffer.COLOR_BLACK
    )
end

function WeatherIcon:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    if self.kind == "sun" then
        self:paintSun(bb, x, y)
        return
    elseif self.kind == "moon" then
        self:paintMoon(bb, x, y)
        return
    elseif self.kind == "unknown" then
        self:paintUnknown(bb, x, y)
        return
    end
    self:paintCloud(bb, x, y)
    if self.kind == "rain" then
        local rain_y = y + math.floor(self.height * 0.76)
        for i = 0, 2 do
            bb:paintRect(
                x + math.floor(self.width * (0.28 + i * 0.22)),
                rain_y,
                math.max(1, math.floor(self.width * 0.05)),
                math.max(2, math.floor(self.height * 0.18)),
                Blitbuffer.COLOR_BLACK
            )
        end
    elseif self.kind == "snow" then
        local snow_y = y + math.floor(self.height * 0.82)
        for i = 0, 2 do
            local snow_x = x + math.floor(self.width * (0.28 + i * 0.22))
            local arm = math.max(2, math.floor(self.width * 0.12))
            bb:paintRect(snow_x - arm, snow_y, arm * 2 + 1, 1, Blitbuffer.COLOR_BLACK)
            bb:paintRect(snow_x, snow_y - arm, 1, arm * 2 + 1, Blitbuffer.COLOR_BLACK)
        end
    end
end

local CodexIcon = Widget:extend{
    width = S(22),
    height = S(22),
}

function CodexIcon:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function CodexIcon:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local cx = x + math.floor(self.width / 2)
    local cy = y + math.floor(self.height / 2)
    local orbit = S(5)
    local radius = S(4)
    local line = math.max(1, S(2))
    local points = {
        { 0, -orbit },
        { orbit, -math.floor(orbit / 2) },
        { orbit, math.floor(orbit / 2) },
        { 0, orbit },
        { -orbit, math.floor(orbit / 2) },
        { -orbit, -math.floor(orbit / 2) },
    }
    for _, point in ipairs(points) do
        bb:paintCircle(cx + point[1], cy + point[2], radius, Blitbuffer.COLOR_BLACK, line)
    end
end

local TodoBox = Widget:extend{
    width = S(16),
    height = S(16),
}

function TodoBox:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function TodoBox:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local line = math.max(1, S(2))
    bb:paintRect(x, y, self.width, line, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + self.height - line, self.width, line, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, line, self.height, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + self.width - line, y, line, self.height, Blitbuffer.COLOR_BLACK)
end

local ForecastDivider = Widget:extend{
    width = S(1),
    height = S(49),
}

function ForecastDivider:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function ForecastDivider:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_BLACK)
end

local function weather_kind(weather)
    local key = string.lower(text_value(weather.iconKey, ""))
    local description = string.lower(text_value(weather.description, ""))
    local combined = key .. " " .. description
    if combined:find("unknown", 1, true) or combined:find("未知", 1, true) then
        return "unknown"
    elseif combined:find("clear-night", 1, true) then
        return "moon"
    elseif combined:find("thunder", 1, true) or combined:find("雷", 1, true) then
        return "rain"
    elseif combined:find("snow", 1, true) or combined:find("雪", 1, true) then
        return "snow"
    elseif combined:find("rain", 1, true) or combined:find("shower", 1, true)
            or combined:find("雨", 1, true) then
        return "rain"
    elseif combined:find("fog", 1, true) or combined:find("mist", 1, true)
            or combined:find("雾", 1, true) then
        return "cloud"
    elseif combined:find("cloud", 1, true) or combined:find("overcast", 1, true)
            or combined:find("阴", 1, true) or combined:find("云", 1, true) then
        return "cloud"
    end
    return "sun"
end

local function forecast_time(value)
    local date, time = text_value(value, ""):match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
    if not time then
        return "--:--"
    end
    local today = os.date("%Y-%m-%d")
    local tomorrow = os.date("%Y-%m-%d", os.time() + 24 * 60 * 60)
    if date == tomorrow then
        return "明" .. time:sub(1, 2)
    elseif date ~= today then
        return date:sub(6) .. " " .. time:sub(1, 2)
    end
    return time
end

local function forecast_cell(item, width, height)
    local inner_width = width
    local inner_height = height
    local rain = tonumber(item and item.precipitationProbability)
    local bottom_text = rounded_text(item and item.tempC) .. "C"
    if rain and rain >= 10 then
        bottom_text = bottom_text .. " " .. rounded_text(rain) .. "%"
    end
    local content = VerticalGroup:new{
        align = "center",
        text_widget(forecast_time(item and item.time), 9, inner_width, true),
        spacer(S(1)),
        WeatherIcon:new{
            kind = weather_kind(item or {}),
            width = S(18),
            height = S(18),
        },
        spacer(S(1)),
        text_widget(bottom_text, 9, inner_width, true),
    }
    return CenterContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = inner_width, h = inner_height },
        content,
    }
end

local function hourly_forecast_strip(forecast, width, height)
    local values = type(forecast) == "table" and forecast or {}
    if #values == 0 then
        return left_cell(
            text_widget("未来 12 小时分时预报暂不可用", 10, width, false),
            width,
            height
        )
    end
    local border = S(1)
    local inner_width = width - border * 2
    local inner_height = height - border * 2
    local divider_width = S(1)
    local cells_width = inner_width - divider_width * 5
    local children = { allow_mirroring = false }
    local base_width = math.floor(cells_width / 6)
    local used_width = 0
    for index = 1, 6 do
        local cell_width = index == 6 and (cells_width - used_width) or base_width
        table.insert(children, forecast_cell(values[index] or {}, cell_width, inner_height))
        used_width = used_width + cell_width
        if index < 6 then
            table.insert(children, ForecastDivider:new{
                width = divider_width,
                height = inner_height,
            })
        end
    end
    return FrameContainer:new{
        width = width,
        height = height,
        padding = 0,
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new(children),
    }
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

local function network_online()
    local ok_online, online = pcall(function() return NetworkMgr:isOnline() end)
    if ok_online then
        return online == true
    end
    local ok_connected, connected = pcall(function() return NetworkMgr:isConnected() end)
    return ok_connected and connected == true
end

local function device_status()
    local capacity = battery_capacity()
    local battery = capacity and ("电量 " .. capacity .. "%") or "电量 --"
    local wifi = "Wi-Fi 关闭"
    local ok_on, is_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if ok_on and is_on then
        local ok_connected, connected = pcall(function() return NetworkMgr:isConnected() end)
        if network_online() then
            wifi = "Wi-Fi 在线"
        elseif ok_connected and connected then
            wifi = "Wi-Fi 已连接·无网络"
        else
            wifi = "Wi-Fi 未联网"
        end
    end
    return battery .. " · " .. wifi
end

local function refresh_minutes(seconds)
    local value = tonumber(seconds) or REFRESH_SECONDS
    return math.max(1, math.floor(value / 60 + 0.5))
end

local function seconds_until_next_minute()
    local second = tonumber(os.date("%S")) or 0
    -- Run just after the minute boundary to avoid rendering the previous minute.
    return math.max(1, 61 - second)
end

local function timestamp_time(value)
    return text_value(value, ""):match("[T ](%d%d:%d%d)") or "--:--"
end

local function quota_window_panel(window, width, height)
    local used = number_or_nil(window.usedPct)
    local used_text = used and string.format("%d%% used", math.floor(used + 0.5)) or "-- used"
    local value_width = math.floor(width * 0.58)
    local row_height = S(29)
    local bar = ProgressWidget:new{
        width = width,
        height = S(12),
        percentage = used and used / 100 or 0,
        bordersize = S(2),
        margin_h = S(2),
        margin_v = S(1),
        radius = 0,
        bordercolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_WHITE,
        fillcolor = Blitbuffer.COLOR_BLACK,
    }
    local value_row = HorizontalGroup:new{
        allow_mirroring = false,
        left_cell(
            text_widget(quota_label(window), 15, width - value_width, true),
            width - value_width,
            row_height
        ),
        right_cell(text_widget(used_text, 23, value_width, true), value_width, row_height),
    }
    return fixed_content({
        value_row,
        spacer(S(3)),
        bar,
        spacer(S(4)),
        text_widget("Reset: " .. compact_timestamp(window.resetAt, true), 10, width, false),
    }, width, height)
end

local function select_quota_windows(windows)
    local short_window
    local weekly_window
    for _, window in ipairs(type(windows) == "table" and windows or {}) do
        local name = text_value(window.name, "")
        local label = quota_label(window)
        if not short_window and (name:find("5", 1, true)
                or name:find("小时", 1, true)) then
            short_window = window
        elseif not weekly_window and (label == "周"
                or name:find("7天", 1, true)) then
            weekly_window = window
        end
    end
    if not short_window then
        short_window = windows and windows[1] or nil
    end
    if not weekly_window then
        for _, window in ipairs(type(windows) == "table" and windows or {}) do
            if window ~= short_window then
                weekly_window = window
                break
            end
        end
    end
    if weekly_window == short_window then
        weekly_window = nil
    end
    return short_window, weekly_window
end


local function quota_card(windows, width, height)
    local inner_width = width - S(28)
    local provider_width = S(104)
    local right_inset = S(8)
    local provider = HorizontalGroup:new{
        allow_mirroring = false,
        CodexIcon:new{},
        HorizontalSpan:new{ width = S(2) },
        text_widget("Codex", 13, S(64), true),
    }
    local top_row = HorizontalGroup:new{
        allow_mirroring = false,
        left_cell(
            text_widget("QUOTA", 13, inner_width - provider_width - right_inset, true),
            inner_width - provider_width - right_inset,
            S(22)
        ),
        right_cell(provider, provider_width, S(22)),
        HorizontalSpan:new{ width = right_inset },
    }
    local short_window, weekly_window = select_quota_windows(windows)
    local panels
    if weekly_window then
        local divider_width = S(2)
        local panel_gap = S(12)
        local panels_width = inner_width - divider_width - panel_gap * 2
        local left_width = math.floor(panels_width / 2)
        local right_width = panels_width - left_width
        local panel_height = S(62)
        panels = HorizontalGroup:new{
            allow_mirroring = false,
            quota_window_panel(short_window, left_width, panel_height),
            HorizontalSpan:new{ width = panel_gap },
            ForecastDivider:new{ width = divider_width, height = panel_height },
            HorizontalSpan:new{ width = panel_gap },
            quota_window_panel(weekly_window, right_width, panel_height),
        }
    else
        panels = quota_window_panel(short_window, inner_width, S(62))
    end
    return card({
        top_row,
        spacer(S(4)),
        panels,
    }, width, height)
end

local function todo_card(todo, width, height)
    local inner_width = width - S(28)
    local items = type(todo) == "table" and type(todo.items) == "table" and todo.items or {}
    local total = tonumber(todo and todo.totalOpen) or #items
    local displayed_count = math.min(3, #items)
    local count_text = total > displayed_count
        and string.format("%d / %d 项", displayed_count, total)
        or string.format("%d 项", total)
    local count_width = S(96)
    local header = HorizontalGroup:new{
        allow_mirroring = false,
        left_cell(text_widget("TO DO", 13, inner_width - count_width, true),
            inner_width - count_width, S(22)),
        right_cell(text_widget(count_text, 13, count_width, true),
            count_width, S(22)),
    }
    local children = { header, spacer(S(7)) }
    local row_height = S(39)
    local box_width = S(20)
    local row_gap = S(10)
    local due_width = S(88)
    local title_width = inner_width - box_width - row_gap - due_width

    if #items == 0 then
        table.insert(children, spacer(S(10)))
        table.insert(children, text_widget("暂无待办 · 可在 Notion 中添加", 14, inner_width, true))
    else
        for index = 1, displayed_count do
            local item = items[index] or {}
            local title = text_value(item.title, "未命名事项")
            if text_value(item.priority, "") == "高" then
                title = "! " .. title
            end
            table.insert(children, HorizontalGroup:new{
                allow_mirroring = false,
                left_cell(TodoBox:new{}, box_width, row_height),
                HorizontalSpan:new{ width = row_gap },
                left_cell(text_widget(title, 16, title_width, index == 1),
                    title_width, row_height),
                right_cell(text_widget(text_value(item.dueLabel, ""), 13, due_width, true),
                    due_width, row_height),
            })
        end
    end
    return card(children, width, height)
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

local function default_health_state()
    return {
        last_restart_at = 0,
        reopen_pending = false,
        restart_requested_at = 0,
    }
end

local function load_health_state()
    local state = default_health_state()
    local file = io.open(HEALTH_FILE, "r")
    if not file then
        return state
    end
    local body = file:read("*a")
    file:close()
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= "table" then
        return state
    end
    state.last_restart_at = tonumber(decoded.last_restart_at) or 0
    state.reopen_pending = decoded.reopen_pending == true
    state.restart_requested_at = tonumber(decoded.restart_requested_at) or 0
    return state
end

local function save_health_state(state)
    local ok, encoded = pcall(json.encode, state)
    if not ok or type(encoded) ~= "string" then
        return false
    end
    return util.writeToFile(encoded, HEALTH_FILE, true)
end

local function current_rss_mb()
    local statm = io.open("/proc/self/statm", "r")
    if not statm then
        return nil
    end
    local _, rss_pages = statm:read("*number", "*number")
    statm:close()
    if not rss_pages then
        return nil
    end
    return math.floor(rss_pages * (4096 / 1024 / 1024))
end

local function validate_dashboard_data(data)
    if type(data) ~= "table" or tonumber(data.schemaVersion) ~= DATA_SCHEMA_VERSION then
        return false, "数据版本不兼容"
    end
    if type(data.updatedAt) ~= "string"
            or type(data.sources) ~= "table"
            or type(data.sources.codex) ~= "table" then
        return false, "额度数据格式不完整"
    end
    if type(data.weather) ~= "table" or type(data.weather.ok) ~= "boolean" then
        return false, "天气数据格式不完整"
    end
    if data.weather.ok then
        if type(data.weather.forecast) ~= "table" or #data.weather.forecast > 6 then
            return false, "分时预报格式不完整"
        end
        for _, item in ipairs(data.weather.forecast) do
            if type(item) ~= "table"
                    or type(item.time) ~= "string"
                    or (item.tempC ~= nil and tonumber(item.tempC) == nil)
                    or type(item.iconKey) ~= "string" then
                return false, "分时预报内容不可用"
            end
        end
    end
    if type(data.todo) ~= "table" or type(data.todo.items) ~= "table" then
        return false, "待办数据格式不完整"
    end
    return true
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
    local outer = is_landscape and S(14) or S(18)
    local gap = is_landscape and S(8) or S(12)
    local content_width = screen_width - 2 * outer
    local data = self.data or {}
    local state = self.view_state or {}
    local sources = data.sources or {}
    local codex = sources.codex or {}
    self.close_guard_until = os.time() + CLOSE_GUARD_SECONDS
    local weather = data.weather or {}
    local todo = data.todo or {}
    local solar_date, lunar_date = calendar_text(data)
    local refresh_min = refresh_minutes(state.refresh_seconds)

    local header_height = is_landscape and S(44) or S(68)
    local status_height = is_landscape and S(42) or S(48)
    local top_height = is_landscape and S(156) or S(182)
    local quota_height = is_landscape and S(132) or S(174)
    local todo_height = is_landscape and S(210) or S(205)

    local header_right_width = math.floor(content_width * 0.36)
    local title_width = content_width - header_right_width
    local right_header = VerticalGroup:new{
        align = "right",
        text_widget(device_status(), 11, header_right_width, true),
        spacer(S(3)),
        text_widget("自动刷新 · 每 " .. refresh_min .. " 分钟", 9, header_right_width, false),
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
        text_widget(device_status() .. " · 每 " .. refresh_min .. " 分钟刷新",
            10, content_width, false),
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
        status_text = "数据已同步 · " .. age_text(last_success)
            .. " · 下次检查 " .. refresh_min .. " 分钟"
    end
    local status = card({
        text_widget(status_text, 12, content_width - S(22), true),
    }, content_width, status_height, S(2))

    local card_gap = S(14)
    local now_width = math.floor((content_width - card_gap) * 0.30)
    local weather_width = content_width - card_gap - now_width
    local inner_now = now_width - S(28)
    local inner_weather = weather_width - S(28)
    local weather_place = text_value(weather.place, "扬州")
    local weather_description = text_value(weather.description, "--")
    local weather_temp = rounded_text(weather.tempC) .. " C"
    local weather_feels = rounded_text(weather.feelsLikeC) .. " C"
    local weather_humidity = rounded_text(weather.humidity) .. "%"
    local weather_wind = rounded_text(weather.windKph) .. " km/h"
    local weather_wind_dir = text_value(weather.windDir, "")
    if weather_wind_dir == "-" then
        weather_wind_dir = ""
    end
    local weather_source = "Open-Meteo"
    if weather.stale then
        weather_source = weather_source .. " · 缓存 " .. timestamp_time(weather.fetchedAt)
    end
    local source_width = S(150)
    local weather_header = HorizontalGroup:new{
        allow_mirroring = false,
        left_cell(
            text_widget("WEATHER", 13, inner_weather - source_width, true),
            inner_weather - source_width,
            S(20)
        ),
        right_cell(
            text_widget(weather_source, 8, source_width, weather.stale == true),
            source_width,
            S(20)
        ),
    }
    local weather_body_height = S(104)
    local weather_body_gap = S(12)
    local current_weather_width = math.floor(inner_weather * 0.34)
    local forecast_width = inner_weather - current_weather_width
        - weather_body_gap
    local weather_title = HorizontalGroup:new{
        allow_mirroring = false,
        left_cell(
            WeatherIcon:new{
                kind = weather_kind(weather),
                width = S(38),
                height = S(38),
            },
            S(44),
            S(40)
        ),
        left_cell(
            text_widget(weather_place .. "  " .. weather_description,
                17, current_weather_width - S(44), true),
            current_weather_width - S(44),
            S(40)
        ),
    }
    local temperature_width = math.floor(current_weather_width * 0.42)
    local weather_temperature = HorizontalGroup:new{
        allow_mirroring = false,
        left_cell(
            text_widget(weather_temp, 24, temperature_width, true),
            temperature_width,
            S(34)
        ),
        left_cell(
            text_widget("体感 " .. weather_feels, 12,
                current_weather_width - temperature_width, true),
            current_weather_width - temperature_width,
            S(34)
        ),
    }
    local current_weather = fixed_content({
        weather_title,
        spacer(S(2)),
        weather_temperature,
        text_widget(
            "湿度 " .. weather_humidity .. " · "
                .. weather_wind_dir .. " " .. weather_wind,
            11,
            current_weather_width,
            true
        ),
    }, current_weather_width, weather_body_height)
    local forecast_strip = hourly_forecast_strip(
        weather.forecast,
        forecast_width,
        S(76)
    )
    local forecast_panel = fixed_content({
        text_widget("未来 12 小时 · 每 2 小时", 10, forecast_width, true),
        spacer(S(3)),
        forecast_strip,
    }, forecast_width, weather_body_height)
    local weather_body = HorizontalGroup:new{
        allow_mirroring = false,
        current_weather,
        HorizontalSpan:new{ width = weather_body_gap },
        forecast_panel,
    }
    self.clock_widget = text_widget(os.date("%H:%M"), 35, inner_now, true)
    self.clock_container = left_cell(
        self.clock_widget,
        inner_now,
        self.clock_widget:getSize().h
    )
    local now_card = card({
        text_widget("NOW", 13, inner_now, true),
        spacer(S(11)),
        self.clock_container,
        spacer(S(2)),
        text_widget(solar_date, 12, inner_now, true),
        text_widget(lunar_date, 12, inner_now, true),
    }, now_width, top_height)
    local weather_card = card({
        weather_header,
        spacer(S(4)),
        weather_body,
    }, weather_width, top_height)
    local top_row = HorizontalGroup:new{
        align = "top",
        allow_mirroring = false,
        now_card,
        HorizontalSpan:new{ width = card_gap },
        weather_card,
    }

    local quota
    if codex.ok and type(codex.windows) == "table" and #codex.windows > 0 then
        quota = quota_card(codex.windows, content_width, quota_height)
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

    local todo_panel = todo_card(todo, content_width, todo_height)
    local children = {
        header,
        spacer(gap),
        status,
        spacer(gap),
        top_row,
        spacer(gap),
        quota,
        spacer(gap),
        todo_panel,
    }
    local fixed_height = header_height + status_height + top_height + quota_height
        + todo_height + gap * 4
    local available_height = screen_height - 2 * outer
    local bottom_fill = available_height - fixed_height
    if bottom_fill > 0 then
        table.insert(children, spacer(bottom_fill))
    end

    self.dimen = Geom:new{ x = 0, y = 0, w = screen_width, h = screen_height }
    self[1] = FrameContainer:new{
        width = screen_width,
        height = screen_height,
        padding = outer,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left", unpack(children) },
    }

    self.ges_events.TapIgnore = {
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

function DashboardView:updateClock()
    local value = os.date("%H:%M")
    if not self.clock_widget or self.clock_widget.text == value then
        return
    end
    self.clock_widget:setText(value)
    UIManager:setDirty(self, "ui", self.clock_container.dimen)
end

function DashboardView:onTapIgnore()
    return true
end

function DashboardView:onSwipeClose()
    if os.time() < self.close_guard_until then
        logger.info("AIQuota: ignored swipe during close guard")
        return true
    end
    return self:onClose("swipe")
end

function DashboardView:onAnyKeyPressed()
    return true
end

function DashboardView:onClose(source)
    if self.on_close then
        self.on_close(source or "unknown")
    end
    UIManager:close(self)
    return true
end

local AiQuota = WidgetContainer:extend{
    name = "ai_quota_dashboard",
    is_doc_only = false,
    endpoint = "https://liyu900810-dot.github.io/kindle-ai-quota-dashboard/data.json",
    dashboard_message = nil,
    refresh_task = nil,
    clock_task = nil,
    online_retry_task = nil,
    reopen_task = nil,
    rotation_mode_backup = nil,
    request_sequence = 0,
    refresh_count = 0,
    last_good_data = nil,
    last_signature = nil,
    last_render_at = 0,
    etag = nil,
    last_modified = nil,
    health_state = nil,
    memory_check_count = 0,
    memory_high_samples = 0,
    memory_restart_pending = false,
    memory_cooldown_logged = false,
    last_error_message = nil,
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
    self.health_state = load_health_state()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.health_state.reopen_pending then
        local requested_at = self.health_state.restart_requested_at
        local age = math.abs(os.time() - requested_at)
        self.health_state.reopen_pending = false
        self.health_state.restart_requested_at = 0
        save_health_state(self.health_state)
        if requested_at > 0 and age <= REOPEN_MAX_AGE_SECONDS then
            self.reopen_task = function()
                self.reopen_task = nil
                if not self.dashboard_message then
                    logger.info("AIQuota: reopening dashboard after memory recovery")
                    self:openDashboard()
                end
            end
            UIManager:scheduleIn(REOPEN_DELAY_SECONDS, self.reopen_task)
        end
    end
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

function AiQuota:stopOnlineRetry()
    if self.online_retry_task then
        UIManager:unschedule(self.online_retry_task)
        self.online_retry_task = nil
    end
end

function AiQuota:scheduleOnlineRetry(request_id, attempt)
    self:stopOnlineRetry()
    if attempt > ONLINE_RETRY_ATTEMPTS then
        return
    end
    self.online_retry_task = function()
        self.online_retry_task = nil
        if request_id ~= self.request_sequence or not self.dashboard_message then
            return
        end
        if network_online() then
            self:stopOnlineRetry()
            Trapper:wrap(function() self:fetchAndShow(request_id) end)
            return
        end
        self:scheduleOnlineRetry(request_id, attempt + 1)
    end
    UIManager:scheduleIn(ONLINE_RETRY_SECONDS, self.online_retry_task)
end

function AiQuota:onNetworkConnected()
    if not self.dashboard_message then
        return
    end
    logger.info("AIQuota: network connected; scheduling dashboard refresh")
    self.request_sequence = self.request_sequence + 1
    local request_id = self.request_sequence
    self:scheduleOnlineRetry(request_id, 1)
end

function AiQuota:stopAutoRefresh()
    if self.refresh_task then
        UIManager:unschedule(self.refresh_task)
        self.refresh_task = nil
    end
    self:stopOnlineRetry()
end

function AiQuota:stopClockRefresh()
    if self.clock_task then
        UIManager:unschedule(self.clock_task)
        self.clock_task = nil
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

function AiQuota:startClockRefresh()
    self:stopClockRefresh()
    self.clock_task = function()
        self.clock_task = nil
        if self.dashboard_message then
            self.dashboard_message:updateClock()
            self:startClockRefresh()
        end
    end
    UIManager:scheduleIn(seconds_until_next_minute(), self.clock_task)
end

function AiQuota:checkMemoryGuard()
    self.memory_check_count = self.memory_check_count + 1
    if self.memory_check_count % MEMORY_CHECK_EVERY_REFRESHES ~= 0 then
        return false
    end
    local rss_mb = current_rss_mb()
    if not rss_mb then
        return false
    end
    if rss_mb < MEMORY_THRESHOLD_MB then
        self.memory_high_samples = 0
        self.memory_cooldown_logged = false
        return false
    end
    self.memory_high_samples = self.memory_high_samples + 1
    if self.memory_high_samples < MEMORY_HIGH_SAMPLES or self.memory_restart_pending then
        return false
    end

    local now = os.time()
    local last_restart_at = tonumber(self.health_state.last_restart_at) or 0
    if last_restart_at > 0 and now - last_restart_at < MEMORY_RESTART_COOLDOWN_SECONDS then
        if not self.memory_cooldown_logged then
            logger.warn("AIQuota: memory remains high during restart cooldown; rss_mb=" .. rss_mb)
            self.memory_cooldown_logged = true
        end
        self.memory_high_samples = 0
        return false
    end

    self.health_state.last_restart_at = now
    self.health_state.reopen_pending = true
    self.health_state.restart_requested_at = now
    if not save_health_state(self.health_state) then
        logger.err("AIQuota: unable to persist memory recovery state")
        self.memory_high_samples = 0
        return false
    end
    if self.last_good_data then
        save_cache(self.last_good_data)
    end
    self.memory_restart_pending = true
    logger.warn("AIQuota: restarting KOReader after sustained high memory; rss_mb=" .. rss_mb)
    UIManager:nextTick(function()
        self.ui:handleEvent(Event:new("Restart"))
    end)
    return true
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
        text_value(state and state.refresh_seconds, ""),
    }, "|")
end

function AiQuota:showDashboard(data, view_state, force)
    data = data or {}
    view_state = view_state or { mode = "online" }
    view_state.refresh_seconds = self:refreshInterval()
    local signature = self:dataSignature(data, view_state)
    if not force and self.dashboard_message and signature == self.last_signature
            and os.time() - self.last_render_at < 900 then
        self:startAutoRefresh()
        return
    end

    local previous_message = self.dashboard_message
    self:enterLandscape()
    self.refresh_count = self.refresh_count + 1
    local refresh_type = self.refresh_count % 4 == 0 and "full" or "ui"
    local message
    message = DashboardView:new{
        data = data,
        view_state = view_state,
        refresh_type = refresh_type,
        on_close = function(source)
            if self.dashboard_message ~= message then
                return
            end
            logger.info("AIQuota: dashboard view closed; source=" .. text_value(source, "unknown"))
            self.dashboard_message = nil
            self:stopAutoRefresh()
            self:stopClockRefresh()
            self.request_sequence = self.request_sequence + 1
            self:restoreRotation()
            UIManager:nextTick(function() collectgarbage("collect") end)
        end,
    }
    self.dashboard_message = message
    self.last_signature = signature
    self.last_render_at = os.time()
    UIManager:show(message)
    if previous_message then
        UIManager:close(previous_message)
        previous_message = nil
        collectgarbage("step", 200)
    else
        logger.info("AIQuota: dashboard view opened")
    end
    self:startAutoRefresh()
    self:startClockRefresh()
end

function AiQuota:showCachedError(message)
    if self.last_error_message ~= message then
        logger.warn("AIQuota: using cached data; reason=" .. text_value(message, "unknown"))
        self.last_error_message = message
    end
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
    local separator = string.find(self.endpoint, "?", 1, true) and "&" or "?"
    local request_url = self.endpoint .. separator .. "_=" .. tostring(os.time())
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
        url = request_url,
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
    local valid, validation_error = validate_dashboard_data(data)
    if not valid then
        self:showCachedError(validation_error)
        return
    end

    if type(headers) == "table" then
        self.etag = headers.etag or headers.ETag
        self.last_modified = headers["last-modified"] or headers["Last-Modified"]
    end
    self.last_good_data = data
    self.last_error_message = nil
    save_cache(data)
    self:showDashboard(data, {
        mode = "online",
        last_success_at = data.updatedAt,
    })
end

function AiQuota:refresh(is_automatic)
    self:stopOnlineRetry()
    if is_automatic and self:checkMemoryGuard() then
        return
    end
    if not network_online() then
        if is_automatic then
            self:showCachedError("Wi-Fi 未联网")
            self:startAutoRefresh()
            self.request_sequence = self.request_sequence + 1
            local request_id = self.request_sequence
            self:scheduleOnlineRetry(request_id, 1)
            return
        end
        self.request_sequence = self.request_sequence + 1
        local request_id = self.request_sequence
        self:scheduleOnlineRetry(request_id, 1)
        NetworkMgr:runWhenConnected(function()
            if request_id == self.request_sequence and self.dashboard_message then
                self:scheduleOnlineRetry(request_id, 1)
            end
        end)
        return
    end

    self.request_sequence = self.request_sequence + 1
    local request_id = self.request_sequence
    Trapper:wrap(function() self:fetchAndShow(request_id) end)
end

return AiQuota
