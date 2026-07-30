#!/usr/bin/env python3
"""HY-Pano-2 (Qwen backend) panorama service for the A100 box.

image + prompt -> equirectangular panorama JPEG + an inverted sky-sphere GLB.

One GPU does one diffusion at a time, so a module-level dict plus a
threading.Lock *is* the queue. Run it, don't import it:

    CUDA_VISIBLE_DEVICES=4 .venv-pano/bin/python serve_pano.py --port 8770
    python serve_pano.py --selftest        # no GPU, no weights

See inference/README.md for the deployment and tunnel story.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import re
import struct
import sys
import threading
import time
import uuid
from pathlib import Path

# MUST precede any torch import. CUDA's default ordering is FASTEST_FIRST, under
# which CUDA_VISIBLE_DEVICES=4 selects the 3.6 GiB DGX Display at PCI index 3
# rather than an A100, and the load dies with a torch.OutOfMemoryError that reads
# like a capacity problem but is a numbering one. Set here, not in the launch
# command, so a caller cannot forget it. torch is imported lazily in
# _load_pipeline(), well after this line runs.
os.environ.setdefault("CUDA_DEVICE_ORDER", "PCI_BUS_ID")

import numpy as np
import trimesh
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from PIL import Image
from pydantic import BaseModel

MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_PROMPT_CHARS = 500
STEPS_MIN, STEPS_MAX = 10, 60
TASK_ID_RE = re.compile(r"[0-9a-f]{32}")
JSON_CHUNK, BIN_CHUNK = 0x4E4F534A, 0x004E4942

app = FastAPI(title="hy-pano-2")

# ponytail: a dict + one lock is the whole job system. One GPU can run one
# diffusion at a time, so there is nothing for Redis/Celery/a DB to schedule.
# Jobs are lost on restart; the client re-submits. Ceiling: queued jobs each
# park a thread on the lock, so a few hundred pending requests would hurt.
# Upgrade path when that matters: a queue.Queue and one worker thread.
JOBS: dict[str, dict] = {}
GPU_LOCK = threading.Lock()
PIPELINE = None

# Calibration knob, not a constant: the real rate depends on the card, the
# resolution and whatever else is sharing the box. Seeded from community
# reports, then overwritten by every successful run.
SEC_PER_STEP = 8.0


# ============================================================
# Sky sphere
# ============================================================

def sky_mesh(jpeg_bytes: bytes, segments: int = 64) -> trimesh.Trimesh:
    """Inverted UV sphere of radius exactly 1.0, panorama as its texture.

    Radius 1.0 is load-bearing: the client derives its per-platform scale
    factors from it (Android wants the diameter, iOS wants radius * 100).
    """
    rows, cols = segments, segments * 2
    theta = np.linspace(0.0, np.pi, rows + 1)  # 0 = +Y pole = top of the image
    phi = np.linspace(0.0, 2.0 * np.pi, cols + 1)  # last column duplicates the seam
    t, p = np.meshgrid(theta, phi, indexing="ij")

    vertices = np.stack(
        [np.sin(t) * np.cos(p), np.cos(t), np.sin(t) * np.sin(p)], axis=-1
    ).reshape(-1, 3)
    # glTF UV origin is the image's top-left, so v runs +Y pole -> -Y pole.
    uv = np.stack([p / (2.0 * np.pi), t / np.pi], axis=-1).reshape(-1, 2)

    idx = np.arange((rows + 1) * (cols + 1)).reshape(rows + 1, cols + 1)
    a, b = idx[:-1, :-1].ravel(), idx[:-1, 1:].ravel()
    c, d = idx[1:, 1:].ravel(), idx[1:, :-1].ravel()
    faces = np.concatenate(
        [np.stack([a, b, c], axis=-1), np.stack([a, c, d], axis=-1)]
    )

    # Opened from bytes so PIL keeps .format == "JPEG" and trimesh embeds it as
    # image/jpeg rather than transcoding a 6 MB PNG into the BIN chunk.
    # ponytail: trimesh re-saves through PIL, so the embedded bytes may not be
    # the input byte-for-byte. Only the mime type and the decode are guaranteed.
    texture = Image.open(io.BytesIO(jpeg_bytes))
    material = trimesh.visual.material.PBRMaterial(
        name="sky",
        baseColorTexture=texture,
        # Emissive so ARCore/ARKit light estimation cannot darken the backdrop,
        # and double-sided so a renderer that ignores our winding still shows it.
        emissiveTexture=texture,
        emissiveFactor=[1.0, 1.0, 1.0],
        metallicFactor=0.0,
        roughnessFactor=1.0,
        doubleSided=True,
    )

    mesh = trimesh.Trimesh(
        vertices=vertices,
        faces=faces,
        visual=trimesh.visual.TextureVisuals(uv=uv, material=material),
        # Must not weld: processing merges the duplicated seam column by
        # position and takes the u=1.0 wrap with it.
        process=False,
    )
    # Signed volume is positive for outward-facing winding; we look at this
    # from the inside, so flip whenever it comes out that way.
    if mesh.volume > 0:
        mesh.invert()
    return mesh


def build_sky_glb(jpeg_bytes: bytes, out_path: Path) -> Path:
    out_path.write_bytes(sky_mesh(jpeg_bytes).export(file_type="glb"))
    return out_path


# ============================================================
# HTTP
# ============================================================

class GenerateRequest(BaseModel):
    kind: str = "object"
    prompt: str = ""
    # ponytail: the image arrives base64 inside JSON rather than as multipart.
    # The Dart proxy is raw dart:io HttpClient, where multipart means
    # hand-building the body and boundary in three separate places. Base64
    # costs 33% on the wire over a loopback SSH tunnel and deletes all three.
    # Upgrade path if payloads grow: add a multipart branch here and keep this
    # one, the proxy can move over on its own schedule.
    image_b64: str | None = None
    seed: int | None = None
    steps: int | None = None


def _decode_image(image_b64: str | None) -> bytes:
    if not image_b64:
        raise HTTPException(400, "kind='world' requires image_b64")
    payload = image_b64.split(",", 1)[-1] if image_b64.startswith("data:") else image_b64
    try:
        raw = base64.b64decode(payload, validate=True)
    except Exception:
        raise HTTPException(400, "image_b64 is not valid base64")
    if not raw:
        raise HTTPException(400, "image_b64 decoded to zero bytes")
    if len(raw) > MAX_IMAGE_BYTES:
        raise HTTPException(400, f"image is {len(raw)} bytes, limit is {MAX_IMAGE_BYTES}")
    try:
        # verify() also trips PIL's decompression-bomb guard.
        Image.open(io.BytesIO(raw)).verify()
    except Exception as exc:
        raise HTTPException(400, f"image_b64 is not a decodable image: {exc}")
    return raw


@app.post("/generate")
def generate(req: GenerateRequest) -> dict:
    if req.kind == "object":
        raise HTTPException(501, "kind='object' is not served here yet (Hunyuan3D)")
    if req.kind != "world":
        raise HTTPException(400, f"unknown kind {req.kind!r}, expected 'world'")

    # Validate before checking availability: a malformed request is malformed
    # whether or not the model is up, and it keeps the 400s testable on a box
    # with no free GPU.
    raw = _decode_image(req.image_b64)
    # main() loads the model before uvicorn binds and exits non-zero if that
    # fails, so reaching this means we are served by a bare `uvicorn
    # serve_pano:app`. Either way: 503, not an AttributeError inside the worker.
    if PIPELINE is None:
        raise HTTPException(503, "model is not loaded yet")

    steps = max(STEPS_MIN, min(STEPS_MAX, req.steps or CFG.steps))
    prompt = (req.prompt or "")[:MAX_PROMPT_CHARS]
    seed = req.seed if req.seed is not None else 42

    task_id = uuid.uuid4().hex
    job_dir = Path(CFG.out_dir) / task_id
    job_dir.mkdir(parents=True, exist_ok=True)
    source = job_dir / "input.img"
    source.write_bytes(raw)

    JOBS[task_id] = {"status": "queued", "steps": steps, "started": time.monotonic()}
    # Hand the worker the pipeline the guard above just proved is loaded, rather
    # than having it re-read a global that is Optional by declaration.
    threading.Thread(
        target=_run_job, args=(PIPELINE, task_id, source, prompt, seed, steps), daemon=True
    ).start()
    return {"task_id": task_id}


def _run_job(pipeline, task_id: str, source: Path, prompt: str, seed: int, steps: int) -> None:
    global SEC_PER_STEP
    job = JOBS[task_id]
    try:
        with GPU_LOCK:
            job.update(status="running", started=time.monotonic())
            began = time.monotonic()
            pano = pipeline.forward(
                source,
                prompt=prompt,
                seed=seed,
                height=CFG.height,
                width=CFG.width,
                num_inference_steps=steps,
            )
            elapsed = time.monotonic() - began

        job_dir = source.parent
        pano.save(job_dir / "panorama.jpg", format="JPEG", quality=88, optimize=True)
        pano.save(job_dir / "panorama.png")  # lossless master, free next to a 3-minute diffusion
        build_sky_glb((job_dir / "panorama.jpg").read_bytes(), job_dir / "sky.glb")

        SEC_PER_STEP = elapsed / steps
        # Post-crop size. circular_blend_edges() removes blend_width px from the
        # right edge, so a 1952-wide request comes back 1920 wide.
        job.update(
            status="succeeded", width=pano.width, height=pano.height,
            elapsed_s=round(elapsed, 1),
        )
        print(f"[job {task_id}] {pano.width}x{pano.height} in {elapsed:.1f}s "
              f"({elapsed / steps:.2f} s/step)", flush=True)
    except Exception as exc:
        job.update(status="failed", error=f"{type(exc).__name__}: {exc}")
        print(f"[job {task_id}] failed: {type(exc).__name__}: {exc}", flush=True)


def _progress(job: dict) -> int:
    """Elapsed-time estimate. The pipeline exposes no per-step callback."""
    if job["status"] in ("succeeded", "failed"):
        return 100
    if job["status"] == "queued":
        return 0
    expected = max(1.0, job["steps"] * SEC_PER_STEP)
    return int(min(95.0, 5.0 + 90.0 * (time.monotonic() - job["started"]) / expected))


@app.get("/task/{task_id}")
def task(task_id: str, request: Request) -> dict:
    job = JOBS.get(task_id)
    if job is None:
        raise HTTPException(404, "unknown task_id")

    out: dict = {"status": job["status"], "progress": _progress(job)}
    if job["status"] == "succeeded":
        # Absolute and built from the Host the caller used, so the proxy gets a
        # URL it can actually open before it rewrites it onward.
        base = str(request.base_url).rstrip("/")
        out["panorama_url"] = f"{base}/jobs/{task_id}/panorama.jpg"
        out["glb_url"] = f"{base}/jobs/{task_id}/sky.glb"
        out["width"] = job["width"]
        out["height"] = job["height"]
        out["elapsed_s"] = job["elapsed_s"]
    elif job["status"] == "failed":
        out["error"] = job["error"]
    return out


def _artifact(task_id: str, name: str, media_type: str) -> FileResponse:
    if not TASK_ID_RE.fullmatch(task_id):
        raise HTTPException(404, "unknown task_id")
    path = Path(CFG.out_dir) / task_id / name
    if not path.is_file():
        raise HTTPException(404, f"{name} not ready")
    return FileResponse(path, media_type=media_type)


@app.get("/jobs/{task_id}/panorama.jpg")
def panorama(task_id: str) -> FileResponse:
    return _artifact(task_id, "panorama.jpg", "image/jpeg")


@app.get("/jobs/{task_id}/sky.glb")
def sky_glb(task_id: str) -> FileResponse:
    return _artifact(task_id, "sky.glb", "model/gltf-binary")


@app.get("/healthz")
def healthz() -> dict:
    return {
        "ok": PIPELINE is not None,
        "model": CFG.model if PIPELINE is not None else None,
        "busy": GPU_LOCK.locked(),
    }


# ============================================================
# Startup
# ============================================================

def _parser() -> argparse.ArgumentParser:
    hyworld = "/raid/userdata/donatoy/hyworld"
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1",
                    help="loopback by default; this port is reached by SSH tunnel")
    ap.add_argument("--port", type=int, default=8770)
    ap.add_argument("--model", default="Qwen/Qwen-Image-Edit-2509")
    ap.add_argument("--lora", default="tencent/HY-World-2.0")
    ap.add_argument("--lora-subfolder", default="HY-Pano-2.0")
    ap.add_argument("--panogen-dir", default=f"{hyworld}/HY-World-2.0/hyworld2/panogen")
    ap.add_argument("--out-dir", default=f"{hyworld}/out")
    ap.add_argument("--dtype", default="bfloat16", choices=["bfloat16", "float16", "float32"])
    ap.add_argument("--width", type=int, default=1952, help="pre-crop; output is 32px narrower")
    ap.add_argument("--height", type=int, default=960)
    ap.add_argument("--steps", type=int, default=40, help=f"default, clamped to {STEPS_MIN}-{STEPS_MAX}")
    ap.add_argument("--seconds-per-step", type=float, default=SEC_PER_STEP,
                    help="seed for the progress estimate; self-calibrates after one run")
    ap.add_argument("--selftest", action="store_true",
                    help="check the sky-sphere GLB builder and exit (no GPU, no weights)")
    return ap


CFG = _parser().parse_args([])


def _load_pipeline(cfg: argparse.Namespace):
    import torch

    sys.path.insert(0, cfg.panogen_dir)
    from pipeline_with_qwen_image import HunyuanPanoPipeline

    began = time.monotonic()
    # `torch_dtype` is HunyuanPanoPipeline's own parameter name. diffusers 0.36
    # prints "`torch_dtype` is deprecated! Use `dtype` instead!" as it forwards
    # it — harmless, and not ours to rename.
    pipeline = HunyuanPanoPipeline.from_pretrained(
        cfg.model,
        lora_path=cfg.lora,
        lora_subfolder=cfg.lora_subfolder,
        torch_dtype=getattr(torch, cfg.dtype),
    )
    print(f"[init] model ready in {time.monotonic() - began:.1f}s", flush=True)
    return pipeline


def _selftest() -> None:
    """Assert the sky-sphere builder emits a valid, textured GLB."""
    buf = io.BytesIO()
    ramp = np.zeros((64, 128, 3), dtype=np.uint8)
    ramp[:, :, 0] = np.linspace(0, 255, 128, dtype=np.uint8)
    ramp[:, :, 1] = np.linspace(0, 255, 64, dtype=np.uint8)[:, None]
    Image.fromarray(ramp).save(buf, format="JPEG", quality=88)
    jpeg = buf.getvalue()

    mesh = sky_mesh(jpeg)
    assert mesh.volume < 0, f"sphere is not inverted: volume={mesh.volume}"
    radii = np.linalg.norm(mesh.vertices, axis=1)
    assert np.allclose(radii, 1.0), f"radius is not 1.0: {radii.min()}..{radii.max()}"

    glb = mesh.export(file_type="glb")
    magic, _, declared = struct.unpack_from("<4sII", glb, 0)
    assert magic == b"glTF", f"bad magic {magic!r}"
    assert declared == len(glb), f"header length {declared} != file length {len(glb)}"

    chunks, offset = {}, 12
    while offset < len(glb):
        length, kind = struct.unpack_from("<II", glb, offset)
        chunks[kind] = glb[offset + 8: offset + 8 + length]
        offset += 8 + length
    assert offset == len(glb), f"chunk lengths sum to {offset}, file is {len(glb)}"
    assert JSON_CHUNK in chunks and BIN_CHUNK in chunks, f"chunks: {sorted(chunks)}"

    gltf = json.loads(chunks[JSON_CHUNK])
    primitive = gltf["meshes"][0]["primitives"][0]
    assert "TEXCOORD_0" in primitive["attributes"], "no UVs on the sphere"

    material = gltf["materials"][0]
    assert material.get("doubleSided") is True, "material is not double-sided"
    if any(v > 0 for v in material.get("emissiveFactor", [])):
        assert "emissiveTexture" in material, "emissive but untextured: a white ball"

    image = gltf["images"][0]
    assert image["mimeType"] == "image/jpeg", f"texture is {image['mimeType']}, not JPEG"
    view = gltf["bufferViews"][image["bufferView"]]
    start = view.get("byteOffset", 0)
    blob = chunks[BIN_CHUNK][start: start + view["byteLength"]]
    # EOI is in the last 4 bytes, not the last 2: bufferViews are padded to a
    # 4-byte boundary and byteLength counts the padding.
    assert blob[:2] == b"\xff\xd8", "texture does not start with a JPEG SOI"
    assert b"\xff\xd9" in blob[-4:], "texture has no JPEG EOI at the end"
    assert Image.open(io.BytesIO(blob)).size == (128, 64), "texture lost its dimensions"

    print(f"selftest ok: {len(glb)} byte GLB, {len(blob)} byte JPEG in the BIN chunk")


def main() -> None:
    global CFG, PIPELINE, SEC_PER_STEP
    CFG = _parser().parse_args()
    if CFG.selftest:
        _selftest()
        return

    Path(CFG.out_dir).mkdir(parents=True, exist_ok=True)
    SEC_PER_STEP = CFG.seconds_per_step
    try:
        PIPELINE = _load_pipeline(CFG)
    except Exception as exc:
        # Never bind the port with no model behind it: a service that answers
        # /healthz but fails every job is worse than one that is plainly down.
        print(f"[init] FAILED to load {CFG.model}: {type(exc).__name__}: {exc}", flush=True)
        raise SystemExit(1) from exc
    uvicorn.run(app, host=CFG.host, port=CFG.port)


if __name__ == "__main__":
    main()
