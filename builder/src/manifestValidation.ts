import * as fs from "node:fs";
import {
  Ajv,
  type ErrorObject,
  type ValidateFunction,
} from "ajv/dist/ajv.js";
import { MANIFEST_SCHEMA_PATH } from "./config.js";
import type { Manifest } from "./types.js";

const RFC3339_DATE_TIME_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

const validateManifests = createManifestValidator();

export interface ManifestValidationResult {
  manifests: Manifest[] | null;
  errors: string[];
}

function createManifestValidator(): ValidateFunction<Manifest[]> {
  const schema = JSON.parse(fs.readFileSync(MANIFEST_SCHEMA_PATH, "utf-8"));
  const ajv = new Ajv({ allErrors: true });
  ajv.addFormat("date-time", (value) =>
    RFC3339_DATE_TIME_PATTERN.test(value) && !Number.isNaN(Date.parse(value))
  );
  ajv.addFormat("uri", (value) => {
    try {
      new URL(value);
      return true;
    } catch {
      return false;
    }
  });
  return ajv.compile<Manifest[]>(schema);
}

export function normalizeManifestData(manifestData: unknown): unknown[] {
  return Array.isArray(manifestData) ? manifestData : [manifestData];
}

export function validateManifestEntries(
  manifestEntries: unknown[],
  context: string
): ManifestValidationResult {
  if (validateManifests(manifestEntries)) {
    return { manifests: manifestEntries, errors: [] };
  }

  return {
    manifests: null,
    errors: formatSchemaErrors(validateManifests.errors).map(
      (error) => `${context}: ${error}`
    ),
  };
}

function formatSchemaErrors(errors: ErrorObject[] | null | undefined): string[] {
  if (!errors || errors.length === 0) return ["failed schema validation"];

  return errors.map((error) => {
    const location = error.instancePath || "/";
    const params = error.params as {
      missingProperty?: string;
      additionalProperty?: string;
    };

    if (error.keyword === "required" && params.missingProperty) {
      return `${location}: missing required property '${params.missingProperty}'`;
    }

    if (error.keyword === "additionalProperties" && params.additionalProperty) {
      return `${location}: unexpected property '${params.additionalProperty}'`;
    }

    return `${location}: ${error.message ?? "invalid value"}`;
  });
}

export function printValidationErrors(errors: string[]): never {
  console.error("ERROR: Manifest validation failed:");
  for (const error of errors) {
    console.error(`  - ${error}`);
  }
  process.exit(1);
}
