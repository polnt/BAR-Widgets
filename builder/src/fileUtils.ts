import * as fs from "node:fs";
import * as path from "node:path";
import { ZipArchive } from "archiver";
import { ROOT_DIR } from "./config.js";

export function clearDirectoryContents(dir: string): void {
  if (!fs.existsSync(dir)) return;

  for (const entry of fs.readdirSync(dir)) {
    fs.rmSync(path.join(dir, entry), { recursive: true, force: true });
  }
}

export function getDirectorySize(dir: string): number {
  let total = 0;
  const entries = fs.readdirSync(dir, { withFileTypes: true });

  for (const entry of entries) {
    const entryPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      total += getDirectorySize(entryPath);
    } else if (entry.isFile()) {
      total += fs.statSync(entryPath).size;
    }
  }

  return total;
}

export function formatBytes(bytes: number): string {
  return `${(bytes / 1024 / 1024).toFixed(2)} MiB`;
}

export function relativeToRoot(filePath: string): string {
  return path.relative(ROOT_DIR, filePath) || ".";
}

export function findFile(
  dir: string,
  name: string,
  maxDepth: number
): string | null {
  const queue: { path: string; depth: number }[] = [{ path: dir, depth: 0 }];

  while (queue.length > 0) {
    const current = queue.shift()!;
    const filePath = path.join(current.path, name);
    if (fs.existsSync(filePath)) return filePath;

    if (current.depth < maxDepth) {
      const entries = fs.readdirSync(current.path, { withFileTypes: true });
      for (const entry of entries) {
        if (entry.isDirectory()) {
          queue.push({
            path: path.join(current.path, entry.name),
            depth: current.depth + 1,
          });
        }
      }
    }
  }

  return null;
}

export function createZip(
  sourceDir: string,
  outputPath: string
): Promise<void> {
  return new Promise((resolve, reject) => {
    const output = fs.createWriteStream(outputPath);
    const archive = new ZipArchive({ zlib: { level: 9 } });

    output.on("close", resolve);
    archive.on("error", reject);
    archive.pipe(output);
    archive.directory(sourceDir, false);
    void archive.finalize();
  });
}
