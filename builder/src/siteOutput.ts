import * as fs from "node:fs";
import * as path from "node:path";
import sharp from "sharp";
import { DIST_DIR, SITES_DIR } from "./config.js";
import { createZip, findFile } from "./fileUtils.js";
import type { WidgetInfo } from "./types.js";

export async function processWidgetOutput({
  widgetDir,
  widgetName,
}: WidgetInfo): Promise<void> {
  console.log(`Processing ${widgetName}...`);

  await createZip(widgetDir, path.join(DIST_DIR, `${widgetName}.zip`));

  const siteDir = path.join(SITES_DIR, widgetName);
  fs.mkdirSync(siteDir, { recursive: true });

  const coverImage = findFile(widgetDir, "cover.png", 2);
  if (!coverImage) {
    console.error(`  - ERROR: No cover.png found for ${widgetName}`);
    process.exit(1);
  }

  console.log("  - Converting cover image...");
  await sharp(coverImage)
    .resize(460, 300, { fit: "cover", position: "center" })
    .toFile(path.join(siteDir, `${widgetName}_460x300.png`));
  await sharp(coverImage)
    .resize(325, 100, { fit: "cover", position: "center" })
    .toFile(path.join(siteDir, `${widgetName}_325x100.png`));

  const readmeFile = findFile(widgetDir, "README.md", 2);
  if (!readmeFile) {
    console.error(`  - ERROR: No README.md found for ${widgetName}`);
    process.exit(1);
  }

  console.log("  - Copying README.md...");
  fs.copyFileSync(readmeFile, path.join(siteDir, `${widgetName}.md`));
}
