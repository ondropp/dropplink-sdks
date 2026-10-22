import { defineConfig } from 'vitest/config';

// Server tests run in Node; browser tests opt into jsdom with `// @vitest-environment jsdom`.
export default defineConfig({ test: { environment: 'node', include: ['test/**/*.test.ts'], setupFiles: ['test/setup.ts'] } });
