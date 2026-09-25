import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { collectStatus, formatStatus, isLauncherRunning, parseArguments, runCLI } from '../lib/cli.mjs';

const endpoint = { enabled: true, protocol: 'http', host: '127.0.0.1', port: 7897 };

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'keyhop-cli-'));
  const home = join(root, 'config');
  mkdirSync(home);
  const executablePath = join(root, 'dist', 'KeyHop.app', 'Contents', 'MacOS', 'KeyHopMenu');
  const out = [];
  const err = [];
  const signals = [];
  const options = {
    root, home, platform: 'darwin', architecture: 'arm64',
    out: (line) => out.push(line), err: (line) => err.push(line),
    getProcessCommand: () => null,
    signal: (...args) => signals.push(args),
    sleep: async () => {}, attempts: 2,
    spawnLauncher: () => { throw new Error('unexpected launch'); },
    validateBundle: () => { throw new Error('unexpected bundle validation or build'); },
  };
  function write(name, data) { writeFileSync(join(home, name), JSON.stringify(data)); }
  function native(extra = {}) {
    const status = {
      version: 1, launcherPID: 12345, executablePath,
      updatedAt: new Date().toISOString(),
      proxy: { ...endpoint, available: true, checkedAt: new Date().toISOString(), message: 'HTTP CONNECT accepted' },
      launches: [], ...extra,
    };
    write('status.json', status);
    return status;
  }
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return { root, home, executablePath, out, err, signals, options, write, native };
}

test('CLI command grammar rejects trailing and unknown arguments', () => {
  assert.deepEqual(parseArguments([]), { command: 'start' });
  assert.deepEqual(parseArguments(['status', '--json']), { command: 'status', json: true });
  for (const args of [['unknown'], ['status', '--json', 'x'], ['start', '--json'], ['quit', 'x'], ['--help', 'x'], ['--json']]) {
    assert.throws(() => parseArguments(args), /无法识别/);
  }
});

test('help and version work on unsupported platforms without inspecting bundle', async (t) => {
  const f = fixture(t);
  assert.equal(await runCLI(['--help'], { ...f.options, platform: 'linux' }), 0);
  assert.match(f.out[0], /proxy-launcher status --json/);
  assert.equal(await runCLI(['--version'], { ...f.options, platform: 'win32' }), 0);
  assert.match(f.out[1], /^\d+\.\d+\.\d+/);
});

test('unsupported platform and unknown arguments return actionable errors', async (t) => {
  const f = fixture(t);
  assert.equal(await runCLI([], { ...f.options, platform: 'linux' }), 1);
  assert.match(f.err[0], /macOS/);
  assert.equal(await runCLI(['start', '--bad'], f.options), 2);
});

test('status and quit require no installed bundle, no build, no process launch', async (t) => {
  const f = fixture(t);
  assert.equal(await runCLI(['status', '--json'], f.options), 0);
  assert.equal(JSON.parse(f.out[0]).running, false);
  assert.equal(JSON.parse(f.out[0]).trafficVerified, false);
  assert.equal(await runCLI(['quit'], f.options), 0);
  assert.deepEqual(f.signals, []);
  assert.equal(existsSync(join(f.home, 'config.json')), false);
});

test('missing home status is read only', async (t) => {
  const f = fixture(t);
  const absent = join(f.root, 'absent');
  assert.equal(await runCLI(['status'], { ...f.options, home: absent }), 0);
  assert.equal(existsSync(absent), false);
});

test('persisted PID is accepted only with the expected executable and live process identity', (t) => {
  const f = fixture(t);
  const native = f.native();
  assert.equal(isLauncherRunning(native, f.executablePath, () => f.executablePath), true);
  assert.equal(isLauncherRunning(native, f.executablePath, () => '/bin/sleep'), false);
  assert.equal(isLauncherRunning(native, f.executablePath, () => null), false);
  assert.equal(isLauncherRunning({ ...native, executablePath: '/bin/sleep' }, f.executablePath, () => '/bin/sleep'), false);
  for (const pid of [0, 1, -1, '12345', 1.5, null]) assert.equal(isLauncherRunning({ ...native, launcherPID: pid }, f.executablePath, () => f.executablePath), false);
});

test('a live menu bar from a previous package location remains manageable after relocation', async (t) => {
  const f = fixture(t);
  const contents = join(f.root, 'old-install', 'KeyHop.app', 'Contents');
  const oldExecutable = join(contents, 'MacOS', 'KeyHopMenu');
  mkdirSync(join(contents, 'MacOS'), { recursive: true });
  writeFileSync(oldExecutable, 'placeholder');
  writeFileSync(join(contents, 'Info.plist'), '<plist><dict><key>CFBundleIdentifier</key><string>com.height.keyhop</string></dict></plist>');
  f.native({ executablePath: oldExecutable });
  assert.equal(await runCLI([], { ...f.options, getProcessCommand: () => oldExecutable }), 0);
  assert.deepEqual(f.signals, [[12345, 'SIGUSR1']]);
  writeFileSync(join(contents, 'Info.plist'), '<key>CFBundleIdentifier</key><string>com.unrelated.app</string>');
  assert.equal(isLauncherRunning({ launcherPID: 12345, executablePath: oldExecutable }, f.executablePath, () => oldExecutable), false);
});

test('denied process inspection is unknown and prevents duplicate starts or signals', async (t) => {
  const f = fixture(t);
  f.native();
  const options = { ...f.options, getProcessCommand: () => { throw new Error('Operation not permitted'); } };
  assert.equal(await runCLI(['status', '--json'], options), 0);
  assert.equal(JSON.parse(f.out[0]).running, null);
  assert.match(formatStatus(JSON.parse(f.out[0])), /无法确认/);
  assert.equal(await runCLI([], options), 1);
  assert.equal(await runCLI(['quit'], options), 1);
  assert.deepEqual(f.signals, []);
});

for (const command of ['start', 'quit']) {
  test(`${command} never signals an old PID if status changes during final verification`, async (t) => {
    const f = fixture(t);
    f.native();
    let lookups = 0;
    assert.equal(await runCLI([command], {
      ...f.options,
      getProcessCommand: () => {
        if (++lookups === 1) f.native({ launcherPID: 54321 });
        return f.executablePath;
      },
    }), 1);
    assert.deepEqual(f.signals, []);
    assert.match(f.err[0], /进程在检查期间发生变化/);
  });
}

test('stale status never signals an unrelated process or claims proxy is currently available', async (t) => {
  const f = fixture(t);
  f.native();
  f.write('config.json', { proxy: endpoint });
  const options = { ...f.options, getProcessCommand: () => '/bin/sleep' };
  assert.equal(await runCLI(['quit'], options), 0);
  assert.deepEqual(f.signals, []);
  assert.equal(await runCLI(['status', '--json'], options), 0);
  const status = JSON.parse(f.out.at(-1));
  assert.equal(status.running, false);
  assert.equal(status.proxy.freshness, 'stale');
  assert.match(formatStatus(status), /当前状态未知/);
});

test('proxy checks expire and a protocol change invalidates the stored result', (t) => {
  const f = fixture(t);
  f.native();
  f.write('config.json', { proxy: endpoint });
  const options = { ...f, getProcessCommand: () => f.executablePath };
  assert.equal(collectStatus(options).proxy.freshness, 'current');
  assert.equal(collectStatus({ ...options, now: Date.now() + 61_000 }).proxy.freshness, 'stale');
  f.write('config.json', { proxy: { ...endpoint, protocol: 'socks5' } });
  assert.equal(collectStatus(options).proxy.freshness, 'stale');
});

test('disabled and legacy proxy settings hide a previously successful check', (t) => {
  const f = fixture(t);
  f.native();
  const { enabled, ...legacyEndpoint } = endpoint;
  for (const proxy of [undefined, legacyEndpoint, { ...endpoint, enabled: false }, { ...endpoint, enabled: 'true' }]) {
    f.write('config.json', { proxy });
    const status = collectStatus({ ...f, getProcessCommand: () => f.executablePath });
    assert.equal(status.proxyEnabled, false);
    assert.equal(status.proxy, null);
    const message = formatStatus(status);
    assert.match(message, /代理：未开启/);
    assert.doesNotMatch(message, /代理服务：|上次协议检查：|HTTP CONNECT accepted/);
  }
  f.write('config.json', { proxy: endpoint });
  const enabledStatus = collectStatus({ ...f, getProcessCommand: () => f.executablePath });
  assert.equal(enabledStatus.proxyEnabled, true);
  assert.equal(enabledStatus.proxy.freshness, 'current');
});

test('disabling proxy keeps the original launch snapshot without calling its check current', (t) => {
  const f = fixture(t);
  const launch = {
    profileID: 'codex', state: 'launched', launchedAt: new Date().toISOString(),
    proxy: { ...endpoint, available: true, checkedAt: new Date().toISOString() },
    message: '已传入 HTTP 代理配置；此进程仍在运行',
  };
  f.native({ launches: [launch] });
  f.write('config.json', { proxy: { ...endpoint, enabled: false }, profiles: [{ id: 'codex', name: 'Codex' }] });
  const status = collectStatus({ ...f, getProcessCommand: () => f.executablePath });
  assert.deepEqual(status.launches, [launch]);
  assert.equal(status.proxy, null);
  assert.match(formatStatus(status), /代理：未开启/);
  assert.match(formatStatus(status), /此进程仍在运行/);
  assert.match(formatStatus(status), /目标 App 流量：未验证/);
});

test('an unavailable proxy is not reported successful even while menu bar is running', (t) => {
  const f = fixture(t);
  f.native({ proxy: { ...endpoint, available: false, checkedAt: new Date().toISOString(), message: 'connection refused' } });
  f.write('config.json', { proxy: endpoint });
  const status = collectStatus({ ...f, getProcessCommand: () => f.executablePath });
  assert.match(formatStatus(status), /代理服务：不可用/);
  assert.equal(status.trafficVerified, false);
});

test('repeated start activates one verified instance without spawning or checking bundle', async (t) => {
  const f = fixture(t);
  f.native();
  assert.equal(await runCLI([], { ...f.options, getProcessCommand: () => f.executablePath }), 0);
  assert.deepEqual(f.signals, [[12345, 'SIGUSR1']]);
});

test('quit gracefully signals only launcher then observes shutdown', async (t) => {
  const f = fixture(t);
  f.native();
  let running = true;
  assert.equal(await runCLI(['quit'], {
    ...f.options,
    getProcessCommand: () => running ? f.executablePath : null,
    signal: (...args) => { f.signals.push(args); running = false; },
  }), 0);
  assert.deepEqual(f.signals, [[12345, 'SIGTERM']]);
  assert.match(f.out[0], /目标 App 保持运行/);
});

test('quit timeout does not escalate to forced termination', async (t) => {
  const f = fixture(t);
  f.native();
  assert.equal(await runCLI(['quit'], { ...f.options, getProcessCommand: () => f.executablePath }), 1);
  assert.deepEqual(f.signals, [[12345, 'SIGTERM']]);
  assert.match(f.err[0], /没有强制终止/);
});

test('start waits for a verified ready process and propagates isolated home', async (t) => {
  const f = fixture(t);
  let running = false;
  assert.equal(await runCLI(['start'], {
    ...f.options,
    environment: { PATH: '/usr/bin' },
    getProcessCommand: () => running ? f.executablePath : null,
    validateBundle: () => {},
    spawnLauncher: (path, home, environment) => {
      assert.equal(path, f.executablePath);
      assert.equal(home, f.home);
      assert.equal(environment.PATH, '/usr/bin');
      f.native();
      running = true;
      return { error: null, exitCode: null };
    },
  }), 0);
  assert.match(f.out[0], /已启动/);
});

test('a racing duplicate child can exit once the other launcher publishes ready status', async (t) => {
  const f = fixture(t);
  let running = false;
  assert.equal(await runCLI([], {
    ...f.options,
    getProcessCommand: () => running ? f.executablePath : null,
    validateBundle: () => {},
    spawnLauncher: () => ({ error: null, exitCode: 0 }),
    sleep: async () => { f.native(); running = true; },
  }), 0);
});

test('missing and incompatible builds fail without compiling or spawning', async (t) => {
  const f = fixture(t);
  const { validateBundle, ...options } = f.options;
  assert.equal(await runCLI([], options), 1);
  assert.match(f.err[0], /npm run build:mac/);
  mkdirSync(join(f.root, 'dist', 'KeyHop.app', 'Contents', 'MacOS'), { recursive: true });
  writeFileSync(f.executablePath, 'placeholder');
  writeFileSync(join(f.root, 'dist', 'build-info.json'), JSON.stringify({ architectures: ['x86_64'] }));
  assert.equal(await runCLI([], options), 1);
  assert.match(f.err[1], /不支持当前架构 arm64/);
});

test('invalid JSON is reported without overwriting user data', async (t) => {
  const f = fixture(t);
  writeFileSync(join(f.home, 'config.json'), '{broken');
  writeFileSync(join(f.home, 'status.json'), 'null');
  assert.equal(await runCLI(['status', '--json'], f.options), 0);
  const result = JSON.parse(f.out[0]);
  assert.equal(result.warnings.length, 2);
  assert.equal(result.running, false);
});

test('launch history is separate from target traffic verification', (t) => {
  const f = fixture(t);
  f.write('config.json', { proxy: endpoint, profiles: [{ id: 'codex', name: 'Codex' }] });
  f.native({ launches: [{ profileID: 'codex', state: 'launched', launchedAt: new Date().toISOString(), message: 'started' }] });
  const message = formatStatus(collectStatus({ ...f, getProcessCommand: () => f.executablePath }));
  assert.match(message, /最近启动记录 · Codex：已按配置启动/);
  assert.match(message, /目标 App 流量：未验证/);
});
