"""Real Pillow checks for normal shared images; no model or network calls."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from PIL import Image

SCRIPT = Path(__file__).with_name('sanitize_shared_image.py')


class SharedImageTests(unittest.TestCase):
    def run_worker(self, source, output):
        result = subprocess.run([sys.executable, '-X', 'utf8', '-B', str(SCRIPT),
            '--input', str(source), '--output', str(output)], capture_output=True,
            text=True, encoding='utf-8', timeout=10)
        self.assertEqual(result.stderr, '')
        self.assertEqual(len(result.stdout.splitlines()), 1)
        return result.returncode, json.loads(result.stdout)

    def test_exif_orientation_metadata_stripping_and_canonical_jpeg(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'input.upload'; target = root / 'output.jpg'
            image = Image.new('RGB', (40, 20), 'green'); exif = image.getexif()
            exif[274] = 6; exif[270] = 'private metadata sentinel'
            image.save(source, 'JPEG', exif=exif, comment=b'private comment')
            code, result = self.run_worker(source, target)
            self.assertEqual(code, 0)
            self.assertEqual((result['width'], result['height']), (20, 40))
            self.assertEqual(result['sizeBytes'], target.stat().st_size)
            self.assertEqual(result['sha256'], hashlib.sha256(target.read_bytes()).hexdigest())
            with Image.open(target) as canonical:
                self.assertEqual(canonical.format, 'JPEG'); self.assertEqual(canonical.mode, 'RGB')
                self.assertFalse(canonical.getexif()); self.assertNotIn('comment', canonical.info)
            self.assertNotIn(b'private metadata sentinel', target.read_bytes())

    def test_large_transparent_png_is_resized_and_background_is_white(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'image.png'; target = root / 'canonical.jpg'
            Image.new('RGBA', (3000, 1000), (255, 0, 0, 0)).save(source)
            code, result = self.run_worker(source, target)
            self.assertEqual(code, 0)
            self.assertEqual((result['width'], result['height']), (2048, 683))
            self.assertLessEqual(result['sizeBytes'], 5 * 1024 * 1024)
            with Image.open(target) as canonical:
                self.assertTrue(all(channel >= 250 for channel in canonical.getpixel((0, 0))))

    def test_bad_format_truncation_animation_and_pixel_limit_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'input'; target = root / 'output.jpg'
            for mode in ('gif', 'broken', 'animated', 'oversized', 'decompression-bomb'):
                if mode == 'gif': Image.new('RGB', (2, 2)).save(source, 'GIF')
                elif mode == 'broken': source.write_bytes(b'\x89PNG\r\n\x1a\ninvalid')
                elif mode == 'animated':
                    Image.new('RGBA', (2, 2), 'red').save(source, 'PNG', save_all=True,
                        append_images=[Image.new('RGBA', (2, 2), 'blue')], duration=100, loop=0)
                elif mode == 'oversized': Image.new('1', (6001, 4000)).save(source, 'PNG')
                else: Image.new('1', (8000, 6001)).save(source, 'PNG')
                code, result = self.run_worker(source, target)
                self.assertEqual(code, 1, mode); self.assertEqual(result, {'error': 'IMAGE_INVALID'}, mode)
                self.assertFalse(target.exists(), mode)


if __name__ == '__main__':
    unittest.main()
