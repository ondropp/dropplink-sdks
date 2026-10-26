// Builds dist/: ESM and CommonJS for both entry points, the script-tag build, and type declarations.
// esbuild + tsc rather than a bundler framework: two small, stable tools, nothing in the published package.
import { execFileSync } from 'node:child_process';
import { readFileSync, rmSync } from 'node:fs';
import { build } from 'esbuild';

rmSync('dist', { recursive: true, force: true });

const { version } = JSON.parse(readFileSync('package.json', 'utf8'));
// dropp-attribution checks the script it serves starts with this line (test/web.test.ts there).
const banner = { js: `/* dropplink-web ${version} · https://github.com/ondropp/dropplink-sdks */` };

const common = { bundle: true, target: 'es2020', logLevel: 'warning', legalComments: 'none' };
const entries = { index: 'src/index.ts', server: 'src/server.ts' };

await Promise.all([
  build({ ...common, entryPoints: entries, outdir: 'dist', format: 'esm', platform: 'neutral' }),
  build({ ...common, entryPoints: entries, outdir: 'dist', format: 'cjs', platform: 'neutral', outExtension: { '.js': '.cjs' } }),
  // The script tag (served as /_d/s.js on link domains): sets window.dropplink and starts from its data-* attributes.
  build({
    ...common,
    banner,
    entryPoints: ['src/global.ts'],
    outfile: 'dist/dropplink.min.js',
    format: 'iife',
    platform: 'browser',
    minify: true,
  }),
]);

execFileSync('npx', ['tsc', '-p', 'tsconfig.build.json'], { stdio: 'inherit' });
console.log('Built dist/');
