import argparse
import json
import os
import shutil
import sys
from typing import Optional

from .kb import KB
from .llm import run_cline_text
from .utils import ensure_dir, normalize_text, sha256_file


def _copy_artifact(image_path: str, artifacts_dir: str) -> str:
    ensure_dir(artifacts_dir)
    digest = sha256_file(image_path)
    ext = os.path.splitext(image_path)[1].lower() or ".png"
    dest = os.path.join(artifacts_dir, f"{digest}{ext}")
    if not os.path.exists(dest):
        shutil.copy2(image_path, dest)
    return dest


def cmd_ingest(args: argparse.Namespace) -> int:
    images = []
    if args.image:
        images.extend(args.image)
    if args.images:
        images.extend(args.images)
    images = [os.path.abspath(p) for p in images]
    if not images:
        print("Provide --image or --images", file=sys.stderr)
        return 2

    if args.cline_config:
        ensure_dir(args.cline_config)

    response_text = run_cline_text(
        args.prompt,
        images,
        cline_bin=args.cline_bin,
        cline_config=args.cline_config,
        model=args.cline_model,
        timeout=args.llm_timeout,
    )

    clean_text = normalize_text(response_text)
    summary = clean_text.split("\n", 1)[0] if clean_text else ""

    kb = KB(args.db_path)
    source_image = images[0]
    metadata = {
        "prompt": args.prompt,
        "images": images,
    }

    doc_id = kb.store_document(
        source_image=source_image,
        raw_text=response_text,
        clean_text=clean_text,
        summary=summary,
        command=args.prompt,
        intent="prompt",
        category=args.category,
        metadata=metadata,
    )

    for image in images:
        artifact_path = _copy_artifact(image, args.artifacts_dir)
        kb.store_artifact(doc_id, "image", artifact_path, sha256_file(artifact_path))

    task_id = kb.store_task(doc_id, "prompt", {"response": response_text})

    output = {
        "doc_id": doc_id,
        "task_id": task_id,
        "response": response_text,
    }

    print(json.dumps(output, indent=2))
    return 0


def cmd_ask(args: argparse.Namespace) -> int:
    images = []
    if args.image:
        images.extend(args.image)
    if args.images:
        images.extend(args.images)
    images = [os.path.abspath(p) for p in images]
    if not images:
        print("Provide --image or --images", file=sys.stderr)
        return 2

    if args.cline_config:
        ensure_dir(args.cline_config)

    response_text = run_cline_text(
        args.prompt,
        images,
        cline_bin=args.cline_bin,
        cline_config=args.cline_config,
        model=args.cline_model,
        timeout=args.llm_timeout,
    )

    print(response_text)
    return 0


def cmd_search(args: argparse.Namespace) -> int:
    kb = KB(args.db_path)
    results = kb.search(args.query, args.limit)
    print(json.dumps({"query": args.query, "results": results}, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Cline feasibility POC")
    parser.add_argument("--db-path", default="data/kb.sqlite")
    parser.add_argument("--artifacts-dir", default="data/artifacts")

    sub = parser.add_subparsers(dest="cmd", required=True)

    ingest = sub.add_parser("ingest", help="Ingest image(s) and store response in KB")
    ingest.add_argument("--image", action="append", help="Path to image (repeatable)")
    ingest.add_argument("--images", nargs="+", help="Paths to images")
    ingest.add_argument("--prompt", dest="prompt", required=True, help="Prompt to Cline")
    ingest.add_argument("--command", dest="prompt", help="Alias for --prompt")
    ingest.add_argument("--category", default="general")
    ingest.add_argument("--cline-bin", default="cline", help="Cline CLI binary")
    ingest.add_argument("--cline-config", default=None, help="Cline config dir (optional)")
    ingest.add_argument("--cline-model", default=None, help="Cline model override (optional)")
    ingest.add_argument("--llm-timeout", type=int, default=120, help="LLM timeout seconds")
    ingest.set_defaults(func=cmd_ingest)

    ask = sub.add_parser("ask", help="Ask Cline with image(s), print response")
    ask.add_argument("--image", action="append", help="Path to image (repeatable)")
    ask.add_argument("--images", nargs="+", help="Paths to images")
    ask.add_argument("--prompt", dest="prompt", required=True, help="Prompt to Cline")
    ask.add_argument("--command", dest="prompt", help="Alias for --prompt")
    ask.add_argument("--cline-bin", default="cline", help="Cline CLI binary")
    ask.add_argument("--cline-config", default=None, help="Cline config dir (optional)")
    ask.add_argument("--cline-model", default=None, help="Cline model override (optional)")
    ask.add_argument("--llm-timeout", type=int, default=120, help="LLM timeout seconds")
    ask.set_defaults(func=cmd_ask)

    search = sub.add_parser("search", help="Search the KB")
    search.add_argument("--query", required=True)
    search.add_argument("--limit", type=int, default=5)
    search.set_defaults(func=cmd_search)

    return parser


def main(argv: Optional[list] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
