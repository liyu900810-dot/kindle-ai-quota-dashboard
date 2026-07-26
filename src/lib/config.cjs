'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { readJson } = require('./common.cjs');

const ROOT = path.resolve(__dirname, '..', '..');

function resolveFromRoot(value, fallback) {
  const target = String(value || fallback || '').trim();
  return path.isAbsolute(target) ? target : path.resolve(ROOT, target);
}

function validateConfig(config) {
  if (!config || typeof config !== 'object' || Array.isArray(config)) {
    throw new Error('config.json 必须是 JSON 对象');
  }
  if (config.providers && typeof config.providers !== 'object') {
    throw new Error('config.providers 必须是对象');
  }
  const serialized = JSON.stringify(config);
  if (/"(?:apiKey|token|password|secret)"\s*:/i.test(serialized)) {
    throw new Error('config.json 不允许保存密钥值；只填写环境变量名称');
  }
}

function loadConfig(configPath = process.env.KINDLE_QUOTA_CONFIG) {
  const filePath = resolveFromRoot(configPath, 'config.json');
  if (!fs.existsSync(filePath)) {
    throw new Error(`没有找到配置文件：${filePath}。先复制 config.example.json 为 config.json`);
  }
  const config = readJson(filePath);
  validateConfig(config);
  return {
    ...config,
    rootDir: ROOT,
    configPath: filePath,
    outputDir: resolveFromRoot(config.outputDir, 'state'),
    quoteFile: config.quoteFile ? resolveFromRoot(config.quoteFile) : '',
    weatherFile: config.weatherFile ? resolveFromRoot(config.weatherFile) : '',
    providers: config.providers || {},
  };
}

module.exports = { ROOT, loadConfig, validateConfig };
