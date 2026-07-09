#!/usr/bin/env node
/*
 Cross-platform read-only preflight for Typeless Switchboard / typeless-toolkit compatibility.
 It does not delete credentials, does not remove files, and does not launch Typeless.
*/
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = os.homedir();
const platform = process.platform;
const APPDATA = process.env.APPDATA || path.join(HOME, 'AppData', 'Roaming');
const LOCALAPPDATA = process.env.LOCALAPPDATA || path.join(HOME, 'AppData', 'Local');
const APPSUPPORT = path.join(HOME, 'Library', 'Application Support');

function expandHome(value) {
  if (!value) return value;
  if (value === '~') return HOME;
  if (value.startsWith('~/')) return path.join(HOME, value.slice(2));
  return value;
}

function firstExisting(candidates) {
  for (const candidate of candidates.map(expandHome)) {
    try { if (fs.existsSync(candidate)) return candidate; } catch (_) {}
  }
  return expandHome(candidates[0] || '');
}

function profileFor(currentPlatform) {
  if (currentPlatform === 'darwin') {
    return {
      platform: 'macos',
      supportLevel: 'productionVerified',
      processName: 'Typeless',
      executableCandidates: [
        '/Applications/Typeless.app/Contents/MacOS/Typeless',
        '~/Applications/Typeless.app/Contents/MacOS/Typeless',
      ],
      userDataDirectoryCandidates: [
        path.join(APPSUPPORT, 'Typeless.exe'),
        path.join(APPSUPPORT, 'Typeless'),
      ],
      deviceCacheDirectoryCandidates: [
        path.join(APPSUPPORT, 'now.typeless.desktop'),
        path.join(APPSUPPORT, 'Typeless', 'Cache'),
        path.join(APPSUPPORT, 'Typeless.exe', 'Cache'),
        path.join(APPSUPPORT, 'Typeless'),
        path.join(APPSUPPORT, 'Typeless.exe'),
      ],
      credentialTargets: [
        'now.typeless.desktop.deviceIdentifier / now.typeless.desktop.security.auth_key',
        'Typeless.deviceIdentifier',
      ],
      deleteCredentialCommand: 'security delete-generic-password -s <service> [-a <account>] ; security delete-generic-password -l <label>',
      openProtocolCommand: '/usr/bin/open typeless://...',
    };
  }
  if (currentPlatform === 'win32') {
    return {
      platform: 'windows',
      supportLevel: 'toolkitCompatible',
      processName: 'Typeless.exe',
      executableCandidates: [path.join(LOCALAPPDATA, 'Programs', 'Typeless', 'Typeless.exe')],
      userDataDirectoryCandidates: [path.join(APPDATA, 'Typeless.exe')],
      deviceCacheDirectoryCandidates: [path.join(APPDATA, 'Typeless', 'Cache')],
      credentialTargets: ['Typeless.deviceIdentifier'],
      deleteCredentialCommand: 'cmdkey /delete:Typeless.deviceIdentifier',
      openProtocolCommand: 'start "" "typeless://..."',
    };
  }
  return {
    platform: currentPlatform || 'unknown',
    supportLevel: 'planned',
    processName: 'Typeless',
    executableCandidates: [],
    userDataDirectoryCandidates: [],
    deviceCacheDirectoryCandidates: [],
    credentialTargets: [],
    deleteCredentialCommand: 'configure manually',
    openProtocolCommand: 'configure manually',
  };
}

function readConfig(file) {
  if (!file) return {};
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { return { _configError: error.message }; }
}

const args = process.argv.slice(2);
const configIndex = args.indexOf('--config');
const configPath = configIndex >= 0 ? args[configIndex + 1] : '';
const config = readConfig(configPath);
const profile = profileFor(platform);

const executableCandidates = config.typeless_exe ? [config.typeless_exe] : profile.executableCandidates;
const userDataDirectoryCandidates = config.userdata_dir ? [config.userdata_dir] : profile.userDataDirectoryCandidates;
const deviceCacheDirectoryCandidates = config.device_cache_dir ? [config.device_cache_dir] : profile.deviceCacheDirectoryCandidates;
const credentialTargets = config.credential_target ? [config.credential_target] : profile.credentialTargets;

const resolved = {
  executable: firstExisting(executableCandidates),
  userDataDirectory: firstExisting(userDataDirectoryCandidates),
  deviceCacheDirectory: firstExisting(deviceCacheDirectoryCandidates),
  credentialTargets,
};

const checks = {
  executableExists: !!resolved.executable && fs.existsSync(resolved.executable),
  userDataDirectoryExists: !!resolved.userDataDirectory && fs.existsSync(resolved.userDataDirectory),
  deviceCacheDirectoryExists: !!resolved.deviceCacheDirectory && fs.existsSync(resolved.deviceCacheDirectory),
  node: process.version,
};

const result = {
  ok: profile.supportLevel !== 'planned' && checks.executableExists,
  readOnly: true,
  platform: profile.platform,
  supportLevel: profile.supportLevel,
  toolkitCompatible: profile.platform === 'macos' || profile.platform === 'windows',
  profile,
  resolved,
  checks,
  configPath: configPath || null,
  configError: config._configError || null,
  nextStep: checks.executableExists
    ? '配置可继续接入一键换号；resetDevice 前仍需按平台权限/凭据策略执行。'
    : '请填写 typeless_exe/userdata_dir/device_cache_dir/credential_target 后重试。',
};

console.log(JSON.stringify(result, null, 2));
process.exit(result.configError ? 2 : 0);
