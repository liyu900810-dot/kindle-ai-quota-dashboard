-- AI Quota Dashboard for KOReader
-- Native card layout for jailbroken Kindle devices, including the original Paperwhite.

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

local function one_line(value, fallback)
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
    local text = one_line(value, "-")
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
        ["0"] = "星期日", ["1"] = "星期一", ["2"] = "星期二", ["3"] = "星期三",
        ["4"] = "星期四", ["5"] = "星期五", ["6"] = "星期六",
    }
    local solar = calendar.solar
    if not solar then
        solar = os.date("%Y年%m月%d日 ") .. one_line(weekdays[os.date("%w")], "")
    end
    return solar, one_line(calendar.lunar, "农历日期不可用")
end

local function text_widget(value, size, max_width, bold)
    return TextWidget:new{
        text = one_line(value),
        face = Font:getFace("cfont", S(size)),
        max_width = max_width,
        padding = 0,
        bold = bold == true,
    }
end

-- Give a card an exact natural size. KOReader containers use the child's
-- natural size for layout even when FrameContainer has width/height fields.
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

local function card(children, width, height)
    local border = S(1)
    local padding = S(12)
    local inner_width = width - 2 * (border + padding)
    local inner_height = height - 2 * (border + padding)
    return FrameContainer:new{
        width = width,
        height = height,
        padding = padding,
        bordersize = border,
        color = Blitbuffer.COLOR_GRAY_9,
        background = Blitbuffer.COLOR_WHITE,
        fixed_content(children, inner_width, inner_height),
    }
end

local function spacer(height)
    return VerticalSpan:new{ width = height }
end

local function horizontal_row(left, right, width, gap, left_width, height)
    left_width = left_width or math.floor((width - gap) / 2)
    height = height or S(142)
    return HorizontalGroup:new{
        card(left, left_width, height),
        HorizontalSpan:new{ width = gap },
        card(right, width - gap - left_width, height),
    }
end

local function quota_card(window, width, height)
    local used = number_or_nil(window.usedPct)
    local used_text = used and (string.format("%d%%", math.floor(used + 0.5))) or "--"
    local bar = ProgressWidget:new{
        width = width - S(26),
        height = S(16),
        percentage = used and used / 100 or 0,
        bordersize = S(1),
        margin_h = S(3),
        margin_v = S(1),
        radius = S(2),
        bordercolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_WHITE,
        fillcolor = Blitbuffer.COLOR_BLACK,
    }
    return card({
        text_widget(one_line(window.name, "Quota"), 15, width - S(26), true),
        spacer(S(5)),
        text_widget(used_text .. " used", 26, width - S(26), true),
        spacer(S(5)),
        bar,
        spacer(S(7)),
        text_widget("Reset: " .. compact_timestamp(window.resetAt, true), 12, width - S(26)),
    }, width, height)
end

local function unavailable_card(label, message, width, height)
    return card({
        text_widget(label, 15, width - S(26), true),
        spacer(S(12)),
        text_widget(message, 18, width - S(26), true),
    }, width, height)
end

local DashboardView = InputContainer:extend{
    covers_fullscreen = true,
}

function DashboardView:init()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local is_landscape = screen_width > screen_height
    local outer = S(18)
    local gap = S(12)
    local content_width = screen_width - 2 * outer
    local card_width = math.floor((content_width - gap) / 2)
    local top_left_width = is_landscape and math.floor(content_width * 0.42) or card_width
    local small_face_width = content_width - S(26)
    local data = self.data or {}
    local sources = data.sources or {}
    local codex = sources.codex or {}
    local weather = data.weather
    local solar_date, lunar_date = calendar_text(data)

    local header_right_width = math.floor(content_width * 0.37)
    local header = is_landscape and HorizontalGroup:new{
        text_widget("KINDLE AI QUOTA DASHBOARD", 20, content_width - header_right_width - S(18), true),
        HorizontalSpan:new{ width = S(18) },
        VerticalGroup:new{
            text_widget(os.date("%H:%M"), 14, header_right_width, true),
            spacer(S(2)),
            text_widget(solar_date, 12, header_right_width),
            spacer(S(2)),
            text_widget(lunar_date, 12, header_right_width),
        },
    } or VerticalGroup:new{
        text_widget("KINDLE AI QUOTA DASHBOARD", 20, content_width, true),
        spacer(S(3)),
        text_widget(os.date("%H:%M  ") .. solar_date, 13, content_width),
        spacer(S(2)),
        text_widget(lunar_date, 12, content_width),
    }

    local weather_title = "WEATHER"
    local weather_place = "天气未配置"
    local weather_detail = ""
    local weather_extra = ""
    local weather_width = content_width - top_left_width - gap
    if weather and weather.ok == true then
        weather_place = one_line(weather.place, "扬州") .. "  " .. one_line(weather.description, "-")
        weather_detail = one_line(weather.tempC, "-") .. " C   体感 " .. one_line(weather.feelsLikeC, "-") .. " C"
        weather_extra = "湿度 " .. one_line(weather.humidity, "-") .. "%"
        if weather.windKph ~= nil then
            weather_extra = weather_extra .. "   风 " .. one_line(weather.windKph) .. " km/h"
        end
    end

    local weather_card = {
        text_widget(weather_title, 14, weather_width - S(26), true),
        spacer(S(3)),
        text_widget(weather_place, 16, weather_width - S(26), true),
        spacer(S(2)),
        text_widget(weather_detail, 15, weather_width - S(26), true),
        spacer(S(2)),
        text_widget(weather_extra, 12, weather_width - S(26)),
    }

    local top_row = horizontal_row({
        text_widget("NOW", 14, top_left_width - S(26), true),
        spacer(S(8)),
        text_widget(os.date("%H:%M"), 31, top_left_width - S(26), true),
        spacer(S(3)),
        text_widget(solar_date, 13, top_left_width - S(26)),
    }, weather_card, content_width, gap, top_left_width, is_landscape and S(154) or S(142))

    local children = { header, spacer(gap), top_row, spacer(gap) }
    local quote = type(data.quote) == "table" and data.quote or nil
    if quote and quote.text then
        local quote_text = "\"" .. one_line(quote.text) .. "\""
        local quote_source = quote.source and ("— " .. one_line(quote.source)) or ""
        table.insert(children, card({
            text_widget("QUOTE", 14, small_face_width, true),
            spacer(S(5)),
            text_widget(quote_text, 15, small_face_width),
            spacer(S(4)),
            text_widget(quote_source, 12, small_face_width),
        }, content_width, S(94)))
        table.insert(children, spacer(gap))
    end

    local quota_windows = {}
    if codex.ok and type(codex.windows) == "table" then
        for _, window in ipairs(codex.windows) do
            table.insert(quota_windows, window)
        end
    end
    if #quota_windows == 0 then
        table.insert(children, unavailable_card(
            "CODEX",
            "暂时无法取得额度数据",
            content_width,
            is_landscape and S(150) or S(145)
        ))
    elseif #quota_windows == 1 then
        -- A single provider gets the full row, avoiding the large empty area
        -- visible in the portrait screenshot.
        table.insert(children, quota_card(
            quota_windows[1],
            content_width,
            is_landscape and S(184) or S(172)
        ))
    else
        for index = 1, #quota_windows, 2 do
            local left = quota_card(quota_windows[index], card_width, is_landscape and S(170) or S(172))
            local row
            if quota_windows[index + 1] then
                row = HorizontalGroup:new{
                    left,
                    HorizontalSpan:new{ width = gap },
                    quota_card(quota_windows[index + 1], content_width - card_width - gap, is_landscape and S(170) or S(172)),
                }
            else
                row = HorizontalGroup:new{ left }
            end
            table.insert(children, row)
            if index + 1 <= #quota_windows then
                table.insert(children, spacer(gap))
            end
        end
    end

    local footer = VerticalGroup:new{
        text_widget("更新：" .. compact_timestamp(data.updatedAt, false), 11, content_width),
        spacer(S(3)),
        text_widget("每 3 分钟自动刷新 · 点击屏幕关闭", 11, content_width),
    }
    table.insert(children, spacer(gap))
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
    -- KOReader uses even values for portrait and odd values for landscape.
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
        weather = { ok = false },
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
        self:showError("网络请求失败：HTTP " .. one_line(code, "error"))
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
