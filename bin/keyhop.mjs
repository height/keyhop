#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const app = join(root, 'dist', 'KeyHop.app');
const command = process.argv[2] ?? 'start';

if (command === 'help' || command === '--help' || command === '-h') {
  console.log(`KeyHop ${process.env.npm_package_version ?? '0.1.0'}

Usage:
  keyhop             Build if needed and show KeyHop in the menu bar
  keyhop start       Same as above
  keyhop --help      Show this help
  keyhop --version   Show the version`);
  process.exit(0);
}

if (command === '--version' || command === '-v') {
  console.log('0.1.0');
  process.exit(0);
}

if (command !== 'start') {
  console.error(`Unknown command: ${command}. Run keyhop --help.`);
  process.exit(2);
}

if (process.platform !== 'darwin') {
  console.error('KeyHop currently supports macOS only.');
  process.exit(1);
}

if (!existsSync(app)) {
  console.log('Building the KeyHop menu bar app for this Mac...');
  const build = spawnSync('/bin/bash', [join(root, 'scripts', 'build-macos.sh')], {
    stdio: 'inherit',
  });
  if (build.error) {
    console.error(build.error.message);
    process.exit(1);
  }
  if (build.status !== 0) process.exit(build.status ?? 1);
}

const opened = spawnSync('/usr/bin/open', ['-a', app], { stdio: 'inherit' });
if (opened.error) {
  console.error(opened.error.message);
  process.exit(1);
}
process.exit(opened.status ?? 1);
