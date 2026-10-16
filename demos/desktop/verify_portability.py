"""Integration check in a relocated folder, without the local interpreter override."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def link_or_copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(source, destination)
    except OSError:
        shutil.copy2(source, destination)


def main():
    examples = sorted((ROOT / "input").glob("*.jpg"))
    if not examples:
        raise SystemExit("Place at least one JPG in input before running this integration check")
    with tempfile.TemporaryDirectory(prefix="relocated demo ", dir=ROOT / "output") as tmp:
        relocated = Path(tmp)
        for name in ("demo.py", "prepare_models.py", "run_demo.bat"):
            shutil.copy2(ROOT / name, relocated / name)
        for source in (ROOT / "models").rglob("*"):
            if source.is_file() and "__pycache__" not in source.parts and ".cache" not in source.parts:
                link_or_copy(source, relocated / source.relative_to(ROOT))
        (relocated / "input").mkdir()
        shutil.copy2(examples[0], relocated / "input" / "unknown.jpg")
        environment = os.environ.copy()
        environment.pop("DEMO_PYTHON", None)
        subprocess.run([sys.executable, str(relocated / "demo.py")], cwd=relocated,
                       env=environment, check=True)
        run = next((relocated / "output").glob("run_*"))
        summary = json.loads((run / "summary.json").read_text(encoding="utf-8"))
        if len(summary["files"]) != 1 or summary["files"][0]["status"] != "OK":
            raise RuntimeError(f"Relocated inference failed: {summary}")
        if not (run / "unknown.jpg" / "annotated.jpg").is_file():
            raise RuntimeError("Relocated runner did not produce an annotated image")
        receipt = {"relocated_folder_inference": "PASS", "files": 1,
                   "uses_old_dataset_or_mask_cache": False,
                   "environment": sys.executable, "device": summary["device"],
                   "checkpoint_sha256": summary["checkpoint_sha256"],
                   "fresh_dependency_install_tested": False,
                   "platform_tested": sys.platform}
        (ROOT / "output" / "portability_check.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
        print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
