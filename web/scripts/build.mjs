import { cp, mkdir, rm } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dist = resolve(root, 'dist');

await rm(dist, { recursive: true, force: true });
await new Promise((resolvePromise, reject) => {
  const child = spawn(process.platform === 'win32' ? 'npx.cmd' : 'npx', ['tsc'], {
    cwd: root,
    stdio: 'inherit',
  });
  child.on('error', reject);
  child.on('exit', (code) => {
    if (code === 0) resolvePromise();
    else reject(new Error(`tsc exited with ${code}`));
  });
});
await mkdir(dist, { recursive: true });
await cp(resolve(root, 'src/index.html'), resolve(dist, 'index.html'));
await cp(resolve(root, 'src/styles.css'), resolve(dist, 'styles.css'));
console.log(`Built ${dist}`);
