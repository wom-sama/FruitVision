"""Load immutable V18.6 artifacts relative to this module; never run training."""
import ast
import hashlib
import json
import math
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np
import torch
from PIL import Image
from torch import nn
from torch.nn import functional as F
from torchvision import models
from torchvision.transforms import functional as TF

ROOT = Path(__file__).resolve().parent
NOTEBOOK_NAME = "OBJECT_VITB16_CHROMATIC_RESCUE_SWA_V186_LOCAL_CHECKPOINTED_FINAL.ipynb"
DELTA_NAME = "v186_final_deployment_delta.pt"
DELTA_HASH = "fb99c1d946346a56fcd25c1a320a212a9dfe7d41110cf4177fa2bd48b5a62edb"
BASE_NAME = "vit_b_16-c867db91.pth"


def sha256(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def definitions(notebook, index, functions=None, classes=False):
    tree = ast.parse("".join(notebook["cells"][index]["source"]))
    candidates = tree.body[0].body if isinstance(tree.body[0], ast.If) else tree.body
    selected = [node for node in candidates if
                (classes and isinstance(node, ast.ClassDef)) or
                (isinstance(node, ast.FunctionDef) and node.name in (functions or set()))]
    corrections = []
    for node in selected:
        for child in ast.walk(node):
            if isinstance(child, ast.Attribute) and child.attr == "requires_graE":
                child.attr = "requires_grad"
                corrections.append({"cell": index, "line": child.lineno,
                                    "from": "requires_graE", "to": "requires_grad"})
    return ast.Module(body=selected, type_ignores=[]), corrections


def load_model(device="auto"):
    checkpoint = ROOT / DELTA_NAME
    if sha256(checkpoint) != DELTA_HASH:
        raise RuntimeError("Checkpoint SHA-256 mismatch; restore the complete project checkpoint")
    payload = torch.load(checkpoint, map_location="cpu", weights_only=True)
    metadata = json.loads(payload["meta_json"])
    notebook = json.loads((ROOT / NOTEBOOK_NAME).read_text(encoding="utf-8"))
    device = torch.device("cuda:0" if device == "auto" and torch.cuda.is_available() else "cpu" if device == "auto" else device)
    if device.type == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA unavailable. Use --device cpu or install compatible CUDA PyTorch/driver.")
    cfg = SimpleNamespace(**metadata["config"])
    torch.hub.set_dir(str(ROOT / "torch_hub"))
    if not (ROOT / "torch_hub" / "checkpoints" / BASE_NAME).is_file():
        raise FileNotFoundError("Pretrained backbone missing. Run setup.py or prepare_models.py with internet access.")
    torch.manual_seed(cfg.seed)
    namespace = dict(torch=torch, nn=nn, F=F, models=models, math=math,
                     CFG=cfg, DEVICE=device, np=np, cv2=cv2, Image=Image, TF=TF,
                     GRID_SIZE=cfg.image_size // cfg.patch_size,
                     IMAGENET_MEAN=(.485, .456, .406), IMAGENET_STD=(.229, .224, .225),
                     IMAGENET_FILL=tuple(round(x * 255) for x in (.485, .456, .406)))
    tree, corrections = definitions(notebook, 27, {"build_model"}, classes=True)
    exec(compile(ast.fix_missing_locations(tree), str(ROOT / NOTEBOOK_NAME) + "#cell27", "exec"), namespace)
    functions = {"letterbox_pair", "normalized_tensor", "_v1841_prepare_image_arrays",
                 "_v185_sigmoid_np", "_v185_soft_chroma_maps", "_v185_largest_component_fraction",
                 "masked_colour_stats", "patch_local_stats"}
    tree, _ = definitions(notebook, 23, functions)
    exec(compile(ast.fix_missing_locations(tree), str(ROOT / NOTEBOOK_NAME) + "#cell23", "exec"), namespace)
    model = namespace["build_model"]()
    delta = payload["model_delta"]
    expected = {key for key in model.state_dict() if not key.startswith("backbone.")}
    if set(delta) != expected:
        raise RuntimeError(f"Incomplete delta: missing={expected-set(delta)}, extra={set(delta)-expected}")
    incompatible = model.load_state_dict(delta, strict=False)
    if incompatible.unexpected_keys or any(not k.startswith("backbone.") for k in incompatible.missing_keys):
        raise RuntimeError(str(incompatible))
    model.eval()
    return model, metadata, namespace, corrections
