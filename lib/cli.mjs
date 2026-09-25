import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, openSync, closeSync, readFileSync, realpathSync, statSync, renameSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(readFileSync(join(packageRoot, 'package.json'), 'utf8'));

export const HELP = `KeyHop ${manifest.version} — macOS 应用启动器

Usage:
  keyhop                    启动菜单栏；已有实例时打开设置
  keyhop start              同上
  keyhop status             查看菜单栏、代理检查及最近启动记录
  keyhop status --json
  keyhop quit               正常退出菜单栏（不会退出目标 App）
  keyhop --help
  keyhop --version

代理默认关闭，可在设置中开启。
设置与状态保存在 ~/Library/Application Support/KeyHop。
可使用 KEYHOP_HOME 指定独立配置目录。
首次开发使用前运行 npm run build:mac；CLI 不会自动编译。
`;

export function parseArguments(args) {
  const command = args[0] ?? 'start';
  if (['help', '--help', '-h'].includes(command) && args.length === 1) return { command: 'help' };
  if (['version', '--version', '-v'].includes(command) && args.length === 1) return { command: 'version' };
  if (command === 'status' && (args.length === 1 || (args.length === 2 && args[1] === '--json'))) {
    return { command, json: args[1] === '--json' };
  }
  if (['start', 'quit'].includes(command) && args.length <= 1) return { command };
  throw new Error(`无法识别的命令或参数：${args.join(' ')}。运行 keyhop --help 查看用法。`);
}

function canonicalPath(path) {
  if (typeof path !== 'string' || !path) return null;
  try { return realpathSync(path); } catch { return resolve(path); }
}

function readJSON(path, warnings) {
  try {
    const value = JSON.parse(readFileSync(path, 'utf8'));
    if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('expected a JSON object');
    return value;
  } catch (error) {
    if (error.code !== 'ENOENT') warnings.push(`${path}: ${error.message}`);
    return null;
  }
}

export function readProcessCommand(pid) {
  const result = spawnSync('/bin/ps', ['-ww', '-p', String(pid), '-o', 'comm='], { encoding: 'utf8' });
  if (result.error || (result.status !== 0 && result.stderr?.trim())) {
    throw new Error(`无法查询菜单栏进程：${result.error?.message ?? result.stderr.trim()}`);
  }
  return result.status === 0 ? result.stdout.trim() : null;
}

function trustedLauncherPath(candidate, expected) {
  if (candidate === expected) return true;
  // A package can move (for example local checkout → npm global install) while
  // its already-running app still owns this configuration directory's lock.
  const macos = dirname(candidate);
  const contents = dirname(macos);
  if (basename(candidate) !== 'KeyHopMenu' || basename(macos) !== 'MacOS' || basename(contents) !== 'Contents' || basename(dirname(contents)) !== 'KeyHop.app') return false;
  try {
    const plist = readFileSync(join(contents, 'Info.plist'), 'utf8');
    return /<key>CFBundleIdentifier<\/key>\s*<string>com\.height\.keyhop<\/string>/.test(plist);
  } catch { return false; }
}

export function isLauncherRunning(status, executablePath, getProcessCommand = readProcessCommand) {
  const pid = status?.launcherPID;
  if (!Number.isSafeInteger(pid) || pid <= 1) return false;
  const expected = canonicalPath(executablePath);
  const candidate = canonicalPath(status.executablePath);
  if (!candidate || !trustedLauncherPath(candidate, expected)) return false;
  return canonicalPath(getProcessCommand(pid)) === candidate;
}

function sameEndpoint(proxy, config) {
  const endpoint = config?.proxy;
  return endpoint && proxy?.host === endpoint.host && proxy?.port === endpoint.port && proxy?.protocol === endpoint.protocol;
}

export function collectStatus({ home, executablePath, getProcessCommand = readProcessCommand, now = Date.now() }) {
  const warnings = [];
  const config = readJSON(join(home, 'config.json'), warnings);
  const native = readJSON(join(home, 'status.json'), warnings);
  let running;
  try { running = isLauncherRunning(native, executablePath, getProcessCommand); }
  catch (error) { running = null; warnings.push(error.message); }
  const age = now - Date.parse(native?.proxy?.checkedAt);
  const proxyEnabled = config?.proxy?.enabled === true;
  const current = running && proxyEnabled && sameEndpoint(native?.proxy, config) && age >= 0 && age <= 60_000;
  const proxy = proxyEnabled && native?.proxy ? { ...native.proxy, freshness: current ? 'current' : 'stale' } : null;
  return {
    version: 1,
    running,
    pid: running ? native.launcherPID : null,
    executablePath: running ? native.executablePath : null,
    home,
    config,
    proxyEnabled,
    proxy,
    lastUpdatedAt: native?.updatedAt ?? null,
    launches: Array.isArray(native?.launches) ? native.launches : [],
    trafficVerified: false,
    warnings,
  };
}

export function formatStatus(status) {
  const lines = [`KeyHop 菜单栏：${status.running === null ? '无法确认（进程查询失败）' : status.running ? `运行中（PID ${status.pid}）` : '未运行'}`, `配置目录：${status.home}`];
  const endpoint = status.config?.proxy;
  const proxyEnabled = endpoint?.enabled === true;
  if (!proxyEnabled) lines.push('代理：未开启');
  else lines.push(`代理配置：${endpoint.protocol}://${endpoint.host}:${endpoint.port}`);
  if (proxyEnabled && status.proxy) {
    lines.push(`代理服务：${status.proxy.freshness === 'current' ? (status.proxy.available ? '可用' : '不可用') : '当前状态未知（上次检查已过期）'}`);
    lines.push(`上次协议检查：${status.proxy.available ? '可用' : '不可用'} · ${status.proxy.checkedAt ?? '未知时间'}`);
    if (status.proxy.message) lines.push(`  ${status.proxy.message}`);
  } else if (proxyEnabled) lines.push('代理服务：尚未检查');
  const states = { launched: '已按配置启动', activated: '已切到前台', requested: '已请求启动', alreadyRunning: '已在运行，需要先退出', proxyUnavailable: '代理不可用，未启动', failed: '启动失败', exited: '该次启动已结束' };
  const profiles = Array.isArray(status.config?.profiles) ? status.config.profiles : [];
  for (const record of status.launches) {
    const profile = profiles.find((entry) => entry.id === record.profileID);
    lines.push(`最近启动记录 · ${profile?.name ?? record.profileID}：${states[record.state] ?? record.state} · ${record.launchedAt ?? ''}`);
    if (record.message) lines.push(`  ${record.message}`);
  }
  if (proxyEnabled || status.launches.some((record) => record.proxy)) {
    lines.push('目标 App 流量：未验证（启动记录不代表全部请求经过代理）');
  }
  for (const warning of status.warnings) lines.push(`读取警告：${warning}`);
  return lines.join('\n');
}

function spawnLauncher(executablePath, home, environment) {
  mkdirSync(home, { recursive: true, mode: 0o700 });
  const logfile = join(home, 'launcher.log');
  try { if (statSync(logfile).size > 1_000_000) renameSync(logfile, `${logfile}.previous`); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const log = openSync(logfile, 'a', 0o600);
  const state = { error: null, exitCode: null };
  let child;
  try {
    child = spawn(executablePath, [], { detached: true, stdio: ['ignore', log, log], env: { ...environment, KEYHOP_HOME: home } });
  } finally { closeSync(log); }
  child.once('error', (error) => { state.error = error; });
  child.once('exit', (code) => { state.exitCode = code; });
  child.unref();
  return state;
}

function validateBundle(root, architecture) {
  const executable = join(root, 'dist', 'KeyHop.app', 'Contents', 'MacOS', 'KeyHopMenu');
  if (!existsSync(executable)) throw new Error('未找到已打包的菜单栏 App。源码开发请先运行 npm run build:mac；已安装包请重新安装完整的 macOS 构建。');
  const warnings = [];
  const buildInfo = readJSON(join(root, 'dist', 'build-info.json'), warnings);
  if (!buildInfo || !Array.isArray(buildInfo.architectures)) throw new Error('菜单栏 App 缺少构建架构信息；请运行 npm run build:mac 或重新安装完整包。');
  const nativeArchitecture = architecture === 'x64' ? 'x86_64' : architecture;
  if (!buildInfo.architectures.includes(nativeArchitecture)) throw new Error(`菜单栏 App 不支持当前架构 ${architecture}（构建架构：${buildInfo.architectures.join(', ')}）。`);
}

export async function runCLI(args, overrides = {}) {
  const options = {
    root: packageRoot,
    platform: process.platform,
    architecture: process.arch,
    environment: process.env,
    home: resolve(process.env.KEYHOP_HOME || join(homedir(), 'Library', 'Application Support', 'KeyHop')),
    out: (value) => console.log(value),
    err: (value) => console.error(value),
    getProcessCommand: readProcessCommand,
    signal: (pid, signal) => process.kill(pid, signal),
    spawnLauncher,
    validateBundle,
    sleep,
    attempts: 40,
    ...overrides,
  };
  let parsed;
  try { parsed = parseArguments(args); } catch (error) { options.err(error.message); return 2; }
  if (parsed.command === 'help') { options.out(HELP); return 0; }
  if (parsed.command === 'version') { options.out(manifest.version); return 0; }
  if (options.platform !== 'darwin') { options.err('KeyHop 目前仅支持 macOS 13 或更高版本。'); return 1; }
  const executablePath = join(options.root, 'dist', 'KeyHop.app', 'Contents', 'MacOS', 'KeyHopMenu');
  const snapshot = () => collectStatus({ home: options.home, executablePath, getProcessCommand: options.getProcessCommand });
  try {
    const initial = snapshot();
    if (parsed.command === 'status') { options.out(parsed.json ? JSON.stringify(initial, null, 2) : formatStatus(initial)); return 0; }
    if (initial.running === null) throw new Error('无法确认已有菜单栏进程，已停止操作。请先解决进程查询权限问题，再重试。');
    if (parsed.command === 'quit') {
      if (!initial.running) { options.out('KeyHop 菜单栏未运行。'); return 0; }
      // Validate immediately before signalling; never trust a persisted PID alone.
      const latest = snapshot();
      if (latest.running === false) { options.out('KeyHop 菜单栏已退出。'); return 0; }
      if (latest.running !== true || latest.pid !== initial.pid || latest.executablePath !== initial.executablePath) throw new Error('菜单栏进程在检查期间发生变化，请重试。');
      options.signal(initial.pid, 'SIGTERM');
      for (let attempt = 0; attempt < options.attempts; attempt++) {
        await options.sleep(125);
        const state = snapshot();
        if (state.running === false) { options.out('KeyHop 菜单栏已退出；目标 App 保持运行。'); return 0; }
        if (state.running === null) throw new Error('退出请求已发送，但无法查询进程确认结果。请检查菜单栏。');
      }
      throw new Error('菜单栏尚未完成退出；请从菜单栏选择退出。没有强制终止任何 App。');
    }
    if (initial.running) {
      const latest = snapshot();
      if (latest.running !== true || latest.pid !== initial.pid || latest.executablePath !== initial.executablePath) throw new Error('菜单栏进程在检查期间发生变化，请重试。');
      options.signal(initial.pid, 'SIGUSR1');
      options.out('已激活正在运行的 KeyHop 菜单栏。');
      return 0;
    }
    options.validateBundle(options.root, options.architecture);
    const child = options.spawnLauncher(executablePath, options.home, options.environment);
    for (let attempt = 0; attempt < options.attempts; attempt++) {
      await options.sleep(125);
      const state = snapshot();
      if (state.running) { options.out('KeyHop 菜单栏已启动。点击菜单栏图标添加 App 和快捷键。'); return 0; }
      if (child.error) throw child.error;
    }
    throw new Error(`菜单栏未在 5 秒内就绪${child.exitCode === null ? '' : `（退出码 ${child.exitCode}）`}。日志：${join(options.home, 'launcher.log')}`);
  } catch (error) { options.err(error.message); return 1; }
}
