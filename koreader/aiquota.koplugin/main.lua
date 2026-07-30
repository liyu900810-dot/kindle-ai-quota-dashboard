-- AI Quota Dashboard for KOReader
-- Designed for jailbroken Kindle devices, including the original Paperwhite.

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Trapper = require("ui/trapper")
local Screen = require("device").screen
local http = require("socket.http")
local json = require("json")
local ltn12 = require("ltn12")
local _ = require("gettext")

local REFRESH_SECONDS = 180

local AiQuota = WidgetContainer:extend{
    name = "ai_quota_dashboard",
    is_doc_only = false,
    endpoint = "https://liyu900810-dot.github.io/kindle-ai-quota-dashboard/data.json",
    dashboard_message = nil,
    refresh_task = nil,
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
        callback = function()
            self:refresh()
        end,
    }
end

function AiQuota:onAIQuotaRefresh()
    self:refresh()
end

local function one_line(value, fallback)
    if value == nil or value == "" then
        return fallback or "-"
    end
    return tostring(value)
end

local function percent_bar(value, width)
    local number = tonumber(value)
    if not number then
        return "[ unavailable ]"
    end
    number = math.max(0, math.min(100, number))
    local filled = math.floor((number / 100) * width + 0.5)
    return "[" .. string.rep("#", filled) .. string.rep(".", width - filled) .. "]"
end

local function appendWeather(lines, weather)
    table.insert(lines, "[ WEATHER ]")
    if not weather or weather.ok ~= true then
        table.insert(lines, "Not configured")
        return
    end

    table.insert(lines, one_line(weather.place, "Unknown place") .. "  " .. one_line(weather.description, "Unknown conditions"))
    table.insert(lines, "Temperature: " .. one_line(weather.tempC, "-") .. " C   Feels: " .. one_line(weather.feelsLikeC, "-") .. " C")
    table.insert(lines, "Humidity: " .. one_line(weather.humidity, "-") .. "%")
    if weather.windKph ~= nil then
        table.insert(lines, "Wind: " .. one_line(weather.windKph) .. " km/h " .. one_line(weather.windDir, ""))
    end
end

function AiQuota:formatData(data)
    local now = os.date("%H:%M")
    local date = os.date("%Y-%m-%d %a")
    local lines = {
        "KINDLE AI QUOTA DASHBOARD                 " .. now,
        date .. "                         AUTO 3 MIN",
        "------------------------------------------",
    }
    local sources = data.sources or {}
    local codex = sources.codex or {}

    table.insert(lines, "[ CODEX ]")
    if codex.ok and codex.windows and #codex.windows > 0 then
        for _, window in ipairs(codex.windows) do
            local used = one_line(window.usedPct, "-")
            table.insert(lines, string.format("%s: %s%% used", one_line(window.name, "quota"), used))
            table.insert(lines, percent_bar(window.usedPct, 24))
            table.insert(lines, "Reset: " .. one_line(window.resetAt))
        end
    else
        table.insert(lines, "CODEX: unavailable")
        if codex.error then
            table.insert(lines, one_line(codex.error))
        end
    end

    table.insert(lines, "------------------------------------------")
    appendWeather(lines, data.weather)

    if data.quote and data.quote.text then
        table.insert(lines, "------------------------------------------")
        table.insert(lines, "[ QUOTE ]")
        table.insert(lines, "\"" .. one_line(data.quote.text) .. "\"")
        if data.quote.source then
            table.insert(lines, "- " .. one_line(data.quote.source))
        end
    end

    table.insert(lines, "------------------------------------------")
    table.insert(lines, "[ OTHER SOURCES ]")
    for key, source in pairs(sources) do
        if key ~= "codex" and source and source.disabled ~= true then
            table.insert(lines, string.upper(one_line(source.label, key)))
            if source.ok == true and source.balance ~= nil then
                table.insert(lines, "Balance: " .. one_line(source.balance) .. " " .. one_line(source.currency, ""))
            else
                table.insert(lines, "Unavailable")
            end
        end
    end

    table.insert(lines, "------------------------------------------")
    table.insert(lines, "Updated: " .. one_line(data.updatedAt))
    table.insert(lines, "Auto refreshes every 3 minutes while this page is open.")
    table.insert(lines, "Tap anywhere to close.")
    return table.concat(lines, "\n")
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

function AiQuota:showMessage(text)
    if self.dashboard_message then
        UIManager:close(self.dashboard_message)
        self.dashboard_message = nil
    end
    local message
    message = InfoMessage:new{
        text = text,
        width = Screen:getWidth() - Screen:scaleBySize(12),
        height = Screen:getHeight() - Screen:scaleBySize(12),
        show_icon = false,
        monospace_font = true,
        flush_events_on_show = true,
        dismiss_callback = function()
            if self.dashboard_message == message then
                self.dashboard_message = nil
                self:stopAutoRefresh()
            end
        end,
    }
    self.dashboard_message = message
    UIManager:show(message)
    self:startAutoRefresh()
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
        self:showMessage("AI quota dashboard\n\nNetwork request failed.\nHTTP: " .. one_line(code, "error"))
        return
    end

    local decoded, data = pcall(json.decode, table.concat(body))
    if not decoded or type(data) ~= "table" then
        self:showMessage("AI quota dashboard\n\nInvalid data received.")
        return
    end

    self:showMessage(self:formatData(data))
end

function AiQuota:refresh()
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            self:fetchAndShow()
        end)
    end)
end

return AiQuota
