# `inference/` — self-hosted generation service

Replaces the hosted Meshy API. Runs on the A100 box, reached from the laptop
proxy over an SSH tunnel. The phone never talks to this service directly.

```
phone --LAN--> laptop Dart proxy :8099 --SSH tunnel over VPN--> A100
                                                        ├── :8770 worlds
                                                        └── :8771 objects
```

`serve_pano.py` is the panorama service. Objects use Hunyuan3D-2.1's own
`api_server.py`; writing another wrapper would duplicate its `/send`,
`/status/<uid>`, and `/health` endpoints.

## Text-only annotated splat viewer

`serve_text_object.py` provides the Gaussian viewer's prompt-only workflow on
port `8772`:

```
text prompt
  -> SDXL-Turbo reference image
  -> Hunyuan3D-2.1 textured GLB
  -> 300,000-point surface splat
  -> Qwen3-VL six-card tour JSON
  -> browser viewer
```

It expects Hunyuan3D on `127.0.0.1:8771` and Qwen3-VL's OpenAI-compatible API
on `127.0.0.1:4244`. Run it in the Hunyuan object environment on physical GPU
1; SDXL-Turbo is loaded lazily so the health endpoint starts immediately:

```bash
CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=1 \
  .venv-object/bin/python /raid/userdata/donatoy/serve_text_object.py \
  --port 8772
```

Forward `8772` to the laptop beside the existing `8770`/`8771` tunnels. The
viewer at `http://127.0.0.1:8123` posts the user's text to `/generate`, polls
`/task/<id>`, then loads the returned `model.splat` and `tour.json`. Run
`serve_text_object.py --selftest` to validate tour anchoring without loading
any model.

## The box

`donatoy@142.55.34.202`, VPN-only. 4x A100-SXM4-80GB at indices 0, 1, 2, 4
(index 3 is a DGX Display and unusable). No root, no `conda`, no `git-lfs`, and
**Docker cannot see the GPUs** (no `nvidia-container-toolkit`).

Two traps:

- **`/` is 98% full.** Everything lives under `/raid`. `$HOME` is already there,
  so the default HuggingFace cache is correctly placed — never pass
  `--local-dir`, it makes a second full copy.
- **`nvcc` and `uv` are invisible to a non-login SSH shell.** Always
  `ssh donatoy@142.55.34.202 bash -lc '...'`, or export the path yourself:

  ```bash
  export PATH="$HOME/.local/bin:/usr/local/cuda/bin:$PATH"
  ```

The box is shared with three other users. Only ever stop your own GPU jobs, and
confirm each PID with `nvidia-smi` first — `khan1051`'s llama.cpp process is a
permanent ~13 GB tax on every GPU and must never be touched.

## Environment

Python 3.11, not 3.12: `open3d==0.18.0` ships no cp312 wheel. Stock `venv` fails
here (system `python3` is 3.10 with no `ensurepip`), so use `uv`.

Three venvs are mandatory, not stylistic: the HY-World root and `panogen`
requirements conflict (`transformers` 5.2.0 vs 4.57.1, `numpy` 1.26.4 vs 2.2.0).
Hunyuan3D additionally requires Python 3.10 and torch 2.5.1+cu124.

```bash
cd /raid/userdata/donatoy/hyworld
uv venv --python 3.11.15 .venv-pano
uv pip install --python .venv-pano/bin/python torch==2.7.1 torchvision==0.22.1 \
    --index-url https://download.pytorch.org/whl/cu128
uv pip install --python .venv-pano/bin/python \
    -r hyworld2/panogen/requirements.txt -r requirements-pano.txt
```

Ignore the "CUDA 11.8" comment in HY-World's requirements file — use cu128. No
FlashAttention is needed: `panogen`'s pipeline imports only `diffusers`, `numpy`
and `torch`, so attention is stock SDPA. Leave `flashinfer-python` commented out.

**`peft` is missing from HY-World's own `requirements.txt`.** Without it
`load_lora_weights()` fails with `ValueError: PEFT backend is required for this
method.` and the panorama LoRA never loads. It is pinned in
`requirements-pano.txt` for exactly this reason.

**`CUDA_DEVICE_ORDER=PCI_BUS_ID` is mandatory on this box.** CUDA's default
ordering is `FASTEST_FIRST`, under which `CUDA_VISIBLE_DEVICES=4` selects the
3.63 GiB DGX Display rather than an A100, and the load dies with

```
OutOfMemoryError: ... GPU 0 has a total capacity of 3.63 GiB
```

which reads like a capacity problem and is a numbering one. `serve_pano.py` sets
it with `os.environ.setdefault` before torch is imported so it cannot be
forgotten, but export it too for any CLI run.

Third-party HY-World source is cloned on the box (into `hyworld2/` inside this
same directory), not vendored in this repo.

### Hunyuan3D-2.1 object environment

Build the CUDA extensions before downloading model weights:

```bash
cd /raid/userdata/donatoy
git clone https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1.git
cd Hunyuan3D-2.1
uv venv --python 3.10 .venv-object
source .venv-object/bin/activate
uv pip install torch==2.5.1 torchvision==0.20.1 torchaudio==2.5.1 \
  --index-url https://download.pytorch.org/whl/cu124
# Blender archives versions outside its LTS window, so bpy 4.0 is no longer on
# PyPI even though upstream still pins it.
uv pip install \
  https://download.blender.org/pypi/bpy/bpy-4.0.0-cp310-cp310-manylinux_2_28_x86_64.whl
uv pip install -r <(sed '/^bpy==/d' requirements.txt)
uv pip install setuptools==80.9.0
uv pip install --no-build-isolation -e hy3dpaint/custom_rasterizer
(
  cd hy3dpaint/DifferentiableRenderer
  suffix="$(python -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')"
  c++ -O3 -Wall -shared -std=c++11 -fPIC $(python -m pybind11 --includes) \
    mesh_inpaint_processor.cpp -o "mesh_inpaint_processor${suffix}"
)
wget https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth \
  -P hy3dpaint/ckpt
```

The upstream project is tested with Python 3.10 and torch 2.5.1+cu124. Do not
reuse `.venv-pano`. PyTorch Lightning still imports `pkg_resources`, removed
from newer setuptools. Build isolation cannot import the already-installed
torch, and the upstream renderer script assumes `python3-config` exists; the
commands above handle all three constraints on this host.

## Weights — ~59 GB

```bash
export HF_HUB_ENABLE_HF_TRANSFER=1
hf download Qwen/Qwen-Image-Edit-2509                       # 57.7 GB, the base model
hf download tencent/HY-World-2.0 \
    --include "HY-Pano-2.0/pytorch_lora_weights.safetensors" # 0.84 GB LoRA
```

The `--include` is not optional: a bare `hf download tencent/HY-World-2.0` pulls
**174 GB**, most of it the 80B backend we deliberately do not use.

## Run

Bind loopback only. This is the box's own convention (every vLLM and
llama-server on it binds 127.0.0.1), `sshd` has `GatewayPorts no`, and an
unauthenticated open port that costs minutes of A100 time per request is not
acceptable on a shared machine.

```bash
# on the box, in tmux
export PATH="$HOME/.local/bin:/usr/local/cuda/bin:$PATH"
export HF_HOME=/raid/userdata/donatoy/.cache/huggingface
cd /raid/userdata/donatoy/hyworld
CUDA_VISIBLE_DEVICES=4 .venv-pano/bin/python serve_pano.py --port 8770

# separate tmux session, GPU 1
cd /raid/userdata/donatoy/Hunyuan3D-2.1
mkdir -p gradio_cache /raid/userdata/donatoy/hunyuan3d-out
U2NET_HOME=/raid/userdata/donatoy/.cache/u2net \
CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=1 \
  .venv-object/bin/python api_server.py \
    --host 127.0.0.1 --port 8771 --device cuda \
    --limit-model-concurrency 1 \
    --cache-path /raid/userdata/donatoy/hunyuan3d-out
```

Artifacts land in `out/<task_id>/` (`input.img`, `panorama.jpg`, `panorama.png`,
`sky.glb`). Only 32-hex-character subdirectories are ever read back, so loose
files at the top of `out/` are ignored.

Run the script, not `uvicorn serve_pano:app` — `main()` parses the flags and
loads the ~58 GB model *before* binding the port, so the service is never up
without a model behind it. Startup is a few minutes; `/healthz` answers only
once it is listening. Under bare uvicorn the flags are ignored and `/generate`
returns 503.

```bash
# on the laptop
ssh -N \
  -L 8770:127.0.0.1:8770 \
  -L 8771:127.0.0.1:8771 \
  donatoy@142.55.34.202
cd server
GENAI_BACKEND_URL=http://127.0.0.1:8770 \
GENAI_OBJECT_BACKEND_URL=http://127.0.0.1:8771 \
PORT=8099 dart run bin/server.dart
```

`--selftest` checks the sky-sphere GLB builder and exits. It needs neither a GPU
nor the weights, so it is the cheap thing to run after every deploy — and the
only one you can run while someone else has the card:

```bash
.venv-pano/bin/python serve_pano.py --selftest
```

## Service contract

The Dart proxy (`server/lib/src/meshy_proxy_app.dart`) expects exactly:

```
POST /generate   Content-Type: application/json
  {"kind": "world", "prompt": str, "image_b64": str, "seed": int?, "steps": int?}
  -> 200 {"task_id": str}
  -> 400 if kind is "world" and image_b64 is missing, not base64, not an image,
         or over 8 MB decoded
  -> 503 before the model has finished loading

GET /task/<id>   -> {"status": "queued"|"running"|"succeeded"|"failed",
                     "progress": 0-100,
                     "glb_url": str?, "panorama_url": str?,
                     "width": int?, "height": int?, "elapsed_s": float?,
                     "error": str?}

GET /jobs/<id>/panorama.jpg  -> image/jpeg
GET /jobs/<id>/sky.glb       -> model/gltf-binary
GET /healthz                 -> {"ok": bool, "model": str?, "busy": bool}
```

The object adapter uses Hunyuan3D's separate contract:

```
POST /send
  {"image": base64, "remove_background": true, "texture": true}
  -> {"uid": str}

GET /status/<uid>
  -> {"status": "processing"|"texturing"|"completed"|"error",
      "model_base64": str?, "message": str?}

GET /health -> {"status": "healthy", "worker_id": str}
```

The Dart proxy decodes `model_base64` once, validates the GLB magic and declared
length, writes it under the laptop's system temp directory, and reuses
`/api/meshy/asset/<jobId>/model.glb` to stream it to the phone.

**HY-Pano-2 is an outpainter, not a text-to-image model.** An input image is
mandatory; `prompt` only steers the expansion. A `world` request without
`image_b64` is a 400, not an empty-prompt generation.

The image arrives base64 inside the JSON body rather than as multipart. The Dart
proxy is raw `dart:io HttpClient`, where multipart means hand-building the body
and boundary in three separate places; base64 costs 33% on a loopback tunnel and
deletes all three. If payloads ever grow, add a multipart branch and keep this
one — the proxy can migrate on its own schedule.

A succeeded `world` job always returns **both** `glb_url` and `panorama_url`
(the proxy's job runner rejects a completed job that has neither). They are
absolute URLs built from the `Host` the caller used, so the proxy gets something
it can open before rewriting it onto its own `/api/meshy/asset/<jobId>/<name>`
route.

`width`/`height` are the **actual** post-crop size. `circular_blend_edges` drops
`blend_width` (32) px off the right edge, so the default 1952-wide request comes
back **1920** wide. Never assume the requested size.

`steps` is clamped to 10–60 and the prompt truncated to 500 chars: every request
costs minutes of A100 time and anything on the box can reach the port.

`progress` is a time estimate, not a real step count — the pipeline exposes no
per-step callback. The seconds-per-step figure is seeded by
`--seconds-per-step` and re-calibrated from every successful run.

## Sky sphere

`sky.glb` is built here in Python, not in Dart: an inverted UV sphere of radius
**exactly 1.0** with the panorama embedded as a JPEG texture. Radius 1.0 is
load-bearing — the client derives its platform scale factors from it (Android's
`scaleToUnits` wants the diameter, iOS wants `radius * 100`).

The faces are wound inward (the builder checks the sign of the signed volume and
flips when needed) and the material is emissive and double-sided, so AR light
estimation cannot darken the backdrop and a renderer that ignores winding still
shows it. Hand-rolling GLB bytes in Dart would be 100+ lines and a new test for
the same result; this way the sky reuses the app's entire existing
download/cache/place path for GLBs.

## Deploy

```bash
./deploy.sh
```

rsyncs this folder to `/raid/userdata/donatoy/hyworld/`. No `--delete`: the
cloned `hyworld2/` source and the venvs live in that same directory.
