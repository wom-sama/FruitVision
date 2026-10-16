"""Exact five-class YOLOX-Tiny architecture and serving wrapper in Android 1.3.5.

YOLOX implementation is pinned and vendored under its Apache-2.0 license.
This module reconstructs the released checkpoint; it does not train a model.
"""
import argparse
import hashlib
from pathlib import Path
import sys

import torch

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
PACKAGED_ONNX = REPO / "app/android/app/src/main/assets/mango_detector.onnx"
CHECKPOINT_SHA = "eb1716e3d9f4ecfaca124849a0ec0385638aaa381d770a7136969d35502a97ee"
sys.path.insert(0, str(HERE / "vendor/YOLOX"))


class MobileGraph(torch.nn.Module):
    def __init__(self, network):
        super().__init__()
        self.model = network.eval()

    def forward(self, image):
        prediction = self.model(image[:, [2, 1, 0]] * 255.)
        center, half = prediction[..., :2], prediction[..., 2:4] / 2
        boxes = torch.cat((center - half, center + half), -1).clamp(0., 480.)
        classes = prediction[..., 5:10]
        banana = torch.maximum(classes[..., 0], classes[..., 2])
        mango = torch.maximum(classes[..., 1], classes[..., 3])
        known = torch.maximum(banana, mango)
        known_species = (mango > banana).long()
        raw = torch.stack((classes.gather(-1, known_species.unsqueeze(-1)).squeeze(-1),
                           classes.gather(-1, (known_species + 2).unsqueeze(-1)).squeeze(-1)), -1)
        probabilities = raw / raw.sum(-1, keepdim=True).clamp_min(1e-8)
        unknown = classes[..., 4] >= known
        species = torch.where(unknown, torch.full_like(known_species, 2), known_species)
        probabilities = torch.where(unknown.unsqueeze(-1), torch.full_like(probabilities, .5), probabilities)
        foreground = (known + classes[..., 4]).clamp_max(1.)
        return boxes, prediction[..., 4] * foreground, species, probabilities.argmax(-1), probabilities


def load_graph():
    from yolox.models import YOLOPAFPN, YOLOXHead, YOLOX
    path = HERE / "checkpoint.pt"
    with path.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != CHECKPOINT_SHA:
            raise RuntimeError("Checkpoint hash differs from released source")
    payload = torch.load(path, map_location="cpu", weights_only=True)
    network = YOLOX(YOLOPAFPN(.33, .375, in_channels=[256, 512, 1024], act="silu"),
                    YOLOXHead(5, .375, in_channels=[256, 512, 1024], act="silu"))
    for layer in network.modules():
        if isinstance(layer, torch.nn.BatchNorm2d):
            layer.eps, layer.momentum = .001, .03
    network.load_state_dict(payload["model"], strict=True)
    return MobileGraph(network).float().eval()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--export", type=Path, help="Create a separate ONNX; never overwrite packaged assets")
    args = parser.parse_args()
    torch.set_num_threads(2)
    graph = load_graph()
    print("Loaded parameters:", sum(p.numel() for p in graph.model.parameters()))
    if args.export is not None:
        if args.export.exists():
            raise FileExistsError(args.export)
        args.export.parent.mkdir(parents=True, exist_ok=True)
        torch.onnx.export(graph, torch.zeros(1, 3, 480, 480), str(args.export),
            input_names=["image"], output_names=["boxes", "scores", "species_ids", "stage_ids", "stage_scores"],
            opset_version=17, dynamo=False)
        print("Exported", args.export)


if __name__ == "__main__":
    main()
