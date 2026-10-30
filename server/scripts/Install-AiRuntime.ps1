param(
    [string]$PythonExecutable,
    [string]$ModelPath,
    [switch]$Configure
)
$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $serverRoot
$venv = Join-Path $serverRoot '.tools\ai-venv'
$venvPython = Join-Path $venv 'Scripts\python.exe'
$worker = Join-Path $serverRoot 'ai\worker.py'
if (-not $PythonExecutable) {
    if (Get-Command py.exe -ErrorAction SilentlyContinue) {
        $PythonExecutable = (& py.exe -3.11 -c 'import sys; print(sys.executable)').Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Install CPython 3.11 x64 or pass -PythonExecutable.' }
    } else {
        $PythonExecutable = (Get-Command python.exe -ErrorAction Stop).Source
    }
}
if (-not (Test-Path -LiteralPath $PythonExecutable -PathType Leaf)) {
    $PythonExecutable = (Get-Command $PythonExecutable -ErrorAction Stop).Source
}
& $PythonExecutable -c 'import sys,struct; assert sys.version_info[:2]==(3,11) and struct.calcsize("P")==8, "CPython 3.11 x64 is required"'
if ($LASTEXITCODE -ne 0) { throw 'Unsupported Python; no environment was modified.' }
if (-not $ModelPath) {
    $ModelPath = Join-Path $projectRoot 'app\android\app\src\main\assets\mango_detector.onnx'
}
$ModelPath = (Resolve-Path -LiteralPath $ModelPath -ErrorAction Stop).Path
if ((Get-FileHash -LiteralPath $ModelPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne '8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41') {
    throw 'Model SHA256 does not match this serving release; do not relabel another checkpoint.'
}
if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    if (Test-Path -LiteralPath $venv) { throw 'Partial AI environment exists; inspect it before retrying.' }
    & $PythonExecutable -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the private AI environment.' }
}
& $venvPython -c 'import sys; assert sys.version_info[:2]==(3,11)'
if ($LASTEXITCODE -ne 0) { throw 'Existing private environment is incompatible.' }
& $venvPython -m pip --isolated install --index-url https://pypi.org/simple --only-binary=:all: -r (Join-Path $serverRoot 'ai\requirements-ai.txt')
if ($LASTEXITCODE -ne 0) { throw 'AI dependency installation failed; inspect retained output, do not enable AI.' }
$oldWorkerDirectory = $env:FRUITVISION_WORKER_DIRECTORY
$oldModel = $env:FRUITVISION_MODEL_PATH
$oldNoUserSite = $env:PYTHONNOUSERSITE
try {
    $env:FRUITVISION_WORKER_DIRECTORY = Split-Path -Parent $worker
    $env:FRUITVISION_MODEL_PATH = $ModelPath
    $env:PYTHONNOUSERSITE = '1'
    $preflight = @'
import sys, os, json
sys.path.insert(0, os.environ['FRUITVISION_WORKER_DIRECTORY'])
import numpy as np
import onnxruntime, cv2, PIL
from PIL import Image
from worker import Detector
detector = Detector()
objects, capped = detector.detect(Image.new('RGB', (480, 480), (128, 128, 128)))
assert not objects and not capped, 'Neutral fixture unexpectedly detected fruit'
print(json.dumps({'ready': True, 'python': sys.version.split()[0], 'ort': onnxruntime.__version__, 'numpy': np.__version__, 'pillow': PIL.__version__, 'opencv': cv2.__version__, 'providers': detector.session.get_providers(), 'neutral_fixture_objects': len(objects)}))
'@
    & $venvPython -X utf8 -B -c $preflight
    if ($LASTEXITCODE -ne 0) { throw 'Real AI preflight failed; AI configuration has not been changed.' }
} finally {
    $env:FRUITVISION_WORKER_DIRECTORY = $oldWorkerDirectory
    $env:FRUITVISION_MODEL_PATH = $oldModel
    $env:PYTHONNOUSERSITE = $oldNoUserSite
}
if ($Configure) {
    $privateRoot = Join-Path $serverRoot '.local'
    $settingsPath = Join-Path $privateRoot 'runtime.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) { throw 'Run Initialize-Local.ps1 first to create private database settings.' }
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    Copy-Item -LiteralPath $settingsPath -Destination (Join-Path $privateRoot "runtime.before-ai-$stamp.json")
    $ai = [ordered]@{
        RunEnabled = $true
        PythonPath = $venvPython
        WorkerPath = $worker
        PythonModulePath = Join-Path $venv 'Lib\site-packages'
        PythonExtraModulePath = ''
        ModelPath = $ModelPath
        ModelName = 'FruitVision Tiny — nhận diện và đếm quả'
        DataRoot = Join-Path $privateRoot 'ai'
    }
    $settings | Add-Member -NotePropertyName Ai -NotePropertyValue $ai -Force
    $temporary = Join-Path $privateRoot ('runtime-ai-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $settingsPath -Force
    Write-Output 'Private AI configuration updated; restart only the owned API to apply it. Database settings and secrets were preserved.'
} else {
    Write-Output 'Private CPU AI environment verified. Use -Configure to update private runtime.json after backing up the running service.'
}
