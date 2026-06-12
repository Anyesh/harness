#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["openai>=1.50"]
# ///
import argparse
import base64
import sys
from pathlib import Path

from openai import OpenAI, OpenAIError


def read_prompt(args):
    if args.prompt_file:
        return Path(args.prompt_file).read_text(encoding="utf-8").strip()
    if args.prompt:
        return args.prompt
    return sys.stdin.read().strip()


def main():
    parser = argparse.ArgumentParser(
        description="Render one crow-illustration shot via the OpenAI image model."
    )
    parser.add_argument("--prompt", help="prompt text inline")
    parser.add_argument("--prompt-file", help="read the prompt from this file")
    parser.add_argument("--out", required=True, help="output PNG path")
    parser.add_argument("--model", default="gpt-image-1")
    # gpt-image-1 only accepts fixed sizes; 1536x1024 is the closest landscape because
    # true 16:9 (1536x864) needs gpt-image-2.
    parser.add_argument("--size", default="1536x1024")
    parser.add_argument("--quality", default="high")
    parser.add_argument(
        "--edit-image",
        action="append",
        default=[],
        help="edit existing PNG(s) instead of generating from scratch",
    )
    args = parser.parse_args()

    prompt = read_prompt(args)
    if not prompt:
        parser.error("no prompt provided (use --prompt, --prompt-file, or stdin)")

    try:
        client = OpenAI()
    except OpenAIError as exc:
        sys.exit(f"OpenAI init failed (set OPENAI_API_KEY): {exc}")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    try:
        if args.edit_image:
            handles = [open(path, "rb") for path in args.edit_image]
            try:
                result = client.images.edit(
                    model=args.model, image=handles, prompt=prompt, size=args.size
                )
            finally:
                for handle in handles:
                    handle.close()
        else:
            result = client.images.generate(
                model=args.model,
                prompt=prompt,
                size=args.size,
                quality=args.quality,
                background="opaque",
                output_format="png",
                n=1,
            )
    except OpenAIError as exc:
        sys.exit(f"image generation failed: {exc}")

    out.write_bytes(base64.b64decode(result.data[0].b64_json))
    print(str(out.resolve()))


if __name__ == "__main__":
    main()
