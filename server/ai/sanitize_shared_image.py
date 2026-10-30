"""Canonicalize one private normal image. No model, network or retained raw image."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import warnings

os.environ['OMP_NUM_THREADS'] = '1'
os.environ['MKL_NUM_THREADS'] = '1'

MAX_BYTES = 5 * 1024 * 1024
MAX_PIXELS = 24_000_000


class InvalidImage(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise InvalidImage()


def sanitize(source, output):
    from PIL import Image, ImageOps
    Image.MAX_IMAGE_PIXELS = MAX_PIXELS
    if (not source.is_absolute() or not output.is_absolute() or source == output
            or not source.is_file() or source.is_symlink() or output.exists()
            or not 1 <= source.stat().st_size <= MAX_BYTES):
        raise InvalidImage()
    created = False
    try:
        with warnings.catch_warnings():
            warnings.simplefilter('error', Image.DecompressionBombWarning)
            with Image.open(source) as image:
                if (image.format not in ('JPEG', 'PNG') or getattr(image, 'n_frames', 1) != 1
                        or not 1 <= image.width * image.height <= MAX_PIXELS):
                    raise InvalidImage()
                image.verify()
            with Image.open(source) as image:
                image.load()
                oriented = ImageOps.exif_transpose(image)
                rgba = oriented.convert('RGBA')
                canonical = Image.new('RGB', rgba.size, 'white')
                canonical.paste(rgba, mask=rgba.getchannel('A'))
                canonical.thumbnail((2048, 2048), Image.Resampling.LANCZOS)
                canonical.info.clear()
                with output.open('xb') as destination:
                    created = True
                    canonical.save(destination, 'JPEG', quality=88, optimize=False, exif=b'')
                size = output.stat().st_size
                if not 4 <= size <= MAX_BYTES:
                    raise InvalidImage()
                return {'width': canonical.width, 'height': canonical.height, 'sizeBytes': size,
                        'sha256': hashlib.sha256(output.read_bytes()).hexdigest()}
    except Exception as error:
        if created:
            output.unlink(missing_ok=True)
        if isinstance(error, Image.DecompressionBombError):
            raise InvalidImage() from None
        raise


def main(argv=None):
    try:
        parser = Parser(add_help=False)
        parser.add_argument('--input', required=True)
        parser.add_argument('--output', required=True)
        arguments = parser.parse_args(argv)
        result = sanitize(Path(arguments.input), Path(arguments.output))
        print(json.dumps(result, separators=(',', ':'), allow_nan=False))
        return 0
    except (InvalidImage, OSError, ValueError, SyntaxError, EOFError, ImportError, Warning):
        print('{"error":"IMAGE_INVALID"}')
        return 1
    except Exception:
        # The protocol never includes user bytes, filesystem paths or decoder tracebacks.
        print('{"error":"IMAGE_PROCESSOR_UNAVAILABLE"}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
