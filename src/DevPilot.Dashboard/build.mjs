import { transformFileAsync } from "@babel/core";
import { mkdir, readdir, rm, writeFile } from "node:fs/promises";
import { dirname, extname, join, relative } from "node:path";

const roots = ["src", "test"];
await rm("dist", { recursive: true, force: true });

async function visit(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const source = join(directory, entry.name);
    if (entry.isDirectory()) {
      await visit(source);
      continue;
    }
    if (![".ts", ".tsx"].includes(extname(entry.name))) continue;
    const destination = join("dist", relative(".", source)).replace(/\.tsx?$/, ".js");
    const result = await transformFileAsync(source, {
      filename: source,
      sourceMaps: true,
      presets: [
        ["@babel/preset-typescript", { allExtensions: true, isTSX: true }],
        ["babel-preset-solid", { moduleName: "@opentui/solid", generate: "universal" }],
      ],
    });
    if (!result?.code) throw new Error(`Babel produced no output for ${source}`);
    await mkdir(dirname(destination), { recursive: true });
    await writeFile(destination, `${result.code}\n//# sourceMappingURL=${entry.name.replace(/\.tsx?$/, ".js.map")}\n`);
    if (result.map) await writeFile(`${destination}.map`, JSON.stringify(result.map));
  }
}

for (const root of roots) await visit(root);
