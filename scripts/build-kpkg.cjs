'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { ROOT } = require('../src/lib/config.cjs');

const sourceDir = path.join(ROOT, 'kindle', 'package');
const releaseDir = path.join(ROOT, 'release');
const stageDir = path.join(releaseDir, 'kindle-ai-quota-dashboard-0.1.0');
const output = path.join(releaseDir, 'kindle-ai-quota-dashboard_0.1.0_kindlehf-kindlepw2.kpkg');
const dashboardUrl = String(process.env.DASHBOARD_URL || '').trim().replace(/\/+$/, '');

function copyTree(source, destination) {
  fs.mkdirSync(destination, { recursive: true });
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const from = path.join(source, entry.name);
    const to = path.join(destination, entry.name);
    if (entry.isDirectory()) copyTree(from, to);
    else if (entry.isFile()) fs.copyFileSync(from, to);
  }
}

if (!/^https?:\/\/[^?#\s]+$/i.test(dashboardUrl)) {
  throw new Error('先设置 DASHBOARD_URL，且地址不能包含查询参数或片段。例如：https://example.github.io/project');
}

fs.rmSync(stageDir, { recursive: true, force: true });
fs.mkdirSync(releaseDir, { recursive: true });
copyTree(sourceDir, stageDir);

const launchPath = path.join(stageDir, 'launch.sh');
const launch = fs.readFileSync(launchPath, 'utf8').replace('__DASHBOARD_URL__', dashboardUrl);
fs.writeFileSync(launchPath, launch, 'utf8');

if (fs.existsSync(output)) fs.rmSync(output);
const command = process.platform === 'win32' ? 'tar.exe' : 'tar';
const result = spawnSync(command, ['-czf', output, '-C', stageDir, '.'], {
  encoding: 'utf8',
  windowsHide: true,
});
if (result.status !== 0) {
  throw new Error(result.stderr || result.stdout || `tar 退出码 ${result.status}`);
}
fs.rmSync(stageDir, { recursive: true, force: true });
process.stdout.write(`packaged ${output}\n`);
