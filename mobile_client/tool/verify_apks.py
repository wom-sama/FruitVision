"""Verify only the new API-client package, never historic model receipts."""
import argparse, hashlib, json, pathlib, re, subprocess, zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SDK = pathlib.Path.home() / 'AppData/Local/Android/Sdk/build-tools/36.0.0'
OUT = ROOT / 'build/app/outputs/apk/release'
parser=argparse.ArgumentParser()
parser.add_argument('--version-name',default='2.0.0')
parser.add_argument('--version-code',default=6000,type=int)
parser.add_argument('--output',default='verification/apk-verification.json')
parser.add_argument('--expected-signer-sha256',default='b254a31dc9fd217c68e076f8ac880dd151086904851fafd9f6c4c18f2905d971',
    help='Expected signer. Separate clone deployments must explicitly use their own key fingerprint; existing installs require their original signer.')
args=parser.parse_args()
assert re.fullmatch(r'[a-fA-F0-9]{64}',args.expected_signer_sha256), 'Expected signer must be a SHA-256 hex fingerprint'
receipt = []
for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64'):
    apk = OUT / f'app-{abi}-release.apk'
    badge = subprocess.check_output([str(SDK/'aapt.exe'),'dump','badging',str(apk)], text=True, encoding='utf8')
    assert f"versionCode='{args.version_code}'" in badge and f"versionName='{args.version_name}'" in badge
    assert "name='vn.mangodemo.mango_offline'" in badge
    assert "sdkVersion:'26'" in badge and "targetSdkVersion:'36'" in badge
    assert 'application-debuggable' not in badge
    perms = [line for line in badge.splitlines() if line.startswith('uses-permission:')]
    # AndroidX Core adds the app's own signature-only receiver permission.
    assert perms == ["uses-permission: name='android.permission.INTERNET'",
        "uses-permission: name='android.permission.REQUEST_INSTALL_PACKAGES'",
        "uses-permission: name='vn.mangodemo.mango_offline.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'"]
    manifest = subprocess.check_output([str(SDK/'aapt.exe'),'dump','xmltree',str(apk),'AndroidManifest.xml'], text=True, encoding='utf8')
    assert 'usesCleartextTraffic' in manifest and 'allowBackup' in manifest
    assert 'protectionLevel' in manifest and '(type 0x11)0x2' in manifest
    for setting in ('usesCleartextTraffic', 'allowBackup'):
        assert any(setting in line and line.rstrip().endswith('0x0') for line in manifest.splitlines())
    signer = subprocess.check_output([str(SDK/'apksigner.bat'),'verify','--verbose','--print-certs',str(apk)], text=True, encoding='utf8')
    assert 'Verified using v2 scheme (APK Signature Scheme v2): true' in signer
    fingerprint = args.expected_signer_sha256.lower()
    assert fingerprint in signer
    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        assert not any(n.lower().endswith(('.onnx','.tflite','.pt','.pth','.ncnn','.param')) for n in names)
        libs = [n for n in names if n.startswith('lib/') and n.endswith('.so')]
        assert sorted(n.split('/')[-1] for n in libs) == ['libapp.so','libflutter.so'], libs
        assert all(n.startswith(f'lib/{abi}/') for n in libs)
        assert 'classes.dex' in names and 'assets/flutter_assets/AssetManifest.bin' in names
    receipt.append({'abi':abi,'path':str(apk),'bytes':apk.stat().st_size,
        'sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),'version':f'{args.version_name}+{args.version_code}',
        'v2Signature':True,'signerSha256':fingerprint,'platformPermissions':['INTERNET','REQUEST_INSTALL_PACKAGES'],
        'appSignatureOnlyReceiverPermission':True,
        'noAiRuntimeOrWeights':True,'cleartextDisabled':True,'backupDisabled':True,
        'signingNote':'Existing debug signer retained for course demo upgrades; not Play Store release signing.'})
destination=ROOT/args.output
destination.parent.mkdir(exist_ok=True,parents=True)
destination.write_text(json.dumps({'allPassed':True,'artifacts':receipt},indent=2),encoding='utf8')
print(json.dumps({'passed':3,'sizesMiB':[round(r['bytes']/1048576,2) for r in receipt]}))
