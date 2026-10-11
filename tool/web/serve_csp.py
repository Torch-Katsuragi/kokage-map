#!/usr/bin/env python3
"""build/web を firebase.json の headers つきで配る手元用サーバ（CSP の確認用）。設計は docs/technical/web-hosting.md

    python tool/web/serve_csp.py            # http://localhost:8099/
    python tool/web/serve_csp.py --port 8100 --report

Windows の `firebase serve` / hosting エミュレータは headers を付けない（web-hosting.md の注意）ので、その代わり。
- `hosting.headers` の `source: "**"` の組だけを全レスポンスに付ける（キャッシュ系の組は手元では要らない）
- `hosting.rewrites` の `** -> /index.html` 相当: ファイルが無いパスは index.html を返す（ディレクトリは index.html）
- `--report`: CSP（強制・Report-Only とも）に `report-uri /__csp_report` を足し、届いた違反を標準出力と
  .temp/csp_reports.jsonl に書く。worker の中の違反などコンソールで拾い損ねるものも集まる
"""
import argparse
import http.server
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
REPORT_PATH = '/__csp_report'
CSP_KEYS = ('content-security-policy', 'content-security-policy-report-only')


def load_headers(report: bool) -> list[tuple[str, str]]:
    cfg = json.loads((ROOT / 'firebase.json').read_text(encoding='utf-8'))
    out = []
    for group in cfg['hosting'].get('headers', []):
        if group.get('source') != '**':
            continue
        for h in group['headers']:
            value = h['value']
            if report and h['key'].lower() in CSP_KEYS:
                value = f'{value}; report-uri {REPORT_PATH}'
            out.append((h['key'], value))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=8099)
    ap.add_argument('--dir', default=str(ROOT / 'build' / 'web'))
    ap.add_argument('--report', action='store_true')
    args = ap.parse_args()

    public = pathlib.Path(args.dir).resolve()
    if not (public / 'index.html').is_file():
        sys.exit(f'{public}/index.html が無い。先に flutter build web --release')
    headers = load_headers(args.report)
    report_log = ROOT / '.temp' / 'csp_reports.jsonl'
    if args.report:
        report_log.parent.mkdir(exist_ok=True)

    class Handler(http.server.SimpleHTTPRequestHandler):
        extensions_map = {
            **http.server.SimpleHTTPRequestHandler.extensions_map,
            '.wasm': 'application/wasm',
            '.js': 'text/javascript',
            '.mjs': 'text/javascript',
            '.json': 'application/json',
        }

        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(public), **kw)

        def end_headers(self):
            for k, v in headers:
                self.send_header(k, v)
            self.send_header('Cache-Control', 'no-store')
            super().end_headers()

        def translate_path(self, path):
            p = pathlib.Path(super().translate_path(path))
            if p.is_dir():
                p = p / 'index.html'
            if not p.exists():
                p = public / 'index.html'  # SPA の rewrite
            return str(p)

        def do_POST(self):
            if self.path != REPORT_PATH:
                self.send_error(404)
                return
            body = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode('utf-8', 'replace')
            print(f'[CSP] {body}', flush=True)
            with report_log.open('a', encoding='utf-8') as f:
                f.write(body.replace('\n', ' ') + '\n')
            self.send_response(204)
            self.end_headers()

        def log_message(self, fmt, *a):
            pass

    print(f'serving {public} on http://localhost:{args.port}/ (report={args.report})', flush=True)
    http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
