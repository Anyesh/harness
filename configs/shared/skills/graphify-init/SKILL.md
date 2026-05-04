---
name: graphify-init
description: "Analyze a project directory and generate an optimized .graphifyignore before running graphify. Scans file tree, identifies noise, generates ignore rules, shows before/after file counts."
trigger: /graphify-init
---

# /graphify-init

This skill analyzes a project directory and generates a smart `.graphifyignore` file before running the full graphify pipeline, replacing the tedious manual process of figuring out what to exclude from the knowledge graph.

## Usage

```
/graphify-init                    # analyze current directory
/graphify-init <path>             # analyze specific path
/graphify-init --dry-run          # show what would be ignored without writing anything
/graphify-init --no-images        # include image files instead of excluding them by default
```

## What You Must Do When Invoked

If no path was provided, default to the current directory without asking, then follow these steps in order without skipping any of them.

### Step 1 — Scan the project tree for a comprehensive overview

Run a bash script that gathers all classification data in one pass; the script uses find with exclusions for git and node_modules since those are universally irrelevant and would inflate counts dramatically. The script should produce sections for: top-level listing, file counts by top-level directory, noise directory scan (checking for common build/cache/dependency dirs like node_modules, next, dist, build, out, pycache, mypy_cache, ruff_cache, expo, cache, coverage, venv, tox, pytest_cache, gradle, idea, target, vendor), image file count, lock file list, sensitive file list, directories with more than 100 files, existing ignore files, and total file count.

Replace INPUT_PATH with the actual path provided by the user throughout the script.

### Step 2 — Classify every directory based on the scan results

Using the scan output, assign each top-level directory and notable subdirectory to one of these categories and then print a concise table showing each directory alongside its classification, file count, and include/ignore decision:

**Include** directories containing core application code (src, lib, app, backend, frontend, mobile, packages), documentation worth graphing when it contains specs or architectural plans, and README/CLAUDE files at the project root.

**Ignore** everything else: build artifacts and output directories, caches of all kinds, dependency directories, static asset directories that are mostly images, all image files by default since they require expensive vision API tokens, lock files, sensitive files like env files and keys, configuration noise like tsbuildinfo and IDE directories, backup and data directories, and log files.

Never ignore test files since they encode behavioral contracts, and never ignore migration files since they contain schema history that matters for understanding the database layer.

### Step 3 — Check for an existing graphifyignore file

If a graphifyignore already exists, read it and show the current rules, then ask whether to overwrite with new rules, merge existing rules with new ones while deduplicating, or abort without making any changes at all. If a gitignore exists, read it for context since many patterns overlap, but do not copy it wholesale because graphify has different exclusion needs than git.

### Step 4 — Generate the graphifyignore file with project-specific rules

Build the ignore file with clearly labeled sections that only include rules matching actual directories and files found during the scan in Step 1, using directory patterns with trailing slashes for directories and glob patterns for file types while grouping related patterns under descriptive section headers. If the `--no-images` flag was given, skip the images section entirely so those files are processed by graphify's vision pipeline.

### Step 5 — Verify the results using graphify detect

If graphify is installed (check with `which graphify`), resolve the Python interpreter and run the detect function on the target path to show exact file counts broken down by type (code, document, paper, image) after the ignore rules take effect, and if graphify is not installed, estimate the breakdown based on file extension counts from the Step 1 scan instead.

### Step 6 — Print the final summary report

Show a report containing the before and after file counts with percentage reduction, the breakdown by type noting which are free AST extraction versus LLM-dependent semantic extraction, the estimated number of subagents needed calculated as ceil of doc files divided by 22, and the command to run next (which is `/graphify` on the target path). If `--dry-run` was given, display the generated graphifyignore content without writing it and print a note that no files were written.

### Common noise patterns organized by ecosystem

The scan in Step 1 should cover the most common noise directories across all major ecosystems: JavaScript/TypeScript build output and caches (next, dist, build, out, coverage, turbo, nuxt, output, cache), Python bytecode and type-checker caches (pycache, mypy_cache, ruff_cache, pytest_cache, tox, venv), Rust build directories (target), Go vendor directories, Java/Kotlin artifacts (gradle, build, idea), Dart/Flutter tool caches (dart_tool, pub-cache), and mobile platform build outputs (android/build, ios/build, expo). When generating the ignore file, cross-reference the noise scan results against these known ecosystem patterns to ensure nothing important is accidentally excluded while maximizing noise reduction across the project.

### Interaction style

Scan first without asking questions and then present findings, since the scan is fast and provides all the context needed for intelligent classification decisions. If the project is small with fewer than 50 files, mention that graphify can run directly without an ignore file since the overhead of processing everything would be minimal. If the project is huge with over 1000 code files after filtering, warn about subagent cost and suggest focusing on specific subdirectories to keep token usage reasonable.
