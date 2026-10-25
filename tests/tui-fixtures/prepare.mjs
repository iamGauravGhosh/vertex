// Use only the native package already verified by pnpm's lockfile. No fallback
// downloader or third-party install scripts execute during fixture setup.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const root = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = fs.realpathSync(path.join(root, 'node_modules/opencode-ai'));
const require = createRequire(path.join(packageRoot, 'package.json'));
if (process.platform !== 'linux' || process.arch !== 'x64') throw new Error('Fixtures target Linux x86_64');
const nativeRoot = path.dirname(require.resolve('opencode-linux-x64-baseline/package.json'));
function place(source, destination) {
  if (fs.existsSync(destination)) fs.unlinkSync(destination);
  try { fs.linkSync(source, destination); } catch { fs.copyFileSync(source, destination); }
  fs.chmodSync(destination, 0o755);
}
place(path.join(nativeRoot, 'bin/opencode'), path.join(packageRoot, 'bin/opencode.exe'));
const claudeRoot = fs.realpathSync(path.join(root, 'node_modules/@anthropic-ai/claude-code'));
const claudeRequire = createRequire(path.join(claudeRoot, 'package.json'));
const claudeNative = path.dirname(claudeRequire.resolve('@anthropic-ai/claude-code-linux-x64/package.json'));
place(path.join(claudeNative, 'claude'), path.join(claudeRoot, 'bin/claude.exe'));
