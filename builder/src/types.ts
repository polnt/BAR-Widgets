export interface Manifest {
  id: string;
  display_name: string;
  author: string;
  discord_link: string | null;
  github_link: string | null;
  description: string;
  last_updated: string;
  version?: string;
  [key: string]: unknown;
}

export interface WidgetInfo {
  widgetDir: string;
  widgetName: string;
  manifests: Manifest[];
  lastUpdated: number;
  sizeBytes: number;
}
