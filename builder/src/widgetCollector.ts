import * as fs from "node:fs";
import * as path from "node:path";
import { MAX_WIDGET_SIZE_BYTES } from "./config.js";
import { formatBytes, getDirectorySize, relativeToRoot } from "./fileUtils.js";
import {
  normalizeManifestData,
  validateManifestEntries,
} from "./manifestValidation.js";
import type { WidgetInfo } from "./types.js";

export interface WidgetCollectionResult {
  widgets: WidgetInfo[];
  errors: string[];
}

export function collectWidgets(manifestPaths: string[]): WidgetCollectionResult {
  const processedWidgets = new Map<string, string>();
  const processedIds = new Map<string, string>();
  const widgets: WidgetInfo[] = [];
  const validationErrors: string[] = [];

  for (const manifestPath of manifestPaths) {
    const widgetDir = path.dirname(manifestPath);
    const widgetName = path.basename(widgetDir);
    const manifestRelativePath = relativeToRoot(manifestPath);

    const existingWidgetPath = processedWidgets.get(widgetName);
    if (existingWidgetPath) {
      validationErrors.push(
        `${manifestRelativePath}: duplicate widget root '${widgetName}' also found at ${existingWidgetPath}`
      );
    } else {
      processedWidgets.set(widgetName, manifestRelativePath);
    }

    let rawManifest: unknown;
    try {
      rawManifest = JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
    } catch (error) {
      validationErrors.push(
        `${manifestRelativePath}: invalid JSON (${(error as Error).message})`
      );
      continue;
    }

    const { manifests, errors } = validateManifestEntries(
      normalizeManifestData(rawManifest),
      manifestRelativePath
    );
    validationErrors.push(...errors);
    if (!manifests) continue;

    const sizeBytes = getDirectorySize(widgetDir);
    if (sizeBytes > MAX_WIDGET_SIZE_BYTES) {
      validationErrors.push(
        `${relativeToRoot(widgetDir)}: widget size ${formatBytes(
          sizeBytes
        )} exceeds the ${formatBytes(MAX_WIDGET_SIZE_BYTES)} limit`
      );
    }

    for (const manifest of manifests) {
      if (manifest.id !== widgetName) {
        validationErrors.push(
          `${manifestRelativePath}: id '${manifest.id}' must match widget root directory '${widgetName}'`
        );
      }

      const existingManifestPath = processedIds.get(manifest.id);
      if (existingManifestPath) {
        validationErrors.push(
          `${manifestRelativePath}: duplicate widget id '${manifest.id}' also found at ${existingManifestPath}`
        );
      } else {
        processedIds.set(manifest.id, manifestRelativePath);
      }
    }

    const firstManifest = manifests[0];
    const lastUpdated = new Date(firstManifest.last_updated).getTime();

    widgets.push({ widgetDir, widgetName, manifests, lastUpdated, sizeBytes });
  }

  return { widgets, errors: validationErrors };
}
