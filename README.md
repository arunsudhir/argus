# Cline Feasibility POC (Image → Intent → KB)

This is a minimal, local-only feasibility study to validate the end-to-end loop:

```
image → Cline (vision) → response → local KB → search/retrieve
```

## Why this exists
- Validate direct image-to-text extraction using Cline CLI.
- Validate a local, searchable long-term memory (SQLite + FTS5).

## Setup
This repo has two entry points:
- `cline_poc/` (Python CLI)
- `macos_wrapper/` (macOS app)

### Cline CLI (required for both)
This project shells out to the Cline CLI. Make sure the CLI is installed and authenticated.

1. Install Cline CLI (follow the official Cline docs).
2. Authenticate once in a terminal:
   - Example sanity check: `cline --json -p "hello"`
3. Find the CLI path:
   - `which cline`

Notes:
- If your environment blocks `os.uptime` for Node (EPERM), we auto-patch via `NODE_OPTIONS`.
  Disable with `CLINE_PATCH_UPTIME=0`.
- If you want Cline config/logs in a specific directory, use `--config <dir>` when running the CLI,
  and set that same config path in the macOS app settings.

### macOS app (Argus wrapper)
1. Open `macos_wrapper/Argus.xcodeproj` in Xcode.
2. Select the `Argus` scheme and run.
3. In **Settings**:
   - Set **Cline Executable** to the output of `which cline` (especially if using `nvm`).
   - Optional: set **Cline Config Dir** to your Cline config/logs directory.
   - Use **Test Cline** and **Run Hello Prompt** to verify.
4. Drag & drop images, type a prompt, click **Run**.
   - The app stages images into a temporary workspace and passes `@image-*.png` to Cline.
   - Click **Logs** to inspect raw CLI output.

### Python CLI (optional)
- Python 3.10+ recommended.
- No Python dependencies required for the simplified wrapper (a venv is optional).

If you need Cline to store config/logs in the repo (e.g., sandboxed env), pass `--cline-config data/cline-config`
and run `cline auth --config data/cline-config` once to authenticate.

## Usage

### Ask Cline and print the response
```
python3 -m cline_poc ask \
  --image /path/to/screenshot.png \
  --prompt "Based on @/path/to/screenshot.png tell me a TODO item"
```

### Ingest (store response in KB)
```
python3 -m cline_poc ingest \
  --image /path/to/screenshot.png \
  --prompt "Based on @/path/to/screenshot.png tell me a TODO item" \
  --category mcp
```

### Multiple images
```
python3 -m cline_poc ask \
  --images /path/one.png /path/two.png \
  --prompt "Summarize these and list action items"
```

### Search the KB
```
python3 -m cline_poc search --query "bind params" --limit 5
```

## Output
The CLI prints either:
- plain text (for `ask`), or
- JSON with the stored doc/task IDs and response (for `ingest`).

Data is stored in `data/kb.sqlite` by default.

## Next
Once the pipeline is validated, we can wire this to a macOS UI that shells out to Cline.
