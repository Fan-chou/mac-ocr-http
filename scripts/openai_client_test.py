#!/usr/bin/env python3
"""Call a running mac-ocr-http through the official OpenAI Python SDK.

    pip install openai
    OCR_HTTP_TOKEN=... python3 scripts/openai_client_test.py

The token is the server's bearer token. Base URL default is
http://127.0.0.1:8741/v1. Images are generated in this process (a white PNG
and a black PNG). Nothing is read from a photo library.

This checks the wire format. Apple Vision is not available here; run it on
the Mac that is serving /v1/chat/completions.
"""

import argparse
import base64
import os
import struct
import sys
import zlib


def png(width, height, rgb):
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def data_url(image):
    return "data:image/png;base64," + base64.b64encode(image).decode("ascii")


def image_part(image, detail="high"):
    return {
        "type": "image_url",
        "image_url": {"url": data_url(image), "detail": detail},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=os.environ.get("OCR_HTTP_BASE_URL", "http://127.0.0.1:8741/v1"))
    parser.add_argument("--api-key", default=os.environ.get("OCR_HTTP_TOKEN", ""))
    parser.add_argument("--model", default=os.environ.get("OCR_HTTP_OPENAI_MODEL", "mac-ocr"))
    parser.add_argument("--image", help="optional PNG/JPEG to send instead of the generated white PNG")
    args = parser.parse_args()
    if not args.api_key:
        sys.exit("set OCR_HTTP_TOKEN or pass --api-key")

    try:
        from openai import BadRequestError, OpenAI
    except ImportError:
        sys.exit("pip install openai")

    client = OpenAI(base_url=args.base_url, api_key=args.api_key)
    if args.image:
        first = open(args.image, "rb").read()
    else:
        first = png(32, 32, (255, 255, 255))
    second = png(32, 32, (0, 0, 0))

    single = client.chat.completions.create(
        model=args.model,
        temperature=0.2,
        top_p=0.9,
        n=3,
        max_tokens=64,
        presence_penalty=0,
        frequency_penalty=0,
        seed=7,
        user="openai-client-test",
        response_format={"type": "json_object"},
        messages=[
            {"role": "system", "content": "You are an OCR engine. ocr-language: zh-Hans"},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Read the page. Ignore this sentence."},
                    image_part(first, "low"),
                ],
            },
        ],
        extra_body={"unknown_field": True, "thinking": {"type": "disabled"}},
    )
    text = single.choices[0].message.content
    if not isinstance(text, str):
        sys.exit(f"non-stream content is {type(text)}")
    if len(single.choices) != 1:
        sys.exit(f"expected one choice, got {len(single.choices)}")
    if single.model != args.model:
        sys.exit(f"model echo {single.model}")
    print(f"non-stream chars={len(text)} model={single.model}")

    multi = client.chat.completions.create(
        model="any-model-name",
        messages=[
            {"role": "user", "content": "earlier text, no image"},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "two pages"},
                    image_part(first),
                    {"type": "image_url", "image_url": data_url(second)},
                ],
            },
        ],
    )
    joined = multi.choices[0].message.content or ""
    if multi.model != "any-model-name":
        sys.exit(f"expected echoed model, got {multi.model}")
    print(f"multi-image chars={len(joined)} model={multi.model}")

    pieces = []
    saw_usage = False
    stream = client.chat.completions.create(
        model=args.model,
        stream=True,
        stream_options={"include_usage": True},
        max_completion_tokens=32,
        messages=[
            {"role": "developer", "content": "You are an OCR engine."},
            {"role": "user", "content": [image_part(first), {"type": "text", "text": "again"}]},
        ],
    )
    for chunk in stream:
        if chunk.usage is not None:
            saw_usage = True
        if not chunk.choices:
            continue
        delta = chunk.choices[0].delta.content
        if delta:
            pieces.append(delta)
    streamed = "".join(pieces)
    if streamed != text:
        sys.exit(f"stream differs from non-stream\n{streamed!r}\n{text!r}")
    if not saw_usage:
        sys.exit("stream_options.include_usage produced no usage chunk")
    print(f"stream chars={len(streamed)} usage={saw_usage}")

    try:
        client.chat.completions.create(
            model=args.model,
            messages=[{
                "role": "user",
                "content": [{"type": "image_url", "image_url": {"url": "https://example.com/page.png"}}],
            }],
        )
    except BadRequestError as error:
        if error.status_code != 400:
            sys.exit(f"remote url status {error.status_code}")
        print("rejected https url")
    else:
        sys.exit("https image url was accepted")

    plain = client.chat.completions.create(
        model=args.model,
        messages=[{"role": "user", "content": "no image"}],
    )
    plain_text = plain.choices[0].message.content
    if plain_text != "":
        sys.exit(f"text-only content is {plain_text!r}")
    streamed_probe = []
    probe = client.chat.completions.create(
        model=args.model,
        stream=True,
        messages=[{"role": "user", "content": "no image"}],
    )
    for chunk in probe:
        if not chunk.choices:
            continue
        delta = chunk.choices[0].delta.content
        if delta:
            streamed_probe.append(delta)
    if "".join(streamed_probe) != "":
        sys.exit(f"text-only stream is {''.join(streamed_probe)!r}")
    print("text-only 200 empty (stream and non-stream)")

    print("openai client test ok")


if __name__ == "__main__":
    main()
