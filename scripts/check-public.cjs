'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { ROOT } = require('../src/lib/config.cjs');

const forbiddenNames = [
  /^data\.(?:json|js)$/i,
  /\.jsonl$/i,
  /\.log$/i,
  /\.kpkg$/i,
  /^config\.json$/i,
];
const textExtensions = new Set([
  '', '.cjs', '.css', '.html', '.js', '.json', '.lua', '.md', '.ps1', '.sh',
  '.txt', '.yml', '.yaml',
]);
const contentPatterns = [
  { label: 'Windows 私人用户目录', regex: /[A-Za-z]:\\Users\\[^\\\r\n]+\\/i },
  { label: 'macOS/Linux 私人用户目录', regex: /\/(?:Users|home)\/[^/\r\n]+\//i },
  { label: '家庭局域网地址', regex: /\b192\.168\.\d{1,3}\.\d{1,3}\b/ },
  { label: 'MAC 地址', regex: /\b[0-9A-F]{2}(?::[0-9A-F]{2}){5}\b/i },
  {
    label: '疑似直接写入的秘密',
    regex: /\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)\b\s*[:=]\s*["'][A-Za-z0-9_./+=-]{12,}["']/i,
  },
];

function trackedFiles() {
  const output = execFileSync('git', ['ls-files', '-z'], {
    cwd: ROOT,
    encoding: 'utf8',
    windowsHide: true,
  });
  return output
    .split('\0')
    .filter(Boolean)
    .map((relative) => path.join(ROOT, relative))
    .filter((filePath) => fs.existsSync(filePath) && fs.statSync(filePath).isFile());
}

const problems = [];
for (const filePath of trackedFiles()) {
  const relative = path.relative(ROOT, filePath);
  if (relative === path.join('scripts', 'check-public.cjs')) continue;
  const inExamples = relative.startsWith(`examples${path.sep}`);
  const publishedRuntime = relative.startsWith(`dist${path.sep}`)
    && /^data\.(?:json|js)$/i.test(path.basename(filePath));
  if (
    !inExamples
    && !publishedRuntime
    && forbiddenNames.some((pattern) => pattern.test(path.basename(filePath)))
  ) {
    problems.push(`${relative}: 不应进入公开仓库的运行产物`);
    continue;
  }
  if (fs.statSync(filePath).size > 2 * 1024 * 1024) {
    problems.push(`${relative}: 文件超过 2 MiB，需人工确认`);
    continue;
  }
  if (!textExtensions.has(path.extname(filePath).toLowerCase())) continue;
  const content = fs.readFileSync(filePath, 'utf8');
  for (const item of contentPatterns) {
    if (item.regex.test(content)) problems.push(`${relative}: ${item.label}`);
  }
}

if (problems.length) {
  process.stderr.write(`公开前检查失败：\n- ${problems.join('\n- ')}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write('公开前检查通过：未发现已知私人路径、运行数据或疑似明文秘密。\n');
}
