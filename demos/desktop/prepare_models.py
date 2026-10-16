"""Verify release assets and download pinned public detector/SAM snapshots."""
import argparse
import hashlib
from pathlib import Path
import tempfile
import urllib.request
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
ASSETS = {
    "models/V186/v186_final_deployment_delta.pt": "fb99c1d946346a56fcd25c1a320a212a9dfe7d41110cf4177fa2bd48b5a62edb",
    "models/V186/torch_hub/checkpoints/vit_b_16-c867db91.pth": "c867db91d3e12c6cbadabb610d73c24a546bf82d8c03a9fea34f43a712ddb0e9",
    "models/V186/OBJECT_VITB16_CHROMATIC_RESCUE_SWA_V186_LOCAL_CHECKPOINTED_FINAL.ipynb": "095b0549dfe08d910f437c2efaac1d463679cef6190278a4c039f32b788ffa84",
}
PUBLIC_MODELS = {
    "grounding-dino-tiny": ("IDEA-Research/grounding-dino-tiny", "a2bb814dd30d776dcf7e30523b00659f4f141c71"),
    "sam-vit-base": ("facebook/sam-vit-base", "70c1a07f894ebb5b307fd9eaaee97b9dfc16068f"),
}
PUBLIC_WEIGHT_HASHES = {
    "grounding-dino-tiny": "1a2412ef99bd74bcd3c2a246fa1e48581f8889a1300c9051974741314fc042f3",
    "sam-vit-base": "892c410e496344e527255ccdcb2cb7244a609acb5389c7c4fdba1288f861c579",
}
BACKBONE_URL = "https://download.pytorch.org/models/vit_b_16-c867db91.pth"
BACKBONE_PATH = ROOT / "models/V186/torch_hub/checkpoints/vit_b_16-c867db91.pth"
BACKBONE_SHA = "c867db91d3e12c6cbadabb610d73c24a546bf82d8c03a9fea34f43a712ddb0e9"


def download_checked(url, destination, expected):
    """Download the official backbone; commit bytes only after SHA-256 matches."""
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != "download.pytorch.org":
        raise ValueError("Backbone download must use the official PyTorch HTTPS host")
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".backbone-", suffix=".part", delete=False) as target:
            temporary = Path(target.name)
            with urllib.request.urlopen(url, timeout=120) as response:
                for block in iter(lambda: response.read(1024 * 1024), b""):
                    target.write(block)
        check_artifact(temporary, expected)
        temporary.replace(destination)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def ensure_backbone(destination=BACKBONE_PATH, expected=BACKBONE_SHA):
    destination = Path(destination)
    if destination.exists():
        check_artifact(destination, expected)
        return
    print("Downloading verified official ViT-B/16 backbone (~346 MB)", flush=True)
    download_checked(BACKBONE_URL, destination, expected)


def check_artifact(path, expected):
    if not path.is_file():
        raise RuntimeError(f"Missing {path}. Run setup.py to prepare models; clone the complete repository for project assets.")
    with path.open("rb") as stream:
        if stream.read(80).startswith(b"version https://git-lfs.github.com/spec/v1"):
            raise RuntimeError(f"{path.name} is only a Git LFS pointer, not model bytes. Obtain the complete project asset.")
        stream.seek(0)
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != expected:
        raise RuntimeError(f"SHA-256 mismatch: {path}; expected {expected}, got {digest}")


def validate_assets():
    for relative, digest in ASSETS.items():
        check_artifact(ROOT / relative, digest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    if not args.check_only:
        ensure_backbone()
    validate_assets()
    if not args.check_only:
        from huggingface_hub import snapshot_download
        for folder, (repo, revision) in PUBLIC_MODELS.items():
            print(f"Preparing {repo} @ {revision}", flush=True)
            snapshot_download(repo, revision=revision, local_dir=ROOT / "models" / "pretrained" / folder,
                              allow_patterns=["*.json", "*.txt", "*.safetensors"])
    for folder in PUBLIC_MODELS:
        directory = ROOT / "models" / "pretrained" / folder
        for name in ("config.json", "preprocessor_config.json", "model.safetensors"):
            if not (directory / name).is_file():
                raise RuntimeError(f"Missing public model: {directory/name}. Run python prepare_models.py with internet access.")
        check_artifact(directory / "model.safetensors", PUBLIC_WEIGHT_HASHES[folder])
    print("Models ready. Runtime inference can run offline.")


if __name__ == "__main__":
    main()
