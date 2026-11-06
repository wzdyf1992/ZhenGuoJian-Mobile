import argparse
import re
import shutil
import zipfile
from pathlib import Path

from app_build import BuildVariant

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='校验并归档真果鉴 Android APK 安装包')
parser.add_argument('--abi', action='append', choices=['arm64-v8a', 'armeabi-v7a', 'x86_64'])
options = parser.parse_args()
variant = BuildVariant()

match = re.search(r'^version:\s*([\w.+-]+)\s*$', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE)
if not match:
    raise SystemExit('pubspec.yaml 缺少合法版本号。')
version = match.group(1)
output = root / 'dist' / 'android'
output.mkdir(parents=True, exist_ok=True)
artifacts = []

for abi in options.abi or ['arm64-v8a', 'armeabi-v7a', 'x86_64']:
    source = root / 'build' / 'app' / 'outputs' / 'flutter-apk' / f'app-{abi}-release.apk'
    if not source.is_file():
        raise SystemExit('缺少 APK：' + str(source))
    with zipfile.ZipFile(source) as archive:
        names = set(archive.namelist())
        required = [
            f'lib/{abi}/{library}'
            for library in ['libduanju_core.so', 'libflutter.so', 'libapp.so', 'libmpv.so', 'libffmpegkit.so']
        ]
        missing = set(required) - names
        if missing:
            raise SystemExit('APK 缺少原生库：' + ', '.join(sorted(missing)))
    target = output / f'{variant.slug}-{version}-{abi}.apk'
    shutil.copy2(source, target)
    artifacts.append(target)

for artifact in artifacts:
    print(artifact)
