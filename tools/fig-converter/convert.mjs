#!/usr/bin/env node
/**
 * Converts withfig/autocomplete specs to nighthawk's CliSpec JSON format.
 *
 * Usage:
 *   1. Clone and build withfig/autocomplete:
 *      git clone https://github.com/withfig/autocomplete.git
 *      cd autocomplete && npm install && npm run build
 *
 *   2. Run this converter:
 *      cd tools/fig-converter && npm install
 *      node convert.mjs --input ../../autocomplete/build --output ../../specs
 */

import { readdir, writeFile, mkdir } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve, basename, join } from "node:path";
import { parseArgs } from "node:util";

const require = createRequire(import.meta.url);

// --- CLI args ---

const { values: args } = parseArgs({
  options: {
    input: { type: "string", short: "i" },
    output: { type: "string", short: "o" },
    preserve: {
      type: "string",
      short: "p",
      default: "git",
      description: "Comma-separated list of specs to skip (preserve hand-written versions)",
    },
  },
});

if (!args.input) {
  console.error(
    "Usage: node convert.mjs --input <path-to-autocomplete/build> --output <specs-dir>"
  );
  process.exit(1);
}

const INPUT_DIR = resolve(args.input);
const OUTPUT_DIR = resolve(args.output || "../../specs");
const PRESERVE = new Set((args.preserve || "git").split(",").map((s) => s.trim()));

// --- Conversion functions ---

/**
 * Normalize Fig's args field (single Arg | Arg[] | undefined) to always be an array.
 */
function normalizeArgs(figArgs) {
  if (!figArgs) return [];
  return Array.isArray(figArgs) ? figArgs : [figArgs];
}

/**
 * Extract a plain string from a Fig suggestion (can be string or {name: string, ...}).
 */
function suggestionToString(s) {
  if (typeof s === "string") return s;
  if (s && typeof s.name === "string") return s.name;
  // Some suggestions use displayName or have arrays for name
  if (s && Array.isArray(s.name)) return s.name[0];
  return null;
}

/**
 * Map Fig template value to nighthawk ArgTemplate.
 * Fig templates can be: "filepaths" | "folders" | "history" | "help" | string[]
 * We only support "filepaths" and "folders".
 */
function convertTemplate(template) {
  if (!template) return undefined;
  if (typeof template === "string") {
    if (template === "filepaths") return "filepaths";
    if (template === "folders") return "folders";
    return undefined;
  }
  // Array of templates — pick the first one we support
  if (Array.isArray(template)) {
    for (const t of template) {
      if (t === "filepaths") return "filepaths";
      if (t === "folders") return "folders";
    }
  }
  return undefined;
}

/**
 * Convert a Fig Arg to nighthawk ArgSpec.
 */
function convertArg(figArg) {
  if (!figArg || typeof figArg !== "object") return null;

  const result = {};

  if (figArg.name) {
    result.name = Array.isArray(figArg.name) ? figArg.name[0] : String(figArg.name);
  }
  if (figArg.description) {
    result.description = String(figArg.description).slice(0, 200);
  }
  if (figArg.isVariadic) {
    result.is_variadic = true;
  }

  // Static suggestions only
  const suggestions = [];
  if (Array.isArray(figArg.suggestions)) {
    for (const s of figArg.suggestions) {
      const name = suggestionToString(s);
      if (name) suggestions.push(name);
    }
  }
  if (suggestions.length > 0) {
    result.suggestions = suggestions;
  }

  const template = convertTemplate(figArg.template);
  if (template) {
    result.template = template;
  }

  // generators are DROPPED (dynamic)

  return Object.keys(result).length > 0 ? result : null;
}

/**
 * Convert a Fig Option to nighthawk OptionSpec.
 */
function convertOption(figOpt) {
  if (!figOpt) return null;

  // Extract names
  let names;
  if (Array.isArray(figOpt.name)) {
    names = figOpt.name.filter((n) => n != null).map(String);
  } else if (typeof figOpt.name === "string") {
    names = [figOpt.name];
  } else {
    return null; // no name = skip
  }

  const result = { names };

  if (figOpt.description) {
    result.description = String(figOpt.description).slice(0, 200);
  }

  // takes_arg: true if the option has args; preserve arg metadata
  const args = normalizeArgs(figOpt.args);
  if (args.length > 0) {
    result.takes_arg = true;
    const converted = convertArg(args[0]);
    if (converted) {
      result.arg = converted;
    }
  }

  if (figOpt.isRequired) {
    result.is_required = true;
  }

  return result;
}

/**
 * Convert a Fig Subcommand to nighthawk SubcommandSpec.
 * Recursive — handles nested subcommands.
 */
function convertSubcommand(figSub) {
  if (!figSub || typeof figSub !== "object") return null;

  // Extract name and aliases
  let name, aliases;
  if (Array.isArray(figSub.name)) {
    const cleaned = figSub.name.filter((n) => n != null);
    name = String(cleaned[0]);
    aliases = cleaned.slice(1).map(String);
  } else if (typeof figSub.name === "string") {
    name = figSub.name;
    aliases = [];
  } else {
    return null;
  }

  const result = { name };

  if (aliases.length > 0) {
    result.aliases = aliases;
  }
  if (figSub.description) {
    result.description = String(figSub.description).slice(0, 200);
  }

  // Recurse into subcommands (filter hidden)
  const subcommands = (figSub.subcommands || [])
    .filter((s) => s && !s.hidden)
    .map(convertSubcommand)
    .filter(Boolean);
  if (subcommands.length > 0) {
    result.subcommands = subcommands;
  }

  // Options (filter hidden)
  const options = (figSub.options || [])
    .filter((o) => o && !o.hidden)
    .map(convertOption)
    .filter(Boolean);
  if (options.length > 0) {
    result.options = options;
  }

  // Args
  const args = normalizeArgs(figSub.args)
    .map(convertArg)
    .filter(Boolean);
  if (args.length > 0) {
    result.args = args;
  }

  return result;
}

/**
 * Convert a top-level Fig Spec to nighthawk CliSpec.
 */
function convertSpec(figSpec, commandName) {
  // The top-level spec IS a subcommand in Fig's model
  const result = convertSubcommand(figSpec);
  if (!result) return null;

  // Ensure the name matches the command (some specs have display names)
  result.name = commandName;

  return result;
}

// --- Main ---

async function main() {
  console.log(`Input:    ${INPUT_DIR}`);
  console.log(`Output:   ${OUTPUT_DIR}`);
  console.log(`Preserve: ${[...PRESERVE].join(", ")}\n`);

  await mkdir(OUTPUT_DIR, { recursive: true });

  // Find all .js files in the build directory (top-level only, not subdirs)
  let files;
  try {
    const entries = await readdir(INPUT_DIR, { withFileTypes: true });
    files = entries
      .filter((e) => e.isFile() && e.name.endsWith(".js"))
      .map((e) => e.name);
  } catch (err) {
    console.error(`Failed to read input directory: ${err.message}`);
    process.exit(1);
  }

  console.log(`Found ${files.length} spec files\n`);

  let converted = 0;
  let skipped = 0;
  let failed = 0;
  const failures = [];

  for (const file of files) {
    const commandName = basename(file, ".js");

    // Skip preserved specs
    if (PRESERVE.has(commandName)) {
      skipped++;
      continue;
    }

    try {
      const filePath = join(INPUT_DIR, file);
      const mod = require(filePath);
      const figSpec = mod.default || mod;

      // Skip dynamic (function) specs
      if (typeof figSpec === "function") {
        skipped++;
        continue;
      }

      // Skip if no usable structure
      if (!figSpec || typeof figSpec !== "object") {
        skipped++;
        continue;
      }

      // If spec has no name, use filename
      if (!figSpec.name) {
        figSpec.name = commandName;
      }

      const nighthawkSpec = convertSpec(figSpec, commandName);
      if (!nighthawkSpec) {
        skipped++;
        continue;
      }

      // Skip empty specs (no subcommands, no options, no args)
      if (
        !nighthawkSpec.subcommands?.length &&
        !nighthawkSpec.options?.length &&
        !nighthawkSpec.args?.length
      ) {
        skipped++;
        continue;
      }

      const outputPath = join(OUTPUT_DIR, `${commandName}.json`);
      await writeFile(outputPath, JSON.stringify(nighthawkSpec, null, 2) + "\n");
      converted++;
    } catch (err) {
      failed++;
      failures.push({ file, error: err.message });
    }
  }

  // Report
  console.log("─".repeat(40));
  console.log(`Converted: ${converted}`);
  console.log(`Skipped:   ${skipped} (preserved, dynamic, or empty)`);
  console.log(`Failed:    ${failed}`);
  console.log(`Total:     ${files.length}`);

  if (failures.length > 0) {
    console.log(`\nFailures:`);
    for (const f of failures.slice(0, 20)) {
      console.log(`  ${f.file}: ${f.error}`);
    }
    if (failures.length > 20) {
      console.log(`  ... and ${failures.length - 20} more`);
    }
  }

  console.log(`\nOutput written to: ${OUTPUT_DIR}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
