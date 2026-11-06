import argparse
import os
import platform
import shutil
import subprocess
from pathlib import Path

from app_build import BuildVariant

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='编译真果鉴 Android Go 原生核心动态库')
parser.add_argument('--abi', action='append', choices=['arm64-v8a', 'armeabi-v7a', 'x86_64'])
options = parser.parse_args()
variant = BuildVariant()

environment = os.environ.copy()
environment.setdefault('GOPROXY', 'https://goproxy.cn,direct')
environment.setdefault('GOSUMDB', 'off')
environment['CGO_ENABLED'] = '1'
go = shutil.which('go')
if not go:
    raise SystemExit('请先安装 Go 1.24.1 或更新版本。')
bootstrap_env = environment.copy()
bootstrap_env['GOSUMDB'] = os.environ.get('GOSUMDB', 'sum.golang.org')
if bootstrap_env['GOSUMDB'] == 'off':
    bootstrap_env['GOSUMDB'] = 'sum.golang.org'
toolchain_root = subprocess.check_output(
    [go, 'env', 'GOROOT'],
    cwd=root / 'native',
    env=bootstrap_env,
    text=True,
).strip()
go = str(Path(toolchain_root) / 'bin' / ('go.exe' if platform.system() == 'Windows' else 'go'))

sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
if not sdk:
    raise SystemExit('请设置 ANDROID_HOME 为 Android SDK 目录。')
ndk = Path(os.environ.get('ANDROID_NDK_HOME', Path(sdk) / 'ndk' / '28.2.13676358'))
host = {'Darwin': 'darwin-x86_64', 'Linux': 'linux-x86_64', 'Windows': 'windows-x86_64'}[platform.system()]
compilers = ndk / 'toolchains' / 'llvm' / 'prebuilt' / host / 'bin'
mappings = {
    'arm64-v8a': ('arm64', 'aarch64-linux-android24-clang'),
    'armeabi-v7a': ('arm', 'armv7a-linux-androideabi24-clang'),
    'x86_64': ('amd64', 'x86_64-linux-android24-clang'),
}

for abi in options.abi or list(mappings):
    architecture, name = mappings[abi]
    compiler = compilers / (name + ('.cmd' if platform.system() == 'Windows' else ''))
    if not compiler.exists():
        raise SystemExit('缺少 Android NDK 编译器：' + str(compiler))
    output = root / 'android' / 'app' / 'src' / 'main' / 'jniLibs' / abi / 'libduanju_core.so'
    output.parent.mkdir(parents=True, exist_ok=True)
    build_env = environment.copy()
    build_env.update(
        GOOS='android',
        GOARCH=architecture,
        CC=str(compiler),
        CGO_LDFLAGS='-Wl,-z,max-page-size=16384',
    )
    if architecture == 'arm':
        build_env['GOARM'] = '7'
    print('Building ' + str(output.relative_to(root)), flush=True)
    subprocess.run(
        [
            go,
            'build',
            '-trimpath',
            '-buildmode=c-shared',
            '-ldflags=' + variant.linker_flags,
            '-o',
            str(output),
            './bridge',
        ],
        cwd=root / 'native',
        env=build_env,
        check=True,
    )
