'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');
const {
  calendarSnapshot,
  demoSnapshot,
  preserveLastKnownGood,
  validateSnapshot,
  writeSnapshot,
} = require('../src/collect.cjs');
const { safeError } = require('../src/lib/common.cjs');
const { ROOT, validateConfig } = require('../src/lib/config.cjs');

test('demo snapshot passes the public schema', () => {
  const snapshot = demoSnapshot();
  assert.doesNotThrow(() => validateSnapshot(snapshot));
  assert.equal(snapshot.weather.place, '示例城市');
  assert.equal(snapshot.sources.deepseek.balance, 12.34);
});

test('calendar snapshot formats solar and lunar dates in Chinese', () => {
  assert.deepEqual(calendarSnapshot(new Date('2026-07-30T00:00:00+08:00')), {
    solar: '2026年7月30日 星期四',
    lunar: '农历六月十七',
  });
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
