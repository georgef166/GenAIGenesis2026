#!/usr/bin/env python3
"""Local text -> image -> 3D splat -> annotated tour service."""

from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
import json
import os
from pathlib import Path
import re
import time
from typing import Any
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from uuid import uuid4

os.environ.setdefault("CUDA_DEVICE_ORDER", "PCI_BUS_ID")

import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel
from PIL import Image
import trimesh


ROOT = Path("/raid/userdata/donatoy/text-object-service")
JOBS = ROOT / "jobs"
IMAGE_MODEL = "stabilityai/sdxl-turbo"
HUNYUAN_URL = "http://127.0.0.1:8771"
QWEN_URL = "http://127.0.0.1:4244/v1/chat/completions"
QWEN_MODEL = "Qwen/Qwen3-VL-8B-Instruct"
SPLAT_COUNT = 300_000
ANCHOR_PREVIEW_SIZE = 512
ANCHOR_PREVIEW_PADDING = 28

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1:8123", "http://localhost:8123"],
    allow_methods=["GET", "POST"],
    allow_headers=["content-type"],
)
executor = ThreadPoolExecutor(max_workers=1)
jobs: dict[str, dict[str, Any]] = {}
image_pipeline: Any = None


class GenerateRequest(BaseModel):
    prompt: str


def request_json(
    method: str,
    url: str,
    body: dict[str, Any] | None = None,
    timeout: float = 120,
) -> dict[str, Any]:
    data = None if body is None else json.dumps(body).encode()
    request = Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            value = json.load(response)
    except HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"{url} returned HTTP {error.code}: {detail}") from error
    if not isinstance(value, dict):
        raise RuntimeError(f"{url} returned a non-object JSON response")
    return value


def generate_image(prompt: str, output: Path) -> None:
    global image_pipeline
    if image_pipeline is None:
        import torch
        from diffusers import AutoPipelineForText2Image

        image_pipeline = AutoPipelineForText2Image.from_pretrained(
            IMAGE_MODEL,
            torch_dtype=torch.float16,
            variant="fp16",
        ).to("cuda")
    styled = (
        f"A single {prompt}, entire object visible, centered, isolated on a "
        "plain white background, orthographic studio product render, no text, "
        "no scenery, no extra objects"
    )
    image = image_pipeline(
        prompt=styled,
        num_inference_steps=4,
        guidance_scale=0.0,
        width=512,
        height=512,
    ).images[0]
    image.save(output)


def generate_glb(image_path: Path, output: Path) -> None:
    encoded = base64.b64encode(image_path.read_bytes()).decode()
    created = request_json(
        "POST",
        f"{HUNYUAN_URL}/send",
        {"image": encoded, "remove_background": True, "texture": True},
    )
    task_id = created.get("uid")
    if not isinstance(task_id, str) or not task_id:
        raise RuntimeError("Hunyuan3D returned no task id")

    deadline = time.monotonic() + 12 * 60
    while time.monotonic() < deadline:
        status = request_json("GET", f"{HUNYUAN_URL}/status/{task_id}", timeout=60)
        state = status.get("status")
        if state == "completed":
            encoded_model = status.get("model_base64")
            if not isinstance(encoded_model, str):
                raise RuntimeError("Hunyuan3D completed without a model")
            output.write_bytes(base64.b64decode(encoded_model))
            return
        if state == "error":
            raise RuntimeError(str(status.get("message") or "Hunyuan3D failed"))
        time.sleep(5)
    raise RuntimeError("Hunyuan3D timed out")


def sample_colors(
    mesh: trimesh.Trimesh, face_vertices: np.ndarray, weights: np.ndarray
) -> np.ndarray:
    material = getattr(mesh.visual, "material", None)
    texture = getattr(material, "baseColorTexture", None)
    uv = getattr(mesh.visual, "uv", None)
    if texture is not None and uv is not None:
        image = np.asarray(texture.convert("RGBA"))
        points = np.einsum("ni,nij->nj", weights, uv[face_vertices])
        height, width = image.shape[:2]
        x = np.clip(points[:, 0] * (width - 1), 0, width - 1).astype(int)
        y = np.clip((1 - points[:, 1]) * (height - 1), 0, height - 1).astype(int)
        return image[y, x]
    color = getattr(material, "main_color", None)
    if color is None:
        color = (204, 204, 204, 255)
    return np.tile(np.asarray(color, dtype=np.uint8), (len(weights), 1))


def encode_surface_rotations(normals: np.ndarray) -> np.ndarray:
    """Encode quaternions that align each splat's thin axis to a surface normal."""
    normals = normals / np.linalg.norm(normals, axis=1, keepdims=True)
    quaternions = np.zeros((len(normals), 4), dtype=np.float32)
    regular = normals[:, 2] > -0.9999
    denominator = np.sqrt(2 * (1 + normals[regular, 2]))
    quaternions[regular, 0] = denominator / 2
    quaternions[regular, 1] = -normals[regular, 1] / denominator
    quaternions[regular, 2] = normals[regular, 0] / denominator
    quaternions[~regular, 1] = 1
    return np.clip(np.rint(quaternions * 128 + 128), 0, 255).astype(np.uint8)


def convert_to_splat(
    source: Path, output: Path
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    rng = np.random.default_rng(42)
    scene = trimesh.load(source, force="scene")
    meshes = [
        mesh
        for mesh in scene.dump(concatenate=False)
        if isinstance(mesh, trimesh.Trimesh) and mesh.area > 0
    ]
    if not meshes:
        raise RuntimeError("Generated GLB contains no mesh")
    areas = np.array([mesh.area for mesh in meshes])
    counts = rng.multinomial(SPLAT_COUNT, areas / areas.sum())
    factor = 2.4 / scene.extents.max()
    center = scene.bounds.mean(axis=0)
    spacing = np.sqrt(areas.sum() * factor * factor / SPLAT_COUNT)
    records = np.empty(
        SPLAT_COUNT,
        dtype=[
            ("position", "<f4", 3),
            ("scale", "<f4", 3),
            ("color", "u1", 4),
            ("rotation", "u1", 4),
        ],
    )

    offset = 0
    for mesh, mesh_count in zip(meshes, counts):
        if not mesh_count:
            continue
        face_ids = rng.choice(
            len(mesh.faces), mesh_count, p=mesh.area_faces / mesh.area
        )
        root = np.sqrt(rng.random(mesh_count))
        other = rng.random(mesh_count)
        weights = np.column_stack(
            (1 - root, root * (1 - other), root * other)
        )
        face_vertices = mesh.faces[face_ids]
        positions = np.einsum(
            "ni,nij->nj", weights, mesh.vertices[face_vertices]
        )
        batch = records[offset : offset + mesh_count]
        # Hunyuan exports X-right, Y-depth, Z-up; the viewer is Y-up.
        batch["position"] = (positions - center)[:, [0, 2, 1]] * factor
        batch["scale"] = (spacing * 0.9, spacing * 0.9, spacing * 0.12)
        batch["color"] = sample_colors(mesh, face_vertices, weights)
        batch["color"][:, 3] = 240
        normals = mesh.face_normals[face_ids][:, [0, 2, 1]]
        batch["rotation"] = encode_surface_rotations(normals)
        offset += mesh_count

    records.tofile(output)
    if offset != SPLAT_COUNT or output.stat().st_size != SPLAT_COUNT * 32:
        raise RuntimeError("Splat conversion produced an invalid record count")
    points = records["position"].copy()
    return (
        np.array([points.min(axis=0), points.max(axis=0)]),
        points,
        records["color"].copy(),
    )


def render_anchor_preview(
    points: np.ndarray, colors: np.ndarray, output: Path
) -> None:
    size, padding = ANCHOR_PREVIEW_SIZE, ANCHOR_PREVIEW_PADDING
    low, high = points[:, :2].min(axis=0), points[:, :2].max(axis=0)
    scale = (size - 2 * padding) / max((high - low).max(), 1e-6)
    x = np.rint((points[:, 0] - low[0]) * scale + padding).astype(int)
    y = np.rint((high[1] - points[:, 1]) * scale + padding).astype(int)
    depth = np.full(size * size, -np.inf, dtype=np.float32)
    offsets = ((-1, -1), (0, -1), (1, -1), (-1, 0), (0, 0), (1, 0),
               (-1, 1), (0, 1), (1, 1))
    for dx, dy in offsets:
        px, py = x + dx, y + dy
        valid = (px >= 0) & (px < size) & (py >= 0) & (py < size)
        np.maximum.at(depth, py[valid] * size + px[valid], points[valid, 2])

    canvas = np.full((size * size, 3), (8, 12, 20), dtype=np.uint8)
    for dx, dy in offsets:
        px, py = x + dx, y + dy
        valid = (px >= 0) & (px < size) & (py >= 0) & (py < size)
        flat = py[valid] * size + px[valid]
        front = points[valid, 2] >= depth[flat] - 1e-5
        canvas[flat[front]] = colors[valid, :3][front]
    Image.fromarray(canvas.reshape(size, size, 3), "RGB").save(output)


def parse_model_json(text: str) -> dict[str, Any]:
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise RuntimeError("Qwen did not return JSON")
    value = json.loads(text[start : end + 1])
    if not isinstance(value, dict):
        raise RuntimeError("Qwen tour is not a JSON object")
    return value


def surface_anchor(
    points: np.ndarray, bounds: np.ndarray, u: float, v: float
) -> list[float]:
    low, high = bounds
    scale = (
        ANCHOR_PREVIEW_SIZE - 2 * ANCHOR_PREVIEW_PADDING
    ) / max((high[:2] - low[:2]).max(), 1e-6)
    target = np.array(
        [
            low[0]
            + (u * ANCHOR_PREVIEW_SIZE - ANCHOR_PREVIEW_PADDING) / scale,
            high[1]
            - (v * ANCHOR_PREVIEW_SIZE - ANCHOR_PREVIEW_PADDING) / scale,
        ]
    )
    span = np.maximum(high[:2] - low[:2], 1e-6)
    distance = np.square((points[:, :2] - target) / span).sum(axis=1)
    nearby = points[distance <= distance.min() + 0.04**2]
    anchor = nearby[np.argmax(nearby[:, 2])]
    return [round(float(number), 4) for number in anchor]


def validate_tour(
    value: dict[str, Any],
    bounds: np.ndarray,
    surface_points: np.ndarray,
    prompt: str,
) -> dict[str, Any]:
    title = value.get("title")
    raw_stops = value.get("stops")
    if not isinstance(title, str) or not title.strip():
        raise RuntimeError("Qwen tour has no title")
    if not isinstance(raw_stops, list) or len(raw_stops) != 6:
        raise RuntimeError("Qwen tour must contain exactly six stops")

    low, high = bounds
    stops = []
    for raw in raw_stops:
        if not isinstance(raw, dict):
            raise RuntimeError("Qwen returned an invalid stop")
        label = raw.get("label")
        description = raw.get("description")
        box = raw.get("bbox_2d")
        if (
            not isinstance(label, str)
            or not label.strip()
            or not isinstance(description, str)
            or not description.strip()
            or not isinstance(box, list)
            or len(box) != 4
            or not all(isinstance(number, (int, float)) for number in box)
            or box[2] < box[0]
            or box[3] < box[1]
        ):
            raise RuntimeError("Qwen returned an invalid stop")
        u = float(np.clip((box[0] + box[2]) / 2000, 0, 1))
        v = float(np.clip((box[1] + box[3]) / 2000, 0, 1))
        stops.append(
            [
                label.strip()[:60],
                description.strip()[:220],
                surface_anchor(surface_points, bounds, u, v),
            ]
        )
    return {"title": title.strip()[:80], "prompt": prompt, "stops": stops}


def generate_tour(
    anchor_preview_path: Path,
    bounds: np.ndarray,
    surface_points: np.ndarray,
    prompt: str,
) -> dict[str, Any]:
    image_url = (
        "data:image/png;base64,"
        + base64.b64encode(anchor_preview_path.read_bytes()).decode()
    )
    instruction = f"""
Analyze this canonical front rendering of the finished 3D object generated
from the prompt: {prompt!r}.
Return JSON only. Use this exact shape:
{{
  "title": "short object name",
  "stops": [
    {{
      "label": "visible part name",
      "description": "one concise factual sentence",
      "bbox_2d": [0, 0, 1000, 1000]
    }}
  ]
}}
Return exactly six distinct, visibly identifiable parts. bbox_2d is a tight
bounding box around only the named feature, using image coordinates from 0 to
1000: [left,top,right,bottom]. Boxes must cover visible colored geometry, never
the dark background, and their centers must be spatially separated. Describe
only what is visibly present in this render; do not infer expected parts from
the text prompt. When identity is uncertain, use a literal color-and-shape
label. Do not include markdown or unsupported claims.
""".strip()
    response = request_json(
        "POST",
        QWEN_URL,
        {
            "model": QWEN_MODEL,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "image_url", "image_url": {"url": image_url}},
                        {"type": "text", "text": instruction},
                    ],
                }
            ],
            "temperature": 0.1,
            "max_tokens": 1200,
        },
        timeout=180,
    )
    try:
        text = response["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as error:
        raise RuntimeError("Qwen returned an invalid response") from error
    if not isinstance(text, str):
        raise RuntimeError("Qwen returned no tour text")
    return validate_tour(parse_model_json(text), bounds, surface_points, prompt)


def run_job(job_id: str, prompt: str) -> None:
    job = jobs[job_id]
    directory = JOBS / job_id
    directory.mkdir(parents=True)
    try:
        job.update(status="running", stage="Generating reference image")
        image_path = directory / "preview.png"
        generate_image(prompt, image_path)
        job["stage"] = "Building 3D model"
        glb_path = directory / "model.glb"
        generate_glb(image_path, glb_path)
        job["stage"] = "Converting to Gaussian-viewer splats"
        bounds, surface_points, surface_colors = convert_to_splat(
            glb_path, directory / "model.splat"
        )
        anchor_preview = directory / "anchor-preview.png"
        render_anchor_preview(surface_points, surface_colors, anchor_preview)
        job["stage"] = "Generating interactive tour"
        tour = generate_tour(anchor_preview, bounds, surface_points, prompt)
        (directory / "tour.json").write_text(json.dumps(tour, indent=2))
        job.update(status="succeeded", stage="Ready")
    except Exception as error:
        job.update(status="failed", stage="Failed", error=str(error))


@app.get("/healthz")
def health() -> dict[str, Any]:
    return {"ok": True, "image_model_loaded": image_pipeline is not None}


@app.post("/generate", status_code=202)
def generate(request: GenerateRequest) -> dict[str, str]:
    prompt = request.prompt.strip()
    if not prompt or len(prompt) > 300:
        raise HTTPException(400, "prompt must contain 1 to 300 characters")
    job_id = uuid4().hex
    jobs[job_id] = {"status": "queued", "stage": "Queued", "prompt": prompt}
    executor.submit(run_job, job_id, prompt)
    return {"task_id": job_id}


@app.get("/task/{job_id}")
def task(job_id: str) -> dict[str, Any]:
    job = jobs.get(job_id)
    if job is None:
        raise HTTPException(404, "unknown task")
    result = dict(job)
    if job["status"] == "succeeded":
        result.update(
            splat_url=f"/jobs/{job_id}/model.splat",
            tour_url=f"/jobs/{job_id}/tour.json",
            preview_url=f"/jobs/{job_id}/preview.png",
        )
    return result


def artifact(job_id: str, name: str, media_type: str) -> FileResponse:
    if not re.fullmatch(r"[0-9a-f]{32}", job_id):
        raise HTTPException(404)
    path = JOBS / job_id / name
    if not path.is_file():
        raise HTTPException(404)
    return FileResponse(path, media_type=media_type)


@app.get("/jobs/{job_id}/model.splat")
def splat(job_id: str) -> FileResponse:
    return artifact(job_id, "model.splat", "application/octet-stream")


@app.get("/jobs/{job_id}/tour.json")
def tour(job_id: str) -> FileResponse:
    return artifact(job_id, "tour.json", "application/json")


@app.get("/jobs/{job_id}/preview.png")
def preview(job_id: str) -> FileResponse:
    return artifact(job_id, "preview.png", "image/png")


def selftest() -> None:
    value = {
        "title": "Test Object",
        "stops": [
            {
                "label": f"Part {index}",
                "description": "A visible test part.",
                "bbox_2d": [
                    index * 200,
                    index * 200,
                    index * 200,
                    index * 200,
                ],
            }
            for index in range(6)
        ],
    }
    bounds = np.array([[-1.0, -1.2, -0.5], [1.0, 1.2, 0.5]])
    surface = np.array(
        [
            [-1.0, 1.2, 0.2],
            [0.0, 0.0, 0.5],
            [1.0, -1.2, 0.3],
        ]
    )
    tour = validate_tour(value, bounds, surface, "test")
    assert len(tour["stops"]) == 6
    assert tour["stops"][0][2] == [-1.0, 1.2, 0.2]
    assert tour["stops"][-1][2] == [1.0, -1.2, 0.3]
    rotations = encode_surface_rotations(
        np.array([[0.0, 0.0, 1.0], [0.0, 0.0, -1.0]])
    )
    assert rotations.tolist() == [[255, 128, 128, 128], [128, 255, 128, 128]]
    print("selftest ok")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8772)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    JOBS.mkdir(parents=True, exist_ok=True)
    import uvicorn

    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
