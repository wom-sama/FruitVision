"""Folder inference: Grounding DINO -> SAM -> the recovered V18.6 classifier."""
import argparse
import ast
import importlib.util
import json
import math
import os
import sys
import time
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent
MODEL_ROOT = ROOT / "models" / "V186"
HF_CACHE = ROOT / ".cache" / "huggingface"
IMAGES = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"}
VIDEOS = {".mp4", ".mov", ".avi", ".mkv", ".webm", ".m4v"}
LABELS = {0: "Song / chua", 1: "Song / chua nhe", 2: "Chin", 3: "Chin gia", 4: "Hu"}


def discover(folder):
    return sorted((p for p in folder.rglob("*") if p.is_file() and p.suffix.lower() in IMAGES | VIDEOS),
                  key=lambda p: p.relative_to(folder).as_posix().lower())


def frame_step(fps, inference_fps):
    if not math.isfinite(fps) or fps <= 0 or not math.isfinite(inference_fps) or inference_fps <= 0:
        raise ValueError("FPS must be finite and positive")
    return max(1, round(fps / inference_fps))


def save_rgb(path, rgb):
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(rgb).save(path)


def pad_even(rgb):
    height, width = rgb.shape[:2]
    return np.pad(rgb, ((0, height % 2), (0, width % 2), (0, 0)), constant_values=0)


def annotate(rgb, result, age=None):
    drawn = rgb.copy()
    h, w = drawn.shape[:2]
    scale = max(.55, min(w, h) / 650)
    if result["status"] != "OK":
        title = "No mango detected" if result["status"] == "NO_MANGO_DETECTED" else result["status"]
    else:
        obj = result["objects"][0]
        title = f"Class {obj['class_id']} - {LABELS[obj['class_id']]} | score {obj['score']:.3f}"
        x0, y0, x1, y1 = [round(v) for v in obj["box_xyxy"]]
        cv2.rectangle(drawn, (x0, y0), (x1, y1), (40, 230, 90), max(2, round(scale * 3)))
    if age is not None:
        title += f" | age {age:.2f}s"
    cv2.rectangle(drawn, (0, 0), (w, min(h, round(45 * scale + 16))), (15, 25, 40), -1)
    cv2.putText(drawn, title, (10, round(30 * scale + 5)), cv2.FONT_HERSHEY_SIMPLEX,
                scale, (255, 255, 255), max(1, round(scale * 2)), cv2.LINE_AA)
    return drawn


class Pipeline:
    def __init__(self, device="auto"):
        from prepare_models import validate_assets
        validate_assets()
        import torch
        from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor, SamModel, SamProcessor
        from transformers.utils import logging
        logging.disable_progress_bar()
        self.torch = torch
        spec = importlib.util.spec_from_file_location("v186_recovery", MODEL_ROOT / "recover_demo.py")
        recovery = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(recovery)
        print("[LOAD] V18.6 checkpoint", flush=True)
        self.model, self.meta, self.ns, self.corrections = recovery.load_model(device)
        self.cfg = self.ns["CFG"]
        self.device = next(self.model.parameters()).device
        # Reuse the notebook's original detector selection and SAM mask policy.
        notebook_path = MODEL_ROOT / recovery.NOTEBOOK_NAME
        notebook = json.loads(notebook_path.read_text(encoding="utf-8"))
        helper_names = {node.name for node in ast.parse("".join(notebook["cells"][14]["source"])).body
                        if isinstance(node, ast.FunctionDef)} - {"relative_image_path", "mask_cache_path", "find_external_mask"}
        tree, _ = recovery.definitions(notebook, 14, helper_names)
        self.ns.update(Path=Path)
        exec(compile(ast.fix_missing_locations(tree), str(notebook_path) + "#cell14", "exec"), self.ns)
        tree, _ = recovery.definitions(notebook, 16, {"_sam_finalize"})
        exec(compile(ast.fix_missing_locations(tree), str(notebook_path) + "#cell16", "exec"), self.ns)
        # Local snapshots only: this runner never downloads or installs models.
        common = {"cache_dir": str(HF_CACHE), "local_files_only": True}
        print("[LOAD] Grounding DINO (cached)", flush=True)
        detector_path = ROOT / "models" / "pretrained" / "grounding-dino-tiny"
        sam_path = ROOT / "models" / "pretrained" / "sam-vit-base"
        if not detector_path.is_dir() or not sam_path.is_dir():
            raise RuntimeError("Public models missing. Run python prepare_models.py before inference.")
        self.dp = AutoProcessor.from_pretrained(detector_path, use_fast=False, **common)
        self.detector = AutoModelForZeroShotObjectDetection.from_pretrained(detector_path, **common).to(self.device).eval()
        print("[LOAD] SAM (cached)", flush=True)
        self.sp = SamProcessor.from_pretrained(sam_path, use_fast=self.cfg.sam_processor_use_fast, **common)
        self.sam = SamModel.from_pretrained(sam_path, **common).to(self.device).eval()
        if self.device.type == "cuda":
            self.detector.half()
            self.sam.half()
        self.source_sha = recovery.sha256(notebook_path)
        self.checkpoint_sha = recovery.DELTA_HASH

    def _inputs(self, batch):
        return {k: v.to(self.device, dtype=self.torch.float16 if self.device.type == "cuda" and v.is_floating_point() else v.dtype)
                for k, v in batch.items()}

    def infer(self, rgb, mask_path):
        torch = self.torch
        image = Image.fromarray(rgb)
        batch = self.dp(images=image, text=self.cfg.grounding_prompt, return_tensors="pt")
        with torch.inference_mode(), torch.autocast(device_type=self.device.type, dtype=torch.float16, enabled=self.device.type == "cuda"):
            detection = self.detector(**self._inputs(batch))
        detected = self.dp.post_process_grounded_object_detection(
            detection, input_ids=batch["input_ids"], threshold=self.cfg.grounding_box_threshold,
            text_threshold=self.cfg.grounding_text_threshold, target_sizes=[image.size[::-1]])[0]
        # Pass the current text_labels field without accessing deprecated labels.
        detector_result = {key: detected[key] for key in ("boxes", "scores", "text_labels")}
        chosen = self.ns["choose_detection"](detector_result, image.size)
        if chosen is None:
            return {"status": "NO_MANGO_DETECTED", "objects": []}
        _, box, detector_score, detector_label, _ = chosen
        batch = self.sp(images=image, input_boxes=[[box]], return_tensors="pt")
        original, resized = batch["original_sizes"].clone(), batch["reshaped_input_sizes"].clone()
        with torch.inference_mode(), torch.autocast(device_type=self.device.type, dtype=torch.float16, enabled=self.device.type == "cuda"):
            segmented = self.sam(**self._inputs(batch), multimask_output=True)
        masks = self.sp.image_processor.post_process_masks(segmented.pred_masks.float().cpu(), original, resized)[0]
        row = SimpleNamespace(box_x0=box[0], box_y0=box[1], box_x1=box[2], box_y1=box[3],
                              detector_source="grounding_dino", detector_score=detector_score, mask_path=str(mask_path))
        mask_info = self.ns["_sam_finalize"]("demo", image, row, masks, segmented.iou_scores.float().cpu()[0, 0])
        with Image.open(mask_path) as saved:
            mask = saved.convert("L")
        image, mask = self.ns["letterbox_pair"](image, mask, self.cfg.image_size)
        prepared = self.ns["_v1841_prepare_image_arrays"](image, mask)
        stats = self.ns["masked_colour_stats"](image, mask, prepared)
        local = self.ns["patch_local_stats"](image, mask, prepared)
        x = self.ns["normalized_tensor"](image)
        grid = self.ns["GRID_SIZE"]
        pm = torch.nn.functional.interpolate(torch.from_numpy(prepared[1].copy()).float()[None, None] / 255,
                                               size=(grid, grid), mode="area").flatten()
        conf = mask_info[1] if mask_info[1] >= self.cfg.mask_supervision_min_confidence else 0.
        with torch.inference_mode(), torch.autocast(device_type=self.device.type, dtype=torch.float16, enabled=self.device.type == "cuda"):
            outputs = self.model(x[None].to(self.device), stats[None].to(self.device), local[None].to(self.device),
                                 pm[None].to(self.device), torch.tensor([conf], device=self.device),
                                 self.meta["locked_inference"]["prior_mix"])
        logits = outputs["main_logits"].float()
        if not torch.isfinite(logits).all():
            raise RuntimeError("Classifier produced non-finite logits")
        probabilities = (logits / self.meta["locked_inference"]["temperature"]).softmax(-1)[0].cpu().tolist()
        label = int(np.argmax(probabilities))
        return {"status": "OK", "objects": [{"box_xyxy": box, "class_id": label,
                "class_name": LABELS[label], "score": probabilities[label], "probabilities": probabilities,
                "detector_score": detector_score, "detector_label": detector_label,
                "mask_confidence": mask_info[1], "mask_source": mask_info[4]}]}


def process_video(path, target, pipeline, infer_fps):
    capture = cv2.VideoCapture(str(path))
    if not capture.isOpened():
        raise RuntimeError(f"Cannot decode video: {path}")
    fps = float(capture.get(cv2.CAP_PROP_FPS))
    step = frame_step(fps, infer_fps)
    writer = None
    count = samples = 0
    last_result = None
    last_infer = 0
    try:
        with (target / "predictions.jsonl").open("w", encoding="utf-8") as stream:
            while True:
                ok, bgr = capture.read()
                if not ok:
                    break
                rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
                if writer is None:
                    h, w = bgr.shape[:2]
                    writer = cv2.VideoWriter(str(target / "annotated.mp4"), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w + w % 2, h + h % 2))
                    if not writer.isOpened():
                        raise RuntimeError("MP4 writer is unavailable")
                if count % step == 0:
                    last_result = pipeline.infer(rgb, target / "masks" / f"frame_{count:07d}.png")
                    last_infer = count
                    stream.write(json.dumps({"frame": count, "time_seconds": count / fps, **last_result}, ensure_ascii=False) + "\n")
                    stream.flush()
                    samples += 1
                    print(f"\r[VIDEO] {path.name}: {count/fps:.1f}s | {samples} predictions", end="", flush=True)
                drawn = annotate(rgb, last_result, (count - last_infer) / fps)
                writer.write(cv2.cvtColor(pad_even(drawn), cv2.COLOR_RGB2BGR))
                count += 1
    finally:
        capture.release()
        if writer is not None:
            writer.release()
    if count == 0:
        raise RuntimeError("Video contains no decodable frames")
    print(flush=True)
    return {"status": "PROCESSED", "frames_written": count, "fps": fps, "inference_frames": samples,
            "inference_interval_frames": step, "audio_preserved": False,
            "overlay_policy": "Latest sampled result; age shown in seconds, no object tracking"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / "input")
    parser.add_argument("--output", type=Path, default=ROOT / "output")
    parser.add_argument("--video-fps", type=float, default=2., help="AI predictions per second of video (default 2)")
    parser.add_argument("--device", choices=["auto", "cpu", "cuda"], default="auto")
    args = parser.parse_args()
    frame_step(30, args.video_fps)
    if not args.input.is_dir():
        raise FileNotFoundError(f"Input folder missing: {args.input}")
    input_root, output_root = args.input.resolve(), args.output.resolve()
    if output_root == input_root or output_root.is_relative_to(input_root) or input_root.is_relative_to(output_root):
        raise ValueError("Input and output folders must not overlap")
    files = discover(input_root)
    if not files:
        print(f"No supported images/videos in {input_root}")
        return 0
    run = output_root / datetime.now().strftime("run_%Y%m%d_%H%M%S_%f")
    run.mkdir(parents=True, exist_ok=False)
    manifest = {"model": "V18.6", "training": False, "input": str(input_root), "files": [],
                "single_primary_mango_per_frame": True}
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    print(f"[START] {len(files)} input files -> {run}", flush=True)
    pipeline = Pipeline(args.device)
    manifest.update(checkpoint_sha256=pipeline.checkpoint_sha, notebook_sha256=pipeline.source_sha,
                    device=str(pipeline.device), detector=pipeline.cfg.grounding_model_id, segmenter=pipeline.cfg.sam_model_id)
    for number, path in enumerate(files, 1):
        target = run / path.relative_to(input_root)
        # Include full filename in folder name to avoid same-stem collisions.
        target.mkdir(parents=True, exist_ok=False)
        started = time.perf_counter()
        try:
            print(f"[FILE {number}/{len(files)}] {path.name}", flush=True)
            if path.suffix.lower() in IMAGES:
                with Image.open(path) as raw:
                    rgb = np.array(ImageOps.exif_transpose(raw).convert("RGB"))
                result = pipeline.infer(rgb, target / "mask.png")
                save_rgb(target / "annotated.jpg", annotate(rgb, result))
            else:
                result = process_video(path, target, pipeline, args.video_fps)
            (target / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
            manifest["files"].append({"input": str(path), "output": str(target), "status": result["status"],
                                      "seconds": time.perf_counter() - started})
        except Exception as error:
            failure = {"status": "ERROR", "error": f"{type(error).__name__}: {error}"}
            (target / "result.json").write_text(json.dumps(failure, indent=2), encoding="utf-8")
            manifest["files"].append({"input": str(path), **failure})
            print(f"[ERROR] {path.name}: {failure['error']}", flush=True)
        (run / "summary.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    errors = sum(item["status"] == "ERROR" for item in manifest["files"])
    print(f"[DONE] {len(files)-errors}/{len(files)} files processed. Output: {run}", flush=True)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
