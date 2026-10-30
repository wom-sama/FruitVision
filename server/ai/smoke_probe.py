"""Bounded real-ORT smoke: one bundled image and the eight-frame codec fixture."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys


root = Path(__file__).resolve().parents[2]
destination = Path(__file__).resolve().parent / '.test-results'
destination.mkdir(exist_ok=True)
report = {'scope': 'Smoke only; no accuracy/throughput/physical-identity qualification.', 'fixtures': []}
for kind, relative in [('image', 'app/android/app/src/main/assets/parity_fixture.png'),
                       ('video', 'app/android/app/src/androidTest/assets/codec_fixture.mp4')]:
    source = root / relative
    output = destination / f'fixture-{kind}'
    job = destination / f'{kind}-job.json'
    job.write_text(json.dumps({'id': f'fixture-{kind}', 'mediaType': kind,
        'inputPath': str(source), 'outputDirectory': str(output)}), encoding='utf-8')
    execution = subprocess.run([sys.executable, '-X', 'utf8', '-B', str(Path(__file__).with_name('worker.py')),
                               '--job', str(job)], capture_output=True, text=True, encoding='utf-8', timeout=25)
    (destination / f'{kind}-protocol.ndjson').write_text(execution.stdout, encoding='utf-8')
    messages = [json.loads(line) for line in execution.stdout.splitlines()]
    if execution.returncode or not messages or messages[-1].get('type') != 'completed':
        raise RuntimeError(f'{kind} smoke failed: {messages[-1:]}; stderr={execution.stderr[:256]}')
    result = messages[-1]['result']
    output.joinpath('result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    report['fixtures'].append({'mediaType': kind, 'source': relative,
        'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'sourceBytes': source.stat().st_size, 'exitCode': execution.returncode,
        'modelSha256': result['modelSha256'], 'framesProcessed': result['framesProcessed'],
        'maxVisibleCount': result['maxVisibleCount'], 'confirmedTrackCount': result['confirmedTrackCount'],
        'lineCrossingCount': result['lineCrossingCount'], 'processingSeconds': result['processingSeconds'],
        'protocolMessages': len(messages), 'stderrBytes': len(execution.stderr.encode('utf-8'))})
report['note'] = 'parity_expected.json targets legacy student SHA819d023f…; it is not a parity oracle for the pinned detector.'
destination.joinpath('smoke-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(report, ensure_ascii=False, indent=2))
