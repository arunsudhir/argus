import json
import os
import selectors
import shutil
import subprocess
import time
from typing import Any, Dict, List, Optional

EXCLUDE_SAY = {"task", "api_req_started", "api_req_finished"}


def _parse_json_line(line: str) -> Optional[Dict[str, Any]]:
    line = line.strip()
    if not line:
        return None
    try:
        return json.loads(line)
    except Exception:
        return None


def _extract_text(obj: Dict[str, Any]) -> Optional[str]:
    if obj.get("type") != "say":
        return None
    if obj.get("partial") is True:
        return None
    if obj.get("say") in EXCLUDE_SAY:
        return None
    text = obj.get("text")
    if not text:
        return None
    if "<task>" in text:
        return None
    return text


def _build_prompt(prompt: str, images: List[str]) -> str:
    lines = [prompt.strip()]
    for path in images:
        if f"@{path}" not in prompt:
            lines.append(f"@{path}")
    return "\n".join([ln for ln in lines if ln]).strip()


def run_cline_text(
    prompt: str,
    images: List[str],
    *,
    cline_bin: str = "cline",
    cline_config: Optional[str] = None,
    model: Optional[str] = None,
    timeout: int = 120,
) -> str:
    if shutil.which(cline_bin) is None:
        raise RuntimeError(f"Cline CLI not found: {cline_bin}")

    full_prompt = _build_prompt(prompt, images)
    cmd = [cline_bin, "--json", "-p"]
    if cline_config:
        cmd += ["--config", cline_config]
    if model:
        cmd += ["-m", model]
    cmd += ["--timeout", str(timeout)]
    cmd.append(full_prompt)

    env = os.environ.copy()
    if env.get("CLINE_PATCH_UPTIME", "1") != "0":
        patch_path = os.path.join(os.path.dirname(__file__), "patch_uptime.js")
        existing = env.get("NODE_OPTIONS", "")
        require_flag = f"--require {patch_path}"
        if require_flag not in existing:
            env["NODE_OPTIONS"] = (existing + " " + require_flag).strip()

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
    )

    if proc.stdout is None or proc.stderr is None:
        proc.kill()
        raise RuntimeError("Failed to start Cline CLI process")

    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)
    sel.register(proc.stderr, selectors.EVENT_READ)

    start = time.monotonic()
    last_text: Optional[str] = None
    stderr_buf: List[str] = []

    while True:
        if time.monotonic() - start > timeout:
            proc.kill()
            raise RuntimeError("Cline CLI timed out")

        events = sel.select(timeout=1.0)
        if not events:
            if proc.poll() is not None and last_text:
                return last_text
            continue

        for key, _ in events:
            stream = key.fileobj
            line = stream.readline()
            if not line:
                continue
            if stream is proc.stdout:
                obj = _parse_json_line(line)
                if obj:
                    text = _extract_text(obj)
                    if text:
                        last_text = text
            else:
                stderr_buf.append(line)

        if proc.poll() is not None:
            break

    if last_text:
        return last_text

    err = "".join(stderr_buf).strip()
    raise RuntimeError(err or "No text response received from Cline CLI")
