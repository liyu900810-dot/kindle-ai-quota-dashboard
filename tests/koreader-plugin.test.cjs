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

test('KOReader plugin is e-ink aware and includes v6.1 metadata', () => {
  assert.match(main, /REFRESH_SECONDS = 300/);
  assert.match(main, /refresh_count % 4 == 0 and "full" or "ui"/);
  assert.match(main, /function WeatherIcon:paintTo/);
  assert.doesNotMatch(main, /[☀☁☂☼]/u);
  assert.match(main, /local CodexIcon = Widget:extend/);
  assert.match(main, /local function todo_card/);
  assert.match(main, /math\.min\(5, #items\)/);
  assert.doesNotMatch(main, /local footer = fixed_content/);
  assert.match(main, /自动刷新 · 每 5 分钟/);
  assert.match(meta, /version = "6\.1\.0"/);
});
