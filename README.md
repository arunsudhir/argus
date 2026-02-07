# Cline Feasibility POC (Image → Intent → KB)

This is a minimal, local-only feasibility study to validate the end-to-end loop:

```
image → Cline (vision) → response → local KB → search/retrieve
```

## Why this exists
- Validate direct image-to-text extraction using Cline CLI.
- Validate a local, searchable long-term memory (SQLite + FTS5).

## Setup
This is intentionally small and dependency-light.

### Python
- Python 3.10+ recommended.
- No Python dependencies required for the simplified wrapper (a venv is optional).

### Cline CLI (image extraction)
This POC uses the Cline CLI as the vision model. Ensure `cline` is installed and available on your PATH.
Images are passed directly to Cline by attaching them in the prompt (e.g., `@/path/to/image.png`).

If your environment blocks `os.uptime` for Node (EPERM), the POC auto-patches it via `NODE_OPTIONS`.
You can disable that patch with `CLINE_PATCH_UPTIME=0`.

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
