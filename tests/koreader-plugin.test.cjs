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

test('KOReader plugin is e-ink aware and includes v6.4 metadata', () => {
  assert.match(main, /REFRESH_SECONDS = 300/);
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
  assert.match(main, /function WeatherIcon:paintMoon/);
  assert.match(main, /Open-Meteo/);
  assert.match(main, /validate_dashboard_data/);
  assert.match(main, /refresh_seconds/);
  assert.doesNotMatch(main, /local footer = fixed_content/);
  assert.match(meta, /version = "6\.4\.0"/);
});
