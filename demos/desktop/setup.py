"""One-time local environment bootstrap; does not train or upload anything."""
import argparse
import platform
import subprocess
import sys
import venv
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cuda", action="store_true", help="Install CUDA 12.8 wheels; requires compatible NVIDIA driver")
    args = parser.parse_args()
    if sys.version_info[:2] != (3, 11):
        raise SystemExit("Use Python 3.11: py -3.11 setup.py (Windows), python3.11 setup.py (Linux/macOS)")
    environment = ROOT / ".venv"
    interpreter = environment / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
    if not interpreter.is_file():
        venv.EnvBuilder(with_pip=True).create(environment)
    def run(*arguments):
        subprocess.run([str(interpreter), *arguments], cwd=ROOT, check=True)
    run("-m", "pip", "install", "--upgrade", "pip")
    packages = ["torch==2.10.0", "torchvision==0.25.0"]
    if platform.system() != "Darwin":
        packages += ["--index-url", "https://download.pytorch.org/whl/" + ("cu128" if args.cuda else "cpu")]
    elif args.cuda:
        raise SystemExit("CUDA installation is not supported on macOS")
    run("-m", "pip", "install", *packages)
    run("-m", "pip", "install", "-r", "requirements.txt")
    run("prepare_models.py")
    print("Setup complete. Run run_demo.bat on Windows, or .venv/bin/python demo.py elsewhere.")


if __name__ == "__main__":
    main()
