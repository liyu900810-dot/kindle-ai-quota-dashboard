'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');
const {
  buildHourlyForecast,
  calendarSnapshot,
  demoSnapshot,
  preserveLastKnownGood,
  validateSnapshot,
  weatherCodeDetails,
  writeSnapshot,
} = require('../src/collect.cjs');
const { safeError } = require('../src/lib/common.cjs');
const { ROOT, validateConfig } = require('../src/lib/config.cjs');
const {
  dueLabel,
  notionPageIsDone,
  notionPageIsVisible,
  notionPageToItem,
  compareTodoItems,
  readTodoFile,
} = require('../src/collectors/todo.cjs');

test('demo snapshot passes the public schema', () => {
  const snapshot = demoSnapshot();
  assert.doesNotThrow(() => validateSnapshot(snapshot));
  assert.equal(snapshot.weather.place, '示例城市');
  assert.equal(snapshot.sources.deepseek.balance, 12.34);
  assert.equal(snapshot.todo.items.length, 3);
});

test('calendar snapshot formats solar and lunar dates in Chinese', () => {
  assert.deepEqual(calendarSnapshot(new Date('2026-07-30T00:00:00+08:00')), {
    solar: '2026年7月30日 星期四',
    lunar: '农历六月十七',
  });
});

test('hourly weather samples the next 12 hours in two-hour steps', () => {
  const hourly = {
    time: Array.from({ length: 13 }, (_, index) => `2026-07-30T${String(10 + index).padStart(2, '0')}:00`),
    temperature_2m: Array.from({ length: 13 }, (_, index) => 20 + index),
    weather_code: Array.from({ length: 13 }, (_, index) => index % 2),
    is_day: Array.from({ length: 13 }, (_, index) => index >= 7 ? 1 : 0),
    precipitation_probability: Array.from({ length: 13 }, (_, index) => index * 2),
  };
  const forecast = buildHourlyForecast(hourly);
  assert.equal(forecast.length, 6);
  assert.deepEqual(forecast.map((item) => item.time), [
    '2026-07-30T12:00',
    '2026-07-30T14:00',
    '2026-07-30T16:00',
    '2026-07-30T18:00',
    '2026-07-30T20:00',
    '2026-07-30T22:00',
  ]);
  assert.deepEqual(forecast.map((item) => item.tempC), [22, 24, 26, 28, 30, 32]);
  assert.deepEqual(forecast.map((item) => item.isDay), [0, 0, 0, 1, 1, 1]);
  assert.deepEqual(weatherCodeDetails(0), { description: '晴', iconKey: 'clear' });
  assert.deepEqual(weatherCodeDetails(0, 0), { description: '晴', iconKey: 'clear-night' });
  assert.deepEqual(weatherCodeDetails(null), { description: '未知', iconKey: 'unknown' });
  assert.deepEqual(weatherCodeDetails(61), { description: '雨', iconKey: 'rain' });
});

test('weather schema rejects malformed hourly forecast data', () => {
  const snapshot = demoSnapshot();
  snapshot.weather.forecast[0].time = 'not-a-time';
  assert.throws(() => validateSnapshot(snapshot), /weather\.forecast/);
});

test('last known good data is preserved only for enabled failing providers', () => {
  const previous = demoSnapshot();
  const next = demoSnapshot();
  next.sources.claude = {
    ok: false,
    label: 'Claude',
    windows: [],
    fetchedAt: next.updatedAt,
    error: '临时失败',
  };
  next.sources.kimi = {
    ok: false,
    label: 'Kimi',
    windows: [],
    fetchedAt: next.updatedAt,
    error: '未启用',
    disabled: true,
  };
  preserveLastKnownGood(next, previous);
  assert.equal(next.sources.claude.ok, true);
  assert.equal(next.sources.claude.stale, true);
  assert.equal(next.sources.claude.error, '临时失败');
  assert.equal(next.sources.kimi.ok, false);
  assert.equal(next.sources.kimi.disabled, true);
});

test('last known good weather is preserved after a transient weather failure', () => {
  const previous = demoSnapshot();
  const next = demoSnapshot();
  next.weather = {
    ok: false,
    place: '扬州',
    fetchedAt: next.updatedAt,
    error: 'fetch failed',
  };
  preserveLastKnownGood(next, previous);
  assert.equal(next.weather.ok, true);
  assert.equal(next.weather.stale, true);
  assert.equal(next.weather.place, '示例城市');
  assert.equal(next.weather.error, 'fetch failed');
  assert.equal(next.weather.lastAttemptAt, next.updatedAt);
});

test('last known good todo is preserved after a transient source failure', () => {
  const previous = demoSnapshot();
  const next = demoSnapshot();
  next.todo = {
    ok: false,
    source: 'notion',
    items: [],
    totalOpen: 0,
    fetchedAt: next.updatedAt,
    error: 'Notion unavailable',
  };
  preserveLastKnownGood(next, previous);
  assert.equal(next.todo.ok, true);
  assert.equal(next.todo.stale, true);
  assert.equal(next.todo.items.length, 3);
  assert.equal(next.todo.error, 'Notion unavailable');
});

test('todo file excludes completed items and limits public output', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kindle-todo-test-'));
  const file = path.join(dir, 'todo.json');
  try {
    fs.writeFileSync(file, JSON.stringify({
      items: [
        { title: '第一项', dueLabel: '今天' },
        { title: '已完成', completed: true },
        { title: '第二项', dueLabel: '明天' },
        { title: '第三项', dueLabel: '本周' },
      ],
    }), 'utf8');
    const result = readTodoFile(file, 2);
    assert.equal(result.ok, true);
    assert.equal(result.totalOpen, 3);
    assert.deepEqual(result.items.map((item) => item.title), ['第一项', '第二项']);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('Notion task properties map to the public todo schema', () => {
  const page = {
    properties: {
      任务: { type: 'title', title: [{ plain_text: '整理项目材料' }] },
      状态: { type: 'status', status: { name: '进行中' } },
      截止日期: { type: 'date', date: { start: '2026-07-31' } },
      优先级: { type: 'select', select: { name: '高' } },
      Kindle显示: { type: 'checkbox', checkbox: true },
      Kindle置顶: { type: 'checkbox', checkbox: true },
    },
  };
  const config = {};
  assert.equal(notionPageIsDone(page, config), false);
  assert.equal(notionPageIsVisible(page, config), true);
  assert.deepEqual(notionPageToItem(page, config, new Date('2026-07-30T08:00:00Z')), {
    title: '整理项目材料',
    dueAt: '2026-07-31',
    dueLabel: '明天',
    priority: '高',
    pinned: true,
  });
  page.properties.状态.status.name = '完成';
  assert.equal(notionPageIsDone(page, config), true);
  page.properties.Kindle显示.checkbox = false;
  assert.equal(notionPageIsVisible(page, config), false);
  assert.equal(dueLabel('2026-07-29', new Date('2026-07-30T08:00:00Z')), '逾期');
});

test('todo sorting prioritizes pinned, due date, then priority', () => {
  const items = [
    { title: '普通任务', dueAt: '2026-08-01', priority: '高', pinned: false },
    { title: '置顶任务', dueAt: null, priority: '低', pinned: true },
    { title: '今天任务', dueAt: '2026-07-31', priority: '普通', pinned: false },
  ];
  assert.deepEqual(items.sort(compareTodoItems).map((item) => item.title), [
    '置顶任务',
    '今天任务',
    '普通任务',
  ]);
});

test('safeError removes obvious credential material', () => {
  const secret = 'A'.repeat(90);
  const output = safeError(`authorization: bearer ${secret}`);
  assert.doesNotMatch(output, new RegExp(secret));
  assert.match(output, /已隐藏/);
});

test('config rejects inline secrets but accepts environment variable names', () => {
  assert.doesNotThrow(() => validateConfig({
    providers: { deepseek: { apiKeyEnv: 'DEEPSEEK_API_KEY' } },
  }));
  assert.throws(() => validateConfig({
    providers: { demo: { token: 'this-should-never-be-here' } },
  }), /不允许保存密钥值/);
});

test('snapshot writer emits JSON and old-browser JavaScript', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kindle-quota-test-'));
  try {
    writeSnapshot(demoSnapshot(), dir, false);
    const json = JSON.parse(fs.readFileSync(path.join(dir, 'data.json'), 'utf8'));
    const javascript = fs.readFileSync(path.join(dir, 'data.js'), 'utf8');
    assert.equal(json.sources.codex.ok, true);
    assert.match(javascript, /^window\.DASH_DATA = /);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('browser runtime is valid JavaScript', () => {
  const result = spawnSync(process.execPath, ['--check', path.join(ROOT, 'web', 'app.js')], {
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
});

test('browser runtime tolerates deployment cache without reporting false offline', () => {
  const runtime = fs.readFileSync(path.join(ROOT, 'web', 'dashboard-runtime.js'), 'utf8');
  assert.match(runtime, /delayAfterMinutes:\s*10/);
  assert.match(runtime, /offlineAfterMinutes:\s*30/);
  assert.match(runtime, /age > settings\.offlineAfterMinutes/);
});
