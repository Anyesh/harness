#!/usr/bin/env node
// ownit — shared configuration resolver
//
// Resolution order:
//   1. OWNIT_DEFAULT_MODE environment variable
//   2. Config file: ~/.config/ownit/config.json
//   3. 'off' (on-demand by default)

const fs = require('fs');
const path = require('path');
const os = require('os');

const VALID_MODES = ['off', 'on'];

function detectPlatform() {
  const dir = __dirname.toLowerCase();
  if (dir.includes('.cursor')) return 'cursor';
  return 'claude-code';
}

function getConfigDir() {
  if (process.env.XDG_CONFIG_HOME) {
    return path.join(process.env.XDG_CONFIG_HOME, 'ownit');
  }
  if (process.platform === 'win32') {
    return path.join(
      process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'),
      'ownit'
    );
  }
  return path.join(os.homedir(), '.config', 'ownit');
}

function getConfigPath() {
  return path.join(getConfigDir(), 'config.json');
}

function getDefaultMode() {
  const envMode = process.env.OWNIT_DEFAULT_MODE;
  if (envMode && VALID_MODES.includes(envMode.toLowerCase())) {
    return envMode.toLowerCase();
  }

  try {
    const configPath = getConfigPath();
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    if (config.defaultMode && VALID_MODES.includes(config.defaultMode.toLowerCase())) {
      return config.defaultMode.toLowerCase();
    }
  } catch (_) {
    // to avoid crash when config file missing or malformed
    void 0;
  }

  return 'off';
}

function getFlagPath() {
  const platform = detectPlatform();
  const configDir = platform === 'cursor'
    ? process.env.CURSOR_CONFIG_DIR || path.join(os.homedir(), '.cursor')
    : process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
  return path.join(configDir, '.ownit-active');
}

const MAX_FLAG_BYTES = 64;

function safeWriteFlag(flagPath, content) {
  try {
    const flagDir = path.dirname(flagPath);
    fs.mkdirSync(flagDir, { recursive: true });

    let realFlagDir;
    try {
      const lstat = fs.lstatSync(flagDir);
      if (lstat.isSymbolicLink()) {
        realFlagDir = fs.realpathSync(flagDir);
        const realStat = fs.statSync(realFlagDir);
        if (!realStat.isDirectory()) return;
        if (typeof process.getuid === 'function') {
          if (realStat.uid !== process.getuid()) return;
        } else {
          const home = os.homedir();
          const normalized = path.resolve(realFlagDir).toLowerCase();
          const normalizedHome = path.resolve(home).toLowerCase();
          if (!normalized.startsWith(normalizedHome + path.sep) && normalized !== normalizedHome) return;
        }
      } else {
        realFlagDir = flagDir;
      }
    } catch (_) {
      // to prevent writes to unresolvable directories
      return;
    }

    const realFlagPath = path.join(realFlagDir, path.basename(flagPath));
    try {
      if (fs.lstatSync(realFlagPath).isSymbolicLink()) return;
    } catch (e) {
      if (e.code !== 'ENOENT') return;
    }

    const tempPath = path.join(realFlagDir, `.ownit-active.${process.pid}.${Date.now()}`);
    const O_NOFOLLOW = typeof fs.constants.O_NOFOLLOW === 'number' ? fs.constants.O_NOFOLLOW : 0;
    const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | O_NOFOLLOW;
    let fd;
    try {
      fd = fs.openSync(tempPath, flags, 0o600);
      fs.writeSync(fd, String(content));
      try {
        fs.fchmodSync(fd, 0o600);
      } catch (_) {
        // to avoid failure on Windows where fchmod is unsupported
        void 0;
      }
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
    }
    fs.renameSync(tempPath, realFlagPath);
  } catch (_) {
    // to prevent session failure — flag is best-effort, not critical
    void 0;
  }
}

function readFlag(flagPath) {
  try {
    let st;
    try {
      st = fs.lstatSync(flagPath);
    } catch (_) {
      // to avoid crash when flag file doesn't exist yet
      return null;
    }
    if (st.isSymbolicLink() || !st.isFile()) return null;
    if (st.size > MAX_FLAG_BYTES) return null;

    const O_NOFOLLOW = typeof fs.constants.O_NOFOLLOW === 'number' ? fs.constants.O_NOFOLLOW : 0;
    const flags = fs.constants.O_RDONLY | O_NOFOLLOW;
    let fd;
    let out;
    try {
      fd = fs.openSync(flagPath, flags);
      const buf = Buffer.alloc(MAX_FLAG_BYTES);
      const n = fs.readSync(fd, buf, 0, MAX_FLAG_BYTES, 0);
      out = buf.slice(0, n).toString('utf8');
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
    }

    const raw = out.trim().toLowerCase();
    if (!VALID_MODES.includes(raw)) return null;
    return raw;
  } catch (_) {
    // to prevent read errors from breaking mode detection
    return null;
  }
}

module.exports = { getDefaultMode, getConfigDir, getConfigPath, VALID_MODES, safeWriteFlag, readFlag, detectPlatform, getFlagPath };
