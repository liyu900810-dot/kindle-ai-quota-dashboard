'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const installer = fs.readFileSync(
  path.join(root, 'scripts', 'install-update-task.ps1'),
  'utf8',
);
const launcher = fs.readFileSync(
  path.join(root, 'scripts', 'run-update-hidden.vbs'),
  'utf8',
);

test('Windows updater uses a truly hidden launcher', () => {
  assert.match(installer, /run-update-hidden\.vbs/);
  assert.match(installer, /System32\\wscript\.exe/);
  assert.doesNotMatch(installer, /New-ScheduledTaskAction -Execute \$powerShell/);
  assert.match(launcher, /shell\.Run\(command, 0, True\)/);
  assert.match(launcher, /update-dashboard\.ps1/);
});
