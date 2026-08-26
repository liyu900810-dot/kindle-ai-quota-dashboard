'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const pluginDir = path.join(root, 'koreader', 'aiquota.koplugin');
const main = fs.readFileSync(path.join(pluginDir, 'main.lua'), 'utf8');
const meta = fs.readFileSync(path.join(pluginDir, '_meta.lua'), 'utf8');

test('KOReader plugin uses one-pass font scaling and fixed alignment containers', () => {
  assert.match(main, /Font:getFace\("cfont", size\)/);
  assert.doesNotMatch(main, /Font:getFace\("cfont", S\(size\)\)/);
  assert.match(main, /RightContainer/);
  assert.match(main, /left_cell/);
  assert.match(main, /right_cell/);
});

test('KOReader plugin protects network requests and preserves cached data', () => {
  assert.match(main, /socketutil:set_timeout/);
  assert.match(main, /MAX_RESPONSE_BYTES/);
  assert.match(main, /aiquota-dashboard-cache\.json/);
  assert.match(main, /showCachedError/);
  assert.match(main, /last_good_data/);
  assert.match(main, /request_url = self\.endpoint .* "_=" \.\. tostring\(os\.time\(\)\)/);
});

test('KOReader plugin is e-ink aware and includes v7.7 metadata', () => {
  const retrySection = main.match(
    /function AiQuota:scheduleOnlineRetry[\s\S]*?function AiQuota:onNetworkConnected/,
  );
  const showSection = main.match(
    /function AiQuota:showDashboard[\s\S]*?function AiQuota:showCachedError/,
  );

  assert.ok(retrySection);
  assert.ok(showSection);
  assert.doesNotMatch(retrySection[0], /self:refresh\(false\)/);
  assert.ok(
    showSection[0].indexOf('UIManager:show(message)')
      < showSection[0].indexOf('UIManager:close(previous_message)'),
  );
  assert.doesNotMatch(showSection[0], /UIManager:close\(self\.dashboard_message\)/);
  assert.match(showSection[0], /if self\.dashboard_message ~= message then\s+return/);
  assert.match(main, /REFRESH_SECONDS = 60/);
  assert.match(main, /LOW_BATTERY_REFRESH_SECONDS = 300/);
  assert.match(main, /refresh_count % 4 == 0 and "full" or "ui"/);
  assert.match(main, /function WeatherIcon:paintTo/);
  assert.doesNotMatch(main, /[☀☁☂☼]/u);
  assert.match(main, /local CodexIcon = Widget:extend/);
  assert.match(main, /local function todo_card/);
  assert.match(main, /local function hourly_forecast_strip/);
  assert.match(main, /for index = 1, 6 do/);
  assert.match(main, /displayed_count = math\.min\(3, #items\)/);
  assert.match(main, /\* 0\.30\)/);
  assert.match(main, /未来 12 小时 · 每 2 小时/);
  assert.doesNotMatch(main, /weather_divider_width/);
  assert.doesNotMatch(main, /只显示未完成事项|Kindle 端只读/);
  assert.match(main, /todo_height = is_landscape and S\(210\)/);
  assert.match(main, /local top_row = HorizontalGroup:new\{\s+align = "top"/);
  assert.doesNotMatch(main, /os\.date\("%Y-%m-%d-%H-%M"\)/);
  assert.match(main, /function WeatherIcon:paintMoon/);
  assert.match(main, /Open-Meteo/);
  assert.match(main, /validate_dashboard_data/);
  assert.match(main, /refresh_seconds/);
  assert.match(main, /CLOSE_GUARD_SECONDS = 3/);
  assert.match(main, /self\.ges_events\.TapIgnore/);
  assert.match(main, /function DashboardView:onTapIgnore\(\)\s+return true/);
  assert.match(main, /function DashboardView:onAnyKeyPressed\(\)\s+return true/);
  assert.match(main, /return self:onClose\("swipe"\)/);
  assert.doesNotMatch(main, /self\.ges_events\.TapClose/);
  assert.doesNotMatch(main, /DashboardView\.onAnyKeyPressed = DashboardView\.onClose/);
  assert.match(main, /dashboard view closed; source=/);
  assert.match(main, /function DashboardView:updateClock\(\)/);
  assert.match(main, /self\.clock_widget:setText\(value\)/);
  assert.match(main, /self\.clock_container\.dimen/);
  assert.match(main, /function AiQuota:startClockRefresh\(\)/);
  assert.match(main, /seconds_until_next_minute\(\)/);
  assert.match(main, /UIManager:scheduleIn\(seconds_until_next_minute\(\), self\.clock_task\)/);
  assert.match(main, /function AiQuota:onNetworkConnected\(\)/);
  assert.match(main, /NetworkMgr:runWhenConnected/);
  assert.doesNotMatch(main, /NetworkMgr:runWhenOnline/);
  assert.doesNotMatch(main, /local footer = fixed_content/);
  assert.match(meta, /version = "7\.7\.0"/);
});

test('KOReader quota card shows five-hour and weekly windows side by side', () => {
  const quotaSection = main.match(
    /local function quota_window_panel[\s\S]*?local function todo_card/,
  );
  assert.ok(quotaSection);
  assert.match(quotaSection[0], /local function select_quota_windows\(windows\)/);
  assert.match(quotaSection[0], /name:find\("5", 1, true\)/);
  assert.match(quotaSection[0], /name:find\("小时", 1, true\)/);
  assert.match(quotaSection[0], /label == "周"/);
  assert.match(quotaSection[0], /name:find\("7天", 1, true\)/);
  assert.match(quotaSection[0], /if weekly_window == short_window then\s+weekly_window = nil/);
  assert.match(quotaSection[0], /quota_window_panel\(short_window, left_width/);
  assert.match(quotaSection[0], /quota_window_panel\(weekly_window, right_width/);
  assert.match(quotaSection[0], /ForecastDivider:new\{ width = divider_width/);
  assert.match(main, /quota_card\(codex\.windows, content_width, quota_height\)/);
  assert.doesNotMatch(main, /if not quota_window or quota_label\(window\) == "周"/);
});

test('KOReader plugin guards sustained high memory without another timer', () => {
  const memorySection = main.match(
    /function AiQuota:checkMemoryGuard[\s\S]*?function AiQuota:enterLandscape/,
  );

  assert.ok(memorySection);
  assert.match(main, /MEMORY_CHECK_EVERY_REFRESHES = 5/);
  assert.match(main, /MEMORY_THRESHOLD_MB = 100/);
  assert.match(main, /MEMORY_HIGH_SAMPLES = 2/);
  assert.match(main, /MEMORY_RESTART_COOLDOWN_SECONDS = 6 \* 60 \* 60/);
  assert.match(main, /local function current_rss_mb\(\)/);
  assert.match(main, /io\.open\("\/proc\/self\/statm", "r"\)/);
  assert.match(memorySection[0], /self\.memory_high_samples = self\.memory_high_samples \+ 1/);
  assert.match(memorySection[0], /save_health_state\(self\.health_state\)/);
  assert.match(memorySection[0], /Event:new\("Restart"\)/);
  assert.match(main, /if is_automatic and self:checkMemoryGuard\(\) then/);
  assert.doesNotMatch(main, /memory_task\s*=/);
});

test('KOReader plugin reopens safely after memory recovery and tolerates bad state', () => {
  assert.match(main, /aiquota-health\.json/);
  assert.match(main, /local function default_health_state\(\)/);
  assert.match(main, /if not ok or type\(decoded\) ~= "table" then\s+return state/);
  assert.match(main, /REOPEN_MAX_AGE_SECONDS = 10 \* 60/);
  assert.match(main, /REOPEN_DELAY_SECONDS = 5/);
  assert.match(main, /if self\.health_state\.reopen_pending then/);
  assert.match(main, /self\.health_state\.reopen_pending = false/);
  assert.match(main, /UIManager:scheduleIn\(REOPEN_DELAY_SECONDS, self\.reopen_task\)/);
  assert.match(main, /collectgarbage\("step", 200\)/);
  assert.match(main, /collectgarbage\("collect"\)/);
  assert.doesNotMatch(main, /dashboard view replaced/);
});
