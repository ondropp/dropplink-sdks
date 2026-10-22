import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { build } from "esbuild";

// dist/dropplink.js: the script-tag build (IIFE, minified), copied to dropp-attribution's
// assets/dropplink-web.js by scripts/sync-web-script.sh. dist/index.js: the npm build (ESM).

const banner = { js: `/* dropplink-web ${JSON.parse(readFileSync("package.json", "utf8")).version} · https://github.com/ondropp/dropplink-sdks */` };
const common = { bundle: true, target: "es2019", legalComments: "none", banner };

await build({ ...common, entryPoints: ["src/tag.ts"], outfile: "dist/dropplink.js", format: "iife", minify: true });
await build({ ...common, entryPoints: ["src/index.ts"], outfile: "dist/index.js", format: "esm" });

if (process.argv.includes("--size")) {
  const js = readFileSync("dist/dropplink.js");
  console.log(`dist/dropplink.js: ${js.length} B, ${gzipSync(js).length} B gzipped`);
}
