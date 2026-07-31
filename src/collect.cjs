'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { collectClaude } = require('./collectors/claude.cjs');
const { collectCodex } = require('./collectors/codex.cjs');
const { collectDeepSeek } = require('./collectors/deepseek.cjs');
const { collectKimi } = require('./collectors/kimi.cjs');
const { collectTodo } = require('./collectors/todo.cjs');
const { ROOT, loadConfig } = require('./lib/config.cjs');
const {
  isoBeijing,
  readJson,
  safeError,
  writeAtomic,
} = require('./lib/common.cjs');

const SOURCE_NAMES = ['claude', 'codex', 'kimi', 'deepseek'];
const SNAPSHOT_SCHEMA_VERSION = 3;

function calendarSnapshot(value = new Date()) {
  const date = value instanceof Date ? value : new Date(value);
  if (!Number.isFinite(date.getTime())) return null;
  const solarParts = new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
    weekday: 'long',
    timeZone: 'Asia/Shanghai',
  }).formatToParts(date);
  const lunarParts = new Intl.DateTimeFormat('zh-CN-u-ca-chinese', {
    dateStyle: 'full',
    timeZone: 'Asia/Shanghai',
  }).formatToParts(date);
  const part = (parts, type) => parts.find((item) => item.type === type)?.value || '';
  return {
    solar: `${part(solarParts, 'year')}年${part(solarParts, 'month')}月${part(solarParts, 'day')}日 ${part(solarParts, 'weekday')}`,
    lunar: `农历${part(lunarParts, 'month')}${part(lunarParts, 'day')}`,
  };
}

function readQuote(filePath) {
  if (!filePath) return null;
  try {
    const value = readJson(filePath);
    if (!value || !value.text) return null;
    return {
      text: String(value.text).slice(0, 180),
      source: String(value.source || '').slice(0, 80),
    };
  } catch {
    return null;
  }
}

function finiteNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function readWeather(filePath) {
  const fetchedAt = isoBeijing();
  if (!filePath) {
    return {
      ok: false,
      description: null,
      iconKey: null,
      tempC: null,
      feelsLikeC: null,
      humidity: null,
      windKph: null,
      windDir: null,
      isDay: null,
      forecast: [],
      place: null,
      observedAt: null,
      fetchedAt,
      error: '未配置天气文件',
    };
  }
  try {
    const value = readJson(filePath);
    return {
      ok: true,
      description: String(value.description || '天气').slice(0, 20),
      iconKey: String(value.iconKey || 'cloudy').slice(0, 30),
      tempC: finiteNumber(value.tempC),
      feelsLikeC: finiteNumber(value.feelsLikeC),
      humidity: finiteNumber(value.humidity),
      windKph: finiteNumber(value.windKph),
      windDir: String(value.windDir || '').slice(0, 20),
      isDay: value.isDay === 0 || value.isDay === 1 ? value.isDay : null,
      forecast: normalizeHourlyForecast(value.forecast),
      place: String(value.place || '').slice(0, 30),
      observedAt: isoBeijing(value.observedAt) || fetchedAt,
      fetchedAt,
      error: null,
    };
  } catch (error) {
    return {
      ok: false,
      description: null,
      iconKey: null,
      tempC: null,
      feelsLikeC: null,
      humidity: null,
      windKph: null,
      windDir: null,
      isDay: null,
      forecast: [],
      place: null,
      observedAt: null,
      fetchedAt,
      error: safeError(error),
    };
  }
}

function weatherCodeDetails(value, isDay = 1) {
  if (value === null || value === undefined || value === '') {
    return { description: '未知', iconKey: 'unknown' };
  }
  const code = Number(value);
  if (!Number.isFinite(code)) return { description: '未知', iconKey: 'unknown' };
  if (code === 0) {
    return { description: '晴', iconKey: Number(isDay) === 0 ? 'clear-night' : 'clear' };
  }
  if ([1, 2].includes(code)) return { description: '多云', iconKey: 'cloudy' };
  if (code === 3) return { description: '阴', iconKey: 'cloudy' };
  if ([45, 48].includes(code)) return { description: '雾', iconKey: 'fog' };
  if ([51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82].includes(code)) {
    return { description: '雨', iconKey: 'rain' };
  }
  if ([71, 73, 75, 77, 85, 86].includes(code)) {
    return { description: '雪', iconKey: 'snow' };
  }
  if ([95, 96, 99].includes(code)) return { description: '雷雨', iconKey: 'thunder' };
  return { description: '多云', iconKey: 'cloudy' };
}

function windDirectionLabel(value) {
  const degrees = finiteNumber(value);
  if (degrees === null) return '';
  const directions = ['北风', '东北风', '东风', '东南风', '南风', '西南风', '西风', '西北风'];
  return directions[Math.round((((degrees % 360) + 360) % 360) / 45) % directions.length];
}

function normalizeHourlyForecast(value) {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 6).map((item) => {
    const rawCode = item?.weatherCode ?? item?.code;
    const isDay = item?.isDay === 0 || item?.isDay === 1 ? item.isDay : null;
    const details = weatherCodeDetails(rawCode, isDay);
    return {
      time: String(item?.time || '').slice(0, 25),
      tempC: finiteNumber(item?.tempC),
      weatherCode: rawCode !== null && rawCode !== undefined && rawCode !== ''
        && Number.isFinite(Number(rawCode))
        ? Number(rawCode)
        : null,
      isDay,
      description: String(item?.description || details.description).slice(0, 12),
      iconKey: String(item?.iconKey || details.iconKey).slice(0, 20),
      precipitationProbability: finiteNumber(item?.precipitationProbability),
    };
  });
}

function buildHourlyForecast(hourly) {
  if (!hourly || !Array.isArray(hourly.time)) return [];
  const items = [];
  for (let index = 2; index <= 12; index += 2) {
    if (!hourly.time[index]) continue;
    const isDay = hourly.is_day?.[index] === 0 || hourly.is_day?.[index] === 1
      ? hourly.is_day[index]
      : null;
    const details = weatherCodeDetails(hourly.weather_code?.[index], isDay);
    items.push({
      time: String(hourly.time[index]).slice(0, 25),
      tempC: finiteNumber(hourly.temperature_2m?.[index]),
      weatherCode: finiteNumber(hourly.weather_code?.[index]),
      isDay,
      description: details.description,
      iconKey: details.iconKey,
      precipitationProbability: finiteNumber(hourly.precipitation_probability?.[index]),
    });
  }
  return items;
}

async function resolveWeatherLocation(place, options = {}) {
  const latitude = Number(options.latitude);
  const longitude = Number(options.longitude);
  if (Number.isFinite(latitude) && Number.isFinite(longitude)) {
    return { latitude, longitude, timezone: options.timezone || 'Asia/Shanghai' };
  }
  const url = new URL('https://geocoding-api.open-meteo.com/v1/search');
  url.searchParams.set('name', place);
  url.searchParams.set('count', '1');
  url.searchParams.set('language', 'zh');
  url.searchParams.set('countryCode', 'CN');
  const response = await fetch(url, {
    headers: { 'User-Agent': 'kindle-ai-quota-dashboard/0.1' },
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error(`天气城市定位失败（HTTP ${response.status}）`);
  const payload = await response.json();
  const result = payload?.results?.[0];
  if (!result || !Number.isFinite(Number(result.latitude)) || !Number.isFinite(Number(result.longitude))) {
    throw new Error(`未找到天气城市：${place}`);
  }
  return {
    latitude: Number(result.latitude),
    longitude: Number(result.longitude),
    timezone: String(result.timezone || options.timezone || 'Asia/Shanghai'),
  };
}

function localWeatherTimestamp(value, timezone) {
  const text = String(value || '');
  if (!text) return null;
  if (timezone === 'Asia/Shanghai' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(text)) {
    return `${text}:00+08:00`;
  }
  return text;
}

async function readRemoteWeather(place, label, options = {}) {
  const fetchedAt = isoBeijing();
  if (!place) {
    return {
      ok: false,
      description: null,
      iconKey: null,
      tempC: null,
      feelsLikeC: null,
      humidity: null,
      windKph: null,
      windDir: null,
      isDay: null,
      forecast: [],
      place: null,
      observedAt: null,
      fetchedAt,
      error: '未配置天气城市',
    };
  }
  try {
    const location = await resolveWeatherLocation(place, options);
    const url = new URL('https://api.open-meteo.com/v1/forecast');
    url.searchParams.set('latitude', String(location.latitude));
    url.searchParams.set('longitude', String(location.longitude));
    url.searchParams.set(
      'current',
      'temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m,is_day',
    );
    url.searchParams.set(
      'hourly',
      'temperature_2m,weather_code,precipitation_probability,is_day',
    );
    url.searchParams.set('forecast_hours', '13');
    url.searchParams.set('timezone', location.timezone);
    const response = await fetch(url, {
      headers: { 'User-Agent': 'kindle-ai-quota-dashboard/0.1' },
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) throw new Error(`天气请求失败（HTTP ${response.status}）`);
    const value = await response.json();
    const current = value?.current || {};
    const number = (field) => finiteNumber(current[field]);
    const isDay = current.is_day === 0 || current.is_day === 1 ? current.is_day : null;
    const details = weatherCodeDetails(current.weather_code, isDay);
    return {
      ok: true,
      description: details.description,
      iconKey: details.iconKey,
      tempC: number('temperature_2m'),
      feelsLikeC: number('apparent_temperature'),
      humidity: number('relative_humidity_2m'),
      windKph: number('wind_speed_10m'),
      windDir: windDirectionLabel(current.wind_direction_10m),
      isDay,
      forecast: buildHourlyForecast(value?.hourly),
      place: String(label || place).slice(0, 30),
      observedAt: localWeatherTimestamp(current.time, location.timezone) || fetchedAt,
      fetchedAt,
      source: 'open-meteo',
      error: null,
    };
  } catch (error) {
    return {
      ok: false,
      description: null,
      iconKey: null,
      tempC: null,
      feelsLikeC: null,
      humidity: null,
      windKph: null,
      windDir: null,
      isDay: null,
      forecast: [],
      place: String(label || place).slice(0, 30),
      observedAt: null,
      fetchedAt,
      error: safeError(error),
    };
  }
}

function demoSnapshot() {
  const now = isoBeijing();
  const afterHours = (hours) => isoBeijing(Date.now() + hours * 60 * 60 * 1000);
  return {
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    updatedAt: now,
    calendar: calendarSnapshot(),
    weather: {
      ok: true,
      description: '晴',
      iconKey: 'clear',
      tempC: 26,
      feelsLikeC: 28,
      humidity: 55,
      windKph: 8,
      windDir: '东南风',
      isDay: 1,
      forecast: [
        { time: afterHours(2), tempC: 25, weatherCode: 1, isDay: 1, description: '多云', iconKey: 'cloudy', precipitationProbability: 10 },
        { time: afterHours(4), tempC: 24, weatherCode: 0, isDay: 0, description: '晴', iconKey: 'clear-night', precipitationProbability: 0 },
        { time: afterHours(6), tempC: 24, weatherCode: 0, isDay: 0, description: '晴', iconKey: 'clear-night', precipitationProbability: 0 },
        { time: afterHours(8), tempC: 26, weatherCode: 1, isDay: 1, description: '多云', iconKey: 'cloudy', precipitationProbability: 5 },
        { time: afterHours(10), tempC: 29, weatherCode: 2, isDay: 1, description: '多云', iconKey: 'cloudy', precipitationProbability: 10 },
        { time: afterHours(12), tempC: 31, weatherCode: 61, isDay: 1, description: '雨', iconKey: 'rain', precipitationProbability: 40 },
      ],
      place: '示例城市',
      observedAt: now,
      fetchedAt: now,
      error: null,
    },
    quote: {
      text: '把无人走过的路，踩成后来人的近路。',
      source: '开源演示',
    },
    todo: {
      ok: true,
      source: 'demo',
      items: [
        { title: '检查 Kindle 新版界面', dueAt: null, dueLabel: '今天', priority: '高' },
        { title: '补充个人待办事项', dueAt: null, dueLabel: '明天', priority: '普通' },
        { title: '确认电脑自动更新任务', dueAt: null, dueLabel: '本周', priority: '普通' },
      ],
      totalOpen: 3,
      fetchedAt: now,
      error: null,
    },
    sources: {
      claude: {
        ok: true,
        label: 'Claude',
        windows: [
          { name: '5小时', usedPct: 23, resetAt: afterHours(3) },
          { name: '7天', usedPct: 42, resetAt: afterHours(96) },
        ],
        fetchedAt: now,
        error: null,
      },
      codex: {
        ok: true,
        label: 'Codex',
        windows: [{ name: '周', usedPct: 18, resetAt: afterHours(120) }],
        fetchedAt: now,
        error: null,
      },
      kimi: {
        ok: true,
        label: 'Kimi',
        windows: [
          { name: '5小时', usedPct: 35, resetAt: afterHours(4) },
          { name: '周', usedPct: 56, resetAt: afterHours(72) },
        ],
        fetchedAt: now,
        error: null,
      },
      deepseek: {
        ok: true,
        label: 'DeepSeek',
        balance: 12.34,
        currency: 'CNY',
        detail: '余额 ¥12.34',
        fetchedAt: now,
        error: null,
      },
    },
  };
}

async function realSnapshot(config) {
  const providers = config.providers || {};
  const [claude, codex, kimi, deepseek, todo] = await Promise.all([
    collectClaude(providers.claude),
    collectCodex(providers.codex),
    collectKimi(providers.kimi),
    collectDeepSeek(providers.deepseek),
    collectTodo(config.todo),
  ]);
  return {
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    updatedAt: isoBeijing(),
    calendar: calendarSnapshot(),
    weather: config.weatherFile
      ? readWeather(config.weatherFile)
      : await readRemoteWeather(config.weatherPlace, config.weatherLabel, {
        latitude: config.weatherLatitude,
        longitude: config.weatherLongitude,
        timezone: config.weatherTimezone,
      }),
    quote: readQuote(config.quoteFile),
    todo,
    sources: { claude, codex, kimi, deepseek },
  };
}

function previousSnapshot(outputDir) {
  try {
    return readJson(path.join(outputDir, 'data.json'));
  } catch {
    return null;
  }
}

function preserveLastKnownGood(snapshot, previous) {
  if (!previous) return snapshot;
  if (
    snapshot.weather
    && !snapshot.weather.ok
    && previous.weather
    && previous.weather.ok
  ) {
    snapshot.weather = {
      ...previous.weather,
      stale: true,
      lastAttemptAt: snapshot.weather.fetchedAt,
      error: snapshot.weather.error,
    };
  }
  if (
    snapshot.todo
    && !snapshot.todo.ok
    && !snapshot.todo.disabled
    && previous.todo
    && previous.todo.ok
  ) {
    snapshot.todo = {
      ...previous.todo,
      stale: true,
      lastAttemptAt: snapshot.todo.fetchedAt,
      error: snapshot.todo.error,
    };
  }
  if (!previous.sources) return snapshot;
  for (const name of SOURCE_NAMES) {
    const current = snapshot.sources[name];
    const fallback = previous.sources[name];
    if (!current || current.ok || current.disabled || !fallback || !fallback.ok) continue;
    snapshot.sources[name] = {
      ...fallback,
      stale: true,
      lastAttemptAt: current.fetchedAt,
      error: current.error,
    };
  }
  return snapshot;
}

function validateSnapshot(snapshot) {
  if (
    !snapshot
    || snapshot.schemaVersion !== SNAPSHOT_SCHEMA_VERSION
    || typeof snapshot.updatedAt !== 'string'
    || !snapshot.sources
  ) {
    throw new Error('快照缺少 updatedAt 或 sources');
  }
  if (!snapshot.weather || typeof snapshot.weather.ok !== 'boolean') {
    throw new Error('快照缺少 weather');
  }
  if (snapshot.weather.ok) {
    if (
      snapshot.weather.tempC === null
      || snapshot.weather.tempC === undefined
      || snapshot.weather.tempC === ''
      || !Number.isFinite(Number(snapshot.weather.tempC))
      || typeof snapshot.weather.description !== 'string'
      || !snapshot.weather.description
      || typeof snapshot.weather.iconKey !== 'string'
      || !snapshot.weather.iconKey
      || (
        snapshot.weather.isDay !== null
        && snapshot.weather.isDay !== 0
        && snapshot.weather.isDay !== 1
      )
    ) {
      throw new Error('weather 当前天气格式不完整');
    }
    if (!Array.isArray(snapshot.weather.forecast) || snapshot.weather.forecast.length > 6) {
      throw new Error('weather.forecast 必须是最多 6 项的数组');
    }
    for (const item of snapshot.weather.forecast) {
      if (
        !item
        || typeof item.time !== 'string'
        || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(item.time)
        || (item.tempC !== null && !Number.isFinite(Number(item.tempC)))
        || typeof item.iconKey !== 'string'
        || !item.iconKey
        || (item.isDay !== null && item.isDay !== 0 && item.isDay !== 1)
        || (
          item.precipitationProbability !== null
          && (
            !Number.isFinite(Number(item.precipitationProbability))
            || Number(item.precipitationProbability) < 0
            || Number(item.precipitationProbability) > 100
          )
        )
      ) {
        throw new Error('weather.forecast 项格式不完整');
      }
    }
  }
  if (!snapshot.todo || typeof snapshot.todo.ok !== 'boolean' || !Array.isArray(snapshot.todo.items)) {
    throw new Error('快照缺少 todo');
  }
  for (const name of SOURCE_NAMES) {
    const source = snapshot.sources[name];
    if (!source || typeof source.ok !== 'boolean' || typeof source.label !== 'string') {
      throw new Error(`${name} 字段不完整`);
    }
    if (name === 'deepseek') {
      if (!Object.prototype.hasOwnProperty.call(source, 'balance')) {
        throw new Error('deepseek 缺少 balance');
      }
    } else if (!Array.isArray(source.windows)) {
      throw new Error(`${name} 缺少 windows`);
    }
  }
}

function writeSnapshot(snapshot, outputDir, keepLocalHistory) {
  const json = `${JSON.stringify(snapshot, null, 2)}\n`;
  const javascript = `window.DASH_DATA = ${JSON.stringify(snapshot, null, 2)};\n`;
  writeAtomic(path.join(outputDir, 'data.json'), json);
  writeAtomic(path.join(outputDir, 'data.js'), javascript);
  if (keepLocalHistory) {
    const historyDir = path.join(outputDir, 'history');
    fs.mkdirSync(historyDir, { recursive: true });
    fs.appendFileSync(
      path.join(historyDir, `${snapshot.updatedAt.slice(0, 10)}.jsonl`),
      `${JSON.stringify(snapshot)}\n`,
      'utf8',
    );
  }
}

async function main() {
  const demo = process.argv.includes('--demo');
  const config = demo
    ? { outputDir: path.join(ROOT, 'state'), keepLocalHistory: false }
    : loadConfig();
  const previous = demo ? null : previousSnapshot(config.outputDir);
  const fresh = demo ? demoSnapshot() : await realSnapshot(config);
  const snapshot = preserveLastKnownGood(fresh, previous);
  validateSnapshot(snapshot);
  writeSnapshot(snapshot, config.outputDir, config.keepLocalHistory === true);
  const status = SOURCE_NAMES
    .map((name) => `${name}:${snapshot.sources[name].ok ? 'ok' : snapshot.sources[name].disabled ? 'off' : 'fail'}`)
    .join(' ');
  process.stdout.write(`updated ${snapshot.updatedAt} ${status}\n`);
}

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`${safeError(error)}\n`);
    process.exitCode = 1;
  });
}

module.exports = {
  calendarSnapshot,
  demoSnapshot,
  preserveLastKnownGood,
  readQuote,
  readWeather,
  readRemoteWeather,
  buildHourlyForecast,
  normalizeHourlyForecast,
  weatherCodeDetails,
  validateSnapshot,
  writeSnapshot,
};
