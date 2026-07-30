'use strict';

const { isoBeijing, readJson, safeError } = require('../lib/common.cjs');

const NOTION_VERSION = '2026-03-11';
const DEFAULT_DONE_VALUES = ['完成', '已完成', 'Done', 'Completed', 'Archived'];

function plainText(parts) {
  if (!Array.isArray(parts)) return '';
  return parts.map((part) => part?.plain_text || part?.text?.content || '').join('').trim();
}

function propertyValue(property) {
  if (!property || typeof property !== 'object') return '';
  if (property.type === 'title') return plainText(property.title);
  if (property.type === 'rich_text') return plainText(property.rich_text);
  if (property.type === 'status') return property.status?.name || '';
  if (property.type === 'select') return property.select?.name || '';
  if (property.type === 'date') return property.date?.start || '';
  if (property.type === 'checkbox') return property.checkbox === true;
  if (property.type === 'formula') {
    const value = property.formula || {};
    return value.string ?? value.number ?? value.boolean ?? value.date?.start ?? '';
  }
  return '';
}

function dueLabel(value, now = new Date()) {
  if (!value) return '';
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return String(value).slice(0, 12);
  const inBeijing = (input) => {
    const shifted = new Date(input.getTime() + 8 * 60 * 60 * 1000);
    return shifted.toISOString().slice(0, 10);
  };
  const today = inBeijing(now);
  const tomorrow = inBeijing(new Date(now.getTime() + 24 * 60 * 60 * 1000));
  const target = inBeijing(date);
  if (target < today) return '逾期';
  if (target === today) return '今天';
  if (target === tomorrow) return '明天';
  return target.slice(5);
}

function normalizeItem(value, now = new Date()) {
  const title = String(value?.title || value?.name || '').trim().slice(0, 80);
  if (!title) return null;
  const dueAt = value?.dueAt || value?.due || null;
  return {
    title,
    dueAt: dueAt ? String(dueAt).slice(0, 40) : null,
    dueLabel: String(value?.dueLabel || dueLabel(dueAt, now)).trim().slice(0, 12),
    priority: String(value?.priority || '').trim().slice(0, 16),
  };
}

function success(items, source, totalOpen = items.length, fetchedAt = isoBeijing()) {
  return {
    ok: true,
    source,
    items,
    totalOpen,
    fetchedAt,
    error: null,
  };
}

function failure(source, error, fetchedAt = isoBeijing()) {
  return {
    ok: false,
    source,
    items: [],
    totalOpen: 0,
    fetchedAt,
    error: safeError(error),
  };
}

function readTodoFile(filePath, maxItems = 5, now = new Date()) {
  const fetchedAt = isoBeijing();
  if (!filePath) return failure('file', '未配置待办文件', fetchedAt);
  try {
    const value = readJson(filePath);
    const rawItems = Array.isArray(value) ? value : value?.items;
    if (!Array.isArray(rawItems)) throw new Error('待办文件缺少 items 数组');
    const openItems = rawItems
      .filter((item) => item && item.done !== true && item.completed !== true)
      .map((item) => normalizeItem(item, now))
      .filter(Boolean);
    return success(openItems.slice(0, maxItems), 'file', openItems.length, fetchedAt);
  } catch (error) {
    return failure('file', error, fetchedAt);
  }
}

function notionPageToItem(page, config, now = new Date()) {
  const properties = page?.properties || {};
  const title = propertyValue(properties[config.titleProperty || '任务']);
  const dueAt = propertyValue(properties[config.dueProperty || '截止日期']);
  const priority = propertyValue(properties[config.priorityProperty || '优先级']);
  return normalizeItem({ title, dueAt, priority }, now);
}

function notionPageIsDone(page, config) {
  const property = page?.properties?.[config.statusProperty || '状态'];
  const value = propertyValue(property);
  if (typeof value === 'boolean') return value;
  const doneValues = Array.isArray(config.doneValues) && config.doneValues.length
    ? config.doneValues
    : DEFAULT_DONE_VALUES;
  return doneValues.some((item) => String(item).toLowerCase() === String(value).toLowerCase());
}

function notionPageIsVisible(page, config) {
  const propertyName = config.visibleProperty || 'Kindle显示';
  const property = page?.properties?.[propertyName];
  return propertyValue(property) === true;
}

async function readNotionTodo(config = {}, maxItems = 5, now = new Date()) {
  const fetchedAt = isoBeijing();
  const tokenEnv = String(config.tokenEnv || 'NOTION_API_KEY');
  const dataSourceIdEnv = String(config.dataSourceIdEnv || 'NOTION_DATA_SOURCE_ID');
  const token = process.env[tokenEnv];
  const dataSourceId = String(config.dataSourceId || process.env[dataSourceIdEnv] || '').trim();
  if (!token) return failure('notion', `环境变量 ${tokenEnv} 未配置`, fetchedAt);
  if (!dataSourceId) return failure('notion', `未配置 Notion data source ID（${dataSourceIdEnv}）`, fetchedAt);

  try {
    const response = await fetch(
      `https://api.notion.com/v1/data_sources/${encodeURIComponent(dataSourceId)}/query`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
          'Notion-Version': NOTION_VERSION,
        },
        body: JSON.stringify({ page_size: 50 }),
        signal: AbortSignal.timeout(15000),
      },
    );
    const payload = await response.json().catch(() => null);
    if (!response.ok) {
      throw new Error(`Notion 请求失败（HTTP ${response.status}）：${payload?.message || '未知错误'}`);
    }
    const openItems = (payload?.results || [])
      .filter((page) => (
        page?.object === 'page'
        && notionPageIsVisible(page, config)
        && !notionPageIsDone(page, config)
      ))
      .map((page) => notionPageToItem(page, config, now))
      .filter(Boolean)
      .sort((left, right) => {
        if (!left.dueAt && !right.dueAt) return 0;
        if (!left.dueAt) return 1;
        if (!right.dueAt) return -1;
        return String(left.dueAt).localeCompare(String(right.dueAt));
      });
    return success(openItems.slice(0, maxItems), 'notion', openItems.length, fetchedAt);
  } catch (error) {
    return failure('notion', error, fetchedAt);
  }
}

async function collectTodo(config = {}) {
  const maxItems = Math.max(1, Math.min(5, Number(config.maxItems || 5)));
  if (config.enabled === false || !config.provider) {
    return {
      ...failure('disabled', '待办数据源未启用'),
      disabled: true,
    };
  }
  if (config.provider === 'notion') {
    const notion = await readNotionTodo(config.notion || {}, maxItems);
    if (notion.ok || !config.fallbackFile) return notion;
    const fallback = readTodoFile(config.fallbackFile, maxItems);
    if (!fallback.ok) return notion;
    return {
      ...fallback,
      source: 'notion-fallback',
      stale: true,
      error: notion.error,
      lastAttemptAt: notion.fetchedAt,
    };
  }
  return readTodoFile(config.file, maxItems);
}

module.exports = {
  collectTodo,
  dueLabel,
  normalizeItem,
  notionPageIsDone,
  notionPageIsVisible,
  notionPageToItem,
  propertyValue,
  readNotionTodo,
  readTodoFile,
};
