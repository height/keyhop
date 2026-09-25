import { readFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const app = join(root, 'dist', 'KeyHop.app');
const binary = join(app, 'Contents', 'MacOS', 'KeyHopMenu');
try {
  if (process.platform !== 'darwin') throw new Error('The macOS package must be prepared on macOS.');
  if (!existsSync(binary)) throw new Error('Missing bundled app. Run npm run build:mac before npm pack.');
  const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  const info = JSON.parse(readFileSync(join(root, 'dist', 'build-info.json'), 'utf8'));
  if (info.version !== manifest.version) throw new Error('Bundle version does not match package.json. Rebuild the app.');
  const inspected = spawnSync('/usr/bin/lipo', ['-archs', binary], { encoding: 'utf8' });
  if (inspected.status !== 0) throw new Error(inspected.stderr || 'Cannot inspect app architecture.');
  const actual = inspected.stdout.trim().split(/\s+/).sort();
  if (JSON.stringify(actual) !== JSON.stringify(['arm64', 'x86_64'])) throw new Error('npm package advertises both Mac architectures. Run npm run build:mac (without --native) before packing.');
  if (JSON.stringify([...info.architectures].sort()) !== JSON.stringify(actual)) throw new Error('Build metadata does not match app architectures.');
  const signed = spawnSync('/usr/bin/codesign', ['--verify', '--strict', app], { encoding: 'utf8' });
  if (signed.status !== 0) throw new Error(signed.stderr || 'Invalid app signature.');
  const bundleVersion = spawnSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleShortVersionString', join(app, 'Contents', 'Info.plist')], { encoding: 'utf8' });
  if (bundleVersion.status !== 0 || bundleVersion.stdout.trim() !== manifest.version) throw new Error('Info.plist version does not match package.json.');
  console.log(`Verified KeyHop ${manifest.version}: universal macOS app, local ad-hoc signing. No publishing performed.`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
