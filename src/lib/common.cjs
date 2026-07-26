'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REQUEST_TIMEOUT_MS = 20_000;

function isoBeijing(value = new Date()) {
  const date = value instanceof Date ? value : new Date(value);
  if (!Number.isFinite(date.getTime())) return null;
  return new Date(date.getTime() + 8 * 60 * 60 * 1000)
    .toISOString()
    .replace('Z', '+08:00');
}

function round1(value) {
  return Math.round(Number(value) * 10) / 10;
}

function clampPct(value) {
  return Math.min(100, Math.max(0, round1(value)));
}

function safeError(error) {
  return String(error && error.message ? error.message : error || '未知错误')
    .replace(/(authorization\s*[:=]?\s*bearer\s+)[^\s,;]+/gi, '$1[已隐藏]')
    .replace(/(access[_-]?token|refresh[_-]?token|api[_-]?key|password|secret|cookie)\s*[:=]\s*[^\s,;]+/gi, '$1=[已隐藏]')
    .replace(/[A-Za-z0-9_-]{80,}/g, '[凭据已隐藏]')
    .slice(0, 240);
}

async function fetchJson(url, options = {}) {
  const controller = new AbortController();
  const timeoutMs = Number(options.timeoutMs || REQUEST_TIMEOUT_MS);
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const requestOptions = { ...options, signal: controller.signal };
  delete requestOptions.timeoutMs;
  try {
    const response = await fetch(url, requestOptions);
    const text = await response.text();
    let payload = null;
    if (text) {
      try {
        payload = JSON.parse(text);
      } catch {
        throw new Error(`HTTP ${response.status} 返回了非 JSON 数据`);
      }
    }
    if (!response.ok) {
      const message = payload && (payload.message || payload.error && payload.error.message);
      throw new Error(`HTTP ${response.status}${message ? `：${safeError(message)}` : ''}`);
    }
    return payload;
  } finally {
    clearTimeout(timer);
  }
}

function expandHome(filePath) {
  const value = String(filePath || '').trim();
  if (!value) return '';
  if (value === '~') return os.homedir();
  if (value.startsWith('~/') || value.startsWith('~\\')) {
    return path.join(os.homedir(), value.slice(2));
  }
  return path.resolve(value);
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeAtomic(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, content, 'utf8');
  fs.renameSync(temporary, filePath);
}

function failedWindows(label, error, fetchedAt = isoBeijing()) {
  return {
    ok: false,
    label,
    windows: [],
    fetchedAt,
    error: safeError(error),
  };
}

function failedBalance(label, error, fetchedAt = isoBeijing()) {
  return {
    ok: false,
    label,
    balance: null,
    currency: 'CNY',
    detail: null,
    fetchedAt,
    error: safeError(error),
  };
}

module.exports = {
  clampPct,
  expandHome,
  failedBalance,
  failedWindows,
  fetchJson,
  isoBeijing,
  readJson,
  round1,
  safeError,
  writeAtomic,
};
