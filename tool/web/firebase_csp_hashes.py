#!/usr/bin/env python3
"""firebase.json の CSP（script-src）に要る Firebase のインラインスクリプトのハッシュを出す。設計は docs/technical/web-hosting.md

    python tool/web/firebase_csp_hashes.py

firebase_core_web は SDK ごとに `window.ff_trigger_<var> = ...import("<JS SDK の URL>")` というインラインスクリプトを
差し込む（Trusted Types の有無で字下げが違う 2 通り）。URL に JS SDK の版が入るので、firebase_core_web が上がると変わる。
.dart_tool/package_config.json から入っている firebase_core_web を探し、テンプレートが想定どおりか確かめてから計算する。
"""
import base64
import hashlib
import json
import pathlib
import re
import sys
from urllib.parse import unquote, urlparse

ROOT = pathlib.Path(__file__).resolve().parents[2]
# (JS SDK のファイル名, windowVar)。使っている SDK だけ（firebase_core / auth / database / app_check）
SERVICES = [('app', 'firebase_core'), ('auth', 'firebase_auth'), ('database', 'firebase_database'),
            ('app-check', 'firebase_app_check')]

TRUSTED = (
    '            window.ff_trigger_{w} = async (callback) => {{\n'
    '              console.debug("Initializing Firebase {w}");\n'
    '              callback(await import("{u}"));\n'
    '            }};\n'
    '          ')
PLAIN = (
    '      window.ff_trigger_{w} = async (callback) => {{\n'
    '        console.debug("Initializing Firebase {w}");\n'
    '        callback(await import("{u}"));\n'
    '      }};\n'
    '    ')


def package_dir(name: str) -> pathlib.Path:
    cfg = json.loads((ROOT / '.dart_tool' / 'package_config.json').read_text(encoding='utf-8'))
    for p in cfg['packages']:
        if p['name'] == name:
            path = unquote(urlparse(p['rootUri']).path)
            return pathlib.Path(path.lstrip('/') if re.match(r'^/[A-Za-z]:', path) else path)
    sys.exit(f'{name} が package_config.json に無い。flutter pub get を先に')


def main() -> None:
    src = package_dir('firebase_core_web') / 'lib' / 'src'
    version = re.search(r"supportedFirebaseJsSdkVersion = '([^']+)'", (src / 'firebase_sdk_version.dart').read_text()).group(1)
    dart = (src / 'firebase_core_web.dart').read_text(encoding='utf-8')
    for t in (TRUSTED, PLAIN):
        probe = t.format(w='$windowVar', u='$stringUrl')
        if probe not in dart:
            sys.exit('firebase_core_web の injectSrcScript のテンプレートが変わった。このスクリプトを合わせること')
    print(f'# firebase_core_web {src.parents[1].name}, JS SDK {version}', file=sys.stderr)
    hashes = []
    for name, var in SERVICES:
        url = f'https://www.gstatic.com/firebasejs/{version}/firebase-{name}.js'
        for t in (TRUSTED, PLAIN):
            digest = hashlib.sha256(t.format(w=var, u=url).encode('utf-8')).digest()
            hashes.append(f"'sha256-{base64.b64encode(digest).decode()}'")
    print(' '.join(hashes))


if __name__ == '__main__':
    main()
