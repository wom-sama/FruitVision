# FruitVision one-job inference worker

`worker.py --job ABSOLUTE_JOB_JSON` reads `{id, mediaType: "image"|"video", inputPath, outputDirectory}`. Both paths must be absolute. The API creates these files and owns authorization, cancellation, queueing and deletion. The worker runs one job and exits; it opens no port, trains nothing and downloads nothing.

Stdout is NDJSON only: `progress` contains integer `progress` 0–99 and `framesProcessed`; `completed` contains `result` and the absolute `previewPath`; `error` contains a safe `message` and exits 1. An incomplete/invalid video never returns `completed`. Python diagnostics on stderr contain only a bounded exception class; codec logs are suppressed before OpenCV loads. The API must treat `completed` as the success signal, serve only its own fixed `preview.jpg`, and keep previews behind owner authorization.

## Runtime

Verified CPython 3.11, CPU `onnxruntime==1.31.1`, `numpy==2.0.2`, `Pillow==11.3.0`, and `opencv-python-headless==4.13.0.92`. The process needs imports `onnxruntime`, `numpy`, `PIL`, `cv2` plus the Python standard library. Current machine launch from the repository root:

```powershell
$env:PYTHONPATH="$PWD\server\.tools\ai_python;E:\kaggle\local\chat\.venv\Lib\site-packages"
& C:\Users\ADMIN\AppData\Local\Programs\Python\Python311\python.exe -X utf8 -B server/ai/worker.py --job C:\absolute\job.json
```

The worker sets OMP, MKL and OpenBLAS to two threads before numerical imports, ORT intra-op to two/inter-op to one with sequential CPU execution, and OpenCV decoder/processing to two threads. No GPU provider or background inference daemon is used. Runtime installation provenance is [../docs/ai-runtime-install.json](../docs/ai-runtime-install.json).

The model defaults to [the existing app asset](../../app/android/app/src/main/assets/mango_detector.onnx). `FRUITVISION_MODEL_PATH` may specify a deployment location for that exact file. The accompanying [detector metadata](../../app/android/app/src/main/assets/detector_metadata.json) remains required at its repository location. This is deliberately one pinned serving model, with no model aliases or automatic fallback:

* SHA-256: `8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41`, 20,307,691 bytes.
* Input RGB float32 `[1,3,480,480]`, normalized by 255. Pillow bilinear resize matches the legacy native/Kotlin 22-bit rounded two-pass resize; dimensions use floor, centered integer padding, RGB 128.
* Exact direct outputs: `boxes [1,4725,4]`, `scores [1,4725]`, `species_ids [1,4725]`, `stage_ids [1,4725]`, `stage_scores [1,4725,2]`.
* Legacy `NativeDetector.select` reads serving metadata without overriding it: confidence .35, class-agnostic IoU NMS .5, max 64. Coordinates are clipped to the oriented original image before NMS, and duplicate candidates do not consume the survivor budget.
* Stage labels are `Xanh / chưa chín` and `Chín`; accepted stage confidence is at least .6. Generic geometry/species 2 and weak stages display `Chưa xác định`, with code -1. Species outputs never become fruit identity labels.

## Bounds and count meaning

Images must actually decode as JPEG/PNG, at most 12 MiB and 24 million pixels. EXIF transpose is applied before inference and preview; coordinates describe this oriented image. PNG alpha is ignored during RGB conversion, matching the legacy RGB channel contract.

Videos must have a recognized MP4 `ftyp` header and successfully decode using FFmpeg/OpenCV. Metadata needs a finite positive FPS (up to 240), 1–3600 integral frames and duration at most 120 seconds. Resolution is at most 1920 by 1080, allowing portrait orientation. Decoder metadata rotation uses OpenCV's FFmpeg orientation support; actual decoded dimensions are revalidated. Every decoded frame is inferred. Non-increasing/invalid timestamps, excessive real frame counts, early EOF, decode failure or the 165-second worker deadline reject the whole job. The API has a separate 180-second timeout. A file within input bounds can still exceed CPU processing time and must then be shortened.

Results use schema `fruitvision-ai-v1`. `framesProcessed` counts inference frames, `maxVisibleCount` is the largest served per-frame detection count, `confirmedTrackCount` counts geometry tracks observed at least twice, and `lineCrossingCount` counts confirmed IDs crossing normalized y=.5 in either direction at most once (±.02 hysteresis). These quantities are never summed to infer unique physical fruit. Images have `confirmedTrackCount=0`; their object count is `maxVisibleCount`.

Tracking ports the app's Hungarian assignment, .2 IoU gate, velocity prediction, two-second gap, two-observation confirmation and confidence-weighted stage votes. Association ignores species/stages to avoid inventing new IDs when classification changes. Grade ties keep the earlier accumulated label. Active tracks cap at 1024 and total history at 10000; exceeding either fails explicitly. Long absence/re-entry can create a new ID. This is a geometry estimate, without a re-identification encoder. Video grade counts sum confirmed tracks; image grade counts sum image detections. Map keys are the two Vietnamese stage labels plus `Chưa xác định`.

`objects` describes the representative frame with the highest visible count (earliest tie). Video objects contain IDs and final stable track stage votes; generic observations remain ungraded. The fixed annotated JPEG shows those boxes/IDs, with a visible center counting line for video. No mass estimate is produced.

## Source and license limitations

Preserve [SOURCE_ATTRIBUTION.json](../../app/android/app/src/main/assets/SOURCE_ATTRIBUTION.json), [YOLOX_LICENSE.txt](../../app/android/app/src/main/assets/YOLOX_LICENSE.txt) (Apache-2.0), and the source records with any distribution. RaspGrade source admission (`../../artifacts/raspgrade_primary_source_20261015/root_geometry_admission.json` in the local research archive) retains the stricter author Hugging Face **CC-BY-NC-4.0** restriction and the conflicting Zenodo **CC-BY-4.0** record: data and resulting model are **NONCOMMERCIAL DEMO ONLY**, without commercial clearance. Additional context manifest (`../../artifacts/additional_conveyor_context_cache_20261015/manifest.json` in the local research archive) retains per-source CC0-1.0, CC-BY-2.0 and CC-BY-SA-2.0/3.0 attribution, and native context manifest (`../../artifacts/conveyor_native_context_cache_20261015/additive_manifest.json` in the local research archive) retains its source restrictions. These are references to existing immutable scientific/source artifacts; this worker does not alter them.

The model's source-stage performance does not establish field ripeness. The shipped metadata explicitly says user-video quality remains FAIL, with possible missed fruit, duplicate boxes and incorrect source stages. Geometry-only fruit remains ungraded. Smoke completion is execution evidence, not accuracy, throughput, physical split independence or release qualification.

## Verification

```powershell
& C:\Users\ADMIN\AppData\Local\Programs\Python\Python311\python.exe -X utf8 -B -m unittest discover -s server/ai -v
& C:\Users\ADMIN\AppData\Local\Programs\Python\Python311\python.exe -X utf8 -B server/ai/smoke_probe.py
```

Use the runtime `PYTHONPATH` above. Unit tests cover clipped class-agnostic NMS, duplicate survivor budget, invalid model values/distributions, abstention, global matching, confirmation, stable votes, crossing/re-entry/history limits, image format/dimensions/EXIF, video dimensions/FPS/duration/frames, every-frame decode and truncated MP4 rejection, positive-area serialization and NDJSON errors/progress.

The bounded smoke runs the real pinned ORT graph on one bundled image and the eight-frame codec fixture. It writes protocol, results, SHA provenance and previews to ignored `.test-results/`. `parity_fixture.png` has SHA-256 `2d859c4c39a44f576db18da3ddf422bf70b91aef13fce40c7ae069fe4e7f6737`; the codec MP4 has SHA-256 `a86aa8a38f2eb4ee468e302b375d82ec8393e978e23d63c014b16c6df8d60b28`. The bundled `parity_expected.json` belongs to legacy grader SHA `819d023f…`, so it is not used as an oracle for this detector. A successful smoke does not claim current Android/worker raw-tensor parity.

The local research archive paths above are provenance references, not files distributed in this repository. Public per-source records and license notices are retained in the linked `SOURCE_ATTRIBUTION.json` and accompanying asset notices.
