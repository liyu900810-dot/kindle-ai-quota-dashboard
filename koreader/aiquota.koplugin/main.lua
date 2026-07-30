-- AI Quota Dashboard for KOReader
-- KPW1 landscape layout: 1024 x 758, monochrome e-ink friendly.

local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local NetworkMgr = require("ui/network/manager")
local ProgressWidget = require("ui/widget/progresswidget")
local Screen = require("device").screen
local TextWidget = require("ui/widget/textwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local json = require("json")
local ltn12 = require("ltn12")
local _ = require("gettext")

local REFRESH_SECONDS = 180
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
        return text
    end
    if short_date then
        return date:sub(6) .. " " .. time
    end
    return date .. " " .. time
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
        face = Font:getFace("cfont", S(size)),
        max_width = max_width,
        padding = 0,
        bold = bold == true,
    }
end

-- KOReader containers use the child natural size. Add explicit spans so
-- every card keeps its intended KPW1 size instead of collapsing vertically.
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

local function metric(label, value, width)
    return VerticalGroup:new{
        text_widget(label, 11, width, false),
        spacer(S(2)),
        text_widget(value, 14, width, true),
    }
end

local function quota_label(window)
    local name = text_value(window.name, "周")
    if name:find("周") then
        return "周"
    end
    if name:find("月") then
        return "月"
    end
    return name
end

local function quota_card(window, width, height)
    local inner_width = width - S(28)
    local used = number_or_nil(window.usedPct)
    local used_text = used and string.format("%d%% used", math.floor(used + 0.5)) or "-- used"
    local provider_width = S(105)
    local value_width = S(175)
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
        text_widget("QUOTA", 13, inner_width - provider_width, true),
        HorizontalSpan:new{ width = inner_width - provider_width - S(5) },
        text_widget("Codex", 13, provider_width, true),
    }
    local value_row = HorizontalGroup:new{
        text_widget(quota_label(window), 14, inner_width - value_width - S(5), true),
        HorizontalSpan:new{ width = inner_width - value_width - S(5) },
        text_widget(used_text, 27, value_width, true),
    }
    return card({
        top_row,
        spacer(S(13)),
        value_row,
        spacer(S(10)),
        bar,
        spacer(S(8)),
        text_widget("Reset: " .. compact_timestamp(window.resetAt, true), 12, inner_width, false),
    }, width, height)
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
    local sources = data.sources or {}
    local codex = sources.codex or {}
    local weather = data.weather or {}
    local solar_date, lunar_date = calendar_text(data)

    -- Fixed KPW1 landscape geometry. The same proportions remain usable in
    -- portrait mode if KOReader restores the original rotation unexpectedly.
    local header_height = is_landscape and S(62) or S(78)
    local status_height = is_landscape and S(34) or S(38)
    local top_height = is_landscape and S(166) or S(182)
    local quota_height = is_landscape and S(166) or S(184)
    local footer_height = S(31)

    local header_right_width = math.floor(content_width * 0.36)
    local title_width = content_width - header_right_width - S(18)
    local header = is_landscape and fixed_content({
        HorizontalGroup:new{
            text_widget("KINDLE AI QUOTA DASHBOARD", 19, title_width, true),
            HorizontalSpan:new{ width = S(18) },
            VerticalGroup:new{
                text_widget(os.date("%H:%M"), 22, header_right_width, true),
                spacer(S(2)),
                text_widget(solar_date, 11, header_right_width, true),
                spacer(S(1)),
                text_widget(lunar_date, 11, header_right_width, true),
            },
        },
        content_width,
        header_height
    ) or fixed_content({
        text_widget("KINDLE AI QUOTA DASHBOARD", 18, content_width, true),
        spacer(S(3)),
        text_widget(os.date("%H:%M  ") .. solar_date, 13, content_width, true),
        spacer(S(1)),
        text_widget(lunar_date, 11, content_width, true),
    }, content_width, header_height)

    local updated_time = compact_timestamp(data.updatedAt, true)
    local status_text
    if codex.ok == true or weather.ok == true then
        status_text = "数据已同步 · 最后更新 " .. updated_time
    else
        status_text = "电脑或数据链路已离线 · 最后在线 " .. os.date("%H:%M")
    end
    local status = card({
        text_widget(status_text, 11, content_width - S(22), true),
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
    local icon = weather.ok == true and "☼" or "○"
    local weather_title = HorizontalGroup:new{
        text_widget(icon, 24, S(34), false),
        HorizontalSpan:new{ width = S(8) },
        text_widget(weather_place .. "  " .. weather_description, 16, inner_weather - S(42), true),
    }
    local weather_metrics_1 = HorizontalGroup:new{
        metric("温度", weather_temp, math.floor((inner_weather - S(12)) / 2)),
        HorizontalSpan:new{ width = S(12) },
        metric("体感", weather_feels, math.floor((inner_weather - S(12)) / 2)),
    }
    local weather_metrics_2 = HorizontalGroup:new{
        metric("湿度", weather_humidity, math.floor((inner_weather - S(12)) / 2)),
        HorizontalSpan:new{ width = S(12) },
        metric("风速", weather_wind, math.floor((inner_weather - S(12)) / 2)),
    }
    local now_card = card({
        text_widget("NOW", 13, inner_now, true),
        spacer(S(14)),
        text_widget(os.date("%H:%M"), 37, inner_now, true),
        spacer(S(3)),
        text_widget(solar_date, 12, inner_now, true),
        spacer(S(2)),
        text_widget(lunar_date, 12, inner_now, true),
    }, now_width, top_height)
    local weather_card = card({
        text_widget("WEATHER", 13, inner_weather, true),
        spacer(S(6)),
        weather_title,
        spacer(S(6)),
        weather_metrics_1,
        spacer(S(5)),
        weather_metrics_2,
    }, weather_width, top_height)
    local top_row = HorizontalGroup:new{
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
    local quota = quota_window and quota_card(quota_window, content_width, quota_height) or card({
        text_widget("QUOTA", 13, content_width - S(28), true),
        spacer(S(14)),
        text_widget("暂时无法取得额度数据", 17, content_width - S(28), true),
    }, content_width, quota_height)

    local footer = fixed_content({
        text_widget("更新: " .. compact_timestamp(data.updatedAt, false), 11, content_width, false),
        spacer(S(3)),
        text_widget("每 3 分钟自动刷新 · 点击屏幕关闭", 11, content_width, false),
    }, content_width, footer_height)

    local children = { header, spacer(gap), status, spacer(gap), top_row, spacer(gap), quota }
    local fixed_height = header_height + status_height + top_height + quota_height + footer_height + gap * 4
    local available_height = screen_height - 2 * outer
    local bottom_fill = available_height - fixed_height
    if bottom_fill > 0 then
        table.insert(children, spacer(bottom_fill))
    else
        table.insert(children, spacer(gap))
    end
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
    UIManager:setDirty(self, function() return "ui", self.dimen end)
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
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function AiQuota:addToMainMenu(menu_items)
    menu_items.ai_quota_dashboard = {
        text = _("AI quota dashboard"),
        sorting_hint = "more_tools",
        callback = function() self:refresh() end,
    }
end

function AiQuota:onAIQuotaRefresh()
    self:refresh()
end

function AiQuota:stopAutoRefresh()
    if self.refresh_task then
        UIManager:unschedule(self.refresh_task)
        self.refresh_task = nil
    end
end

function AiQuota:startAutoRefresh()
    self:stopAutoRefresh()
    self.refresh_task = function()
        self.refresh_task = nil
        if self.dashboard_message then
            self:refresh()
        end
    end
    UIManager:scheduleIn(REFRESH_SECONDS, self.refresh_task)
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

function AiQuota:showDashboard(data)
    if self.dashboard_message then
        self.rebuilding = true
        UIManager:close(self.dashboard_message)
        self.dashboard_message = nil
        self.rebuilding = false
    end
    self:enterLandscape()
    local message = DashboardView:new{
        data = data,
        on_close = function()
            if self.dashboard_message == message then
                self.dashboard_message = nil
                self:stopAutoRefresh()
            end
            if not self.rebuilding then
                self:restoreRotation()
            end
        end,
    }
    self.dashboard_message = message
    UIManager:show(message)
    self:startAutoRefresh()
end

function AiQuota:showError(message)
    self:showDashboard{
        updatedAt = os.date("%Y-%m-%d %H:%M:%S"),
        sources = { codex = { ok = false } },
        weather = { ok = false, place = "扬州" },
        quote = { text = message },
    }
end

function AiQuota:fetchAndShow()
    local body = {}
    local url = self.endpoint .. "?t=" .. tostring(os.time())
    local ok, code = http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(body),
    }
    if not ok or tonumber(code) ~= 200 then
        self:showError("网络请求失败：HTTP " .. text_value(code, "error"))
        return
    end

    local decoded, data = pcall(json.decode, table.concat(body))
    if not decoded or type(data) ~= "table" then
        self:showError("收到的数据无法读取")
        return
    end
    self:showDashboard(data)
end

function AiQuota:refresh()
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function() self:fetchAndShow() end)
    end)
end

return AiQuota
