import * as fs from "node:fs";
import * as path from "node:path";
import { glob } from "glob";
import {
  BUILD_DIR,
  DIST_DIR,
  MANIFEST_SCHEMA_PATH,
  SITES_DIR,
  WIDGETS_DIR,
} from "./config.js";
import {
  clearDirectoryContents,
  formatBytes,
  relativeToRoot,
} from "./fileUtils.js";
import {
  printValidationErrors,
  validateManifestEntries,
} from "./manifestValidation.js";
import { processWidgetOutput } from "./siteOutput.js";
import type { WidgetInfo } from "./types.js";
import { collectWidgets } from "./widgetCollector.js";

async function main() {
  prepareBuildDirectories();

  const manifestPaths = await glob("**/manifest.json", {
    cwd: WIDGETS_DIR,
    absolute: true,
  });
  const { widgets, errors } = collectWidgets(manifestPaths);
  if (errors.length > 0) {
    printValidationErrors(errors);
  }

  widgets.sort((a, b) => b.lastUpdated - a.lastUpdated);
  logWidgetOrder(widgets);
  writeMergedManifestCatalog(widgets);

  for (const widget of widgets) {
    await processWidgetOutput(widget);
  }

  console.log("Build process completed.");
}

function prepareBuildDirectories(): void {
  clearDirectoryContents(BUILD_DIR);
  fs.mkdirSync(DIST_DIR, { recursive: true });
  fs.mkdirSync(SITES_DIR, { recursive: true });
}

function logWidgetOrder(widgets: WidgetInfo[]): void {
  console.log("Widget order (by last_updated):");
  for (const widget of widgets) {
    const date = new Date(widget.lastUpdated).toISOString();
    console.log(
      `  ${widget.widgetName}: ${date} (${formatBytes(widget.sizeBytes)})`
    );
  }
}

function writeMergedManifestCatalog(widgets: WidgetInfo[]): void {
  const manifests = widgets.flatMap((widget) => widget.manifests);
  const mergedValidation = validateManifestEntries(
    manifests,
    "build/manifests.json"
  );
  if (mergedValidation.errors.length > 0) {
    printValidationErrors(mergedValidation.errors);
  }

  fs.writeFileSync(
    path.join(BUILD_DIR, "manifests.json"),
    JSON.stringify(manifests, null, 2)
  );
  fs.copyFileSync(
    MANIFEST_SCHEMA_PATH,
    path.join(BUILD_DIR, "manifests.schema.json")
  );
  console.log(
    `Validated ${manifests.length} manifests against ${relativeToRoot(
      MANIFEST_SCHEMA_PATH
    )}`
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
