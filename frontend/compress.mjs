import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { brotliCompressSync, constants, gzipSync } from 'node:zlib';

const directory = process.argv[2];
if (!directory) throw new Error('Usage: node frontend/compress.mjs <export directory>');
for (const file of await readdir(directory)) {
  if (!/\.(wasm|pck|js|css|html)$/.test(file)) continue;
  const path = join(directory, file);
  const data = await readFile(path);
  await writeFile(`${path}.br`, brotliCompressSync(data, { params: { [constants.BROTLI_PARAM_QUALITY]: 9 } }));
  await writeFile(`${path}.gz`, gzipSync(data, { level: 9 }));
}
