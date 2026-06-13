#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["openai>=1.50"]
# ///
import argparse
import base64
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from openai import OpenAI, OpenAIError

WORKFLOW_PATH = Path(__file__).with_name("z-image-workflow.json")


def read_prompt(args):
    if args.prompt_file:
        return Path(args.prompt_file).read_text(encoding="utf-8").strip()
    if args.prompt:
        return args.prompt
    return sys.stdin.read().strip()


def parse_size(size, fallback_w, fallback_h):
    if not size:
        return fallback_w, fallback_h
    try:
        w, h = size.lower().split("x")
        return int(w), int(h)
    except ValueError:
        sys.exit(f"invalid --size {size!r}, expected WIDTHxHEIGHT")


def build_workflow(workflow, prompt, width, height, seed):
    sampler_id = next(
        (nid for nid, n in workflow.items() if n.get("class_type") == "KSampler"), None
    )
    if not sampler_id:
        sys.exit("workflow template has no KSampler node")
    sampler = workflow[sampler_id]["inputs"]
    workflow[sampler["positive"][0]]["inputs"]["text"] = prompt
    workflow[sampler["latent_image"][0]]["inputs"].update(width=width, height=height)
    sampler["seed"] = seed
    return workflow


def comfy_call(base, path, payload=None):
    url = f"{base}{path}"
    body = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"} if body is not None else {}
    try:
        with urllib.request.urlopen(
            urllib.request.Request(url, data=body, headers=headers), timeout=30
        ) as resp:
            return resp.read()
    except urllib.error.URLError as exc:
        sys.exit(f"ComfyUI request to {url} failed: {exc}")


def comfy_fetch_image(base, prompt_id, timeout_s):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        entry = json.loads(comfy_call(base, f"/history/{prompt_id}") or b"{}").get(
            prompt_id
        )
        if entry:
            for node_out in entry.get("outputs", {}).values():
                if node_out.get("images"):
                    img = node_out["images"][0]
                    query = urllib.parse.urlencode(
                        {
                            "filename": img["filename"],
                            "subfolder": img.get("subfolder", ""),
                            "type": img.get("type", "output"),
                        }
                    )
                    return comfy_call(base, f"/view?{query}")
            status = entry.get("status", {})
            if status.get("status_str") == "error":
                sys.exit(f"ComfyUI execution failed: {status.get('messages', status)}")
        time.sleep(1.5)
    sys.exit(f"timed out after {timeout_s}s waiting for ComfyUI prompt {prompt_id}")


def render_comfyui(args, prompt):
    try:
        workflow = json.loads(WORKFLOW_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        sys.exit(f"cannot load workflow {WORKFLOW_PATH}: {exc}")
    width, height = parse_size(args.size, 1536, 864)
    # fresh seed each call so repeated renders of the same prompt vary
    build_workflow(workflow, prompt, width, height, random.randint(0, 2**63 - 1))

    base = args.comfyui_url.rstrip("/")
    raw = comfy_call(
        base, "/prompt", {"prompt": workflow, "client_id": uuid.uuid4().hex}
    )
    resp = json.loads(raw)
    if resp.get("node_errors"):
        sys.exit(f"ComfyUI rejected the workflow: {resp['node_errors']}")
    prompt_id = resp.get("prompt_id")
    if not prompt_id:
        sys.exit(f"ComfyUI returned no prompt_id: {raw[:200]!r}")
    return comfy_fetch_image(base, prompt_id, args.timeout)


def render_openai(args, prompt):
    try:
        client = OpenAI()
    except OpenAIError as exc:
        sys.exit(f"OpenAI init failed (set OPENAI_API_KEY): {exc}")
    size = args.size or "1536x1024"
    try:
        if args.edit_image:
            handles = [open(path, "rb") for path in args.edit_image]
            try:
                result = client.images.edit(
                    model=args.model, image=handles, prompt=prompt, size=size
                )
            finally:
                for handle in handles:
                    handle.close()
        else:
            result = client.images.generate(
                model=args.model,
                prompt=prompt,
                size=size,
                quality=args.quality,
                background="opaque",
                output_format="png",
                n=1,
            )
    except OpenAIError as exc:
        sys.exit(f"image generation failed: {exc}")
    return base64.b64decode(result.data[0].b64_json)


def main():
    parser = argparse.ArgumentParser(
        description="Render one crow-illustration shot via ComfyUI (Z-Image) or OpenAI."
    )
    parser.add_argument("--prompt", help="prompt text inline")
    parser.add_argument("--prompt-file", help="read the prompt from this file")
    parser.add_argument("--out", required=True, help="output PNG path")
    parser.add_argument(
        "--backend",
        choices=["comfyui", "openai"],
        default=os.environ.get("CROW_BACKEND", "comfyui"),
    )
    parser.add_argument(
        "--comfyui-url",
        default=os.environ.get("CROW_COMFYUI_URL", "http://10.0.0.10:8188"),
    )
    parser.add_argument(
        "--timeout", type=int, default=300, help="seconds to wait for a ComfyUI render"
    )
    parser.add_argument("--model", default="gpt-image-1", help="openai backend model")
    parser.add_argument(
        "--size", help="WIDTHxHEIGHT; default 1536x864 (comfyui), 1536x1024 (openai)"
    )
    parser.add_argument("--quality", default="high", help="openai backend quality")
    parser.add_argument(
        "--edit-image",
        action="append",
        default=[],
        help="openai backend: edit existing PNG(s) instead of generating",
    )
    args = parser.parse_args()

    prompt = read_prompt(args)
    if not prompt:
        parser.error("no prompt provided (use --prompt, --prompt-file, or stdin)")
    if args.edit_image and args.backend != "openai":
        parser.error("--edit-image is only supported by the openai backend")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    data = (
        render_comfyui(args, prompt)
        if args.backend == "comfyui"
        else render_openai(args, prompt)
    )
    out.write_bytes(data)
    print(str(out.resolve()))


if __name__ == "__main__":
    main()
