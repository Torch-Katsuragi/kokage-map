#!/usr/bin/env python3
"""こかげマップ web 版の開発用: テスト用のプロジェクトフォルダを OPFS に流し込むための配信サーバ。

web 版はふつう File System Access API でフォルダを選ぶが、その選択と許可の確認は人が押さないと通らない。
ブラウザのサイト専用領域（OPFS）なら要らないので、ここに入れたフォルダを `#/map?project=opfs:<名前>` で
開けば、ブラウザを外から動かすだけで確認が回る（2026-09-30）。

    python tool/web_opfs.py <フォルダ> [--port 8098]

配るもの（どれも CORS 付き）:
    /manifest.json      フォルダの中のファイル（隠しファイルも）の相対パス
    /files/<相対パス>   ファイルの中身
    /web_opfs.js        アプリのページの中で動かす道具（seed / list / read / remove）

アプリのページ（例 http://localhost:8099）の中で（DevTools のコンソールか、ブラウザを動かす道具から）:

    const m = await import('http://localhost:8098/web_opfs.js');
    await m.seed('http://localhost:8098', 'Kitayama-2026');   // 空にしてから丸ごと入れる
    location.hash = '#/map?project=opfs:Kitayama-2026';        // 開く（起動時の URL に書いてもよい）
    await m.list('Kitayama-2026');                             // 確認
    await m.read('Kitayama-2026/Kitayama-2026.qgs');

⚠ OPFS はサイト（origin）ごと。localhost:8099 に入れたものは本番のドメインからは見えない。
"""
import argparse
import json
import pathlib
import urllib.parse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

TOOL = pathlib.Path(__file__).resolve().parent


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", type=pathlib.Path)
    ap.add_argument("--port", type=int, default=8098)
    args = ap.parse_args()
    folder = args.folder.resolve()
    if not folder.is_dir():
        raise SystemExit(f"{folder} はフォルダではない")

    class Handler(SimpleHTTPRequestHandler):
        def end_headers(self) -> None:
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            super().end_headers()

        def _send(self, body: bytes, ctype: str) -> None:
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            path = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
            if path == "/manifest.json":
                files = sorted(p.relative_to(folder).as_posix() for p in folder.rglob("*") if p.is_file())
                self._send(json.dumps({"name": folder.name, "files": files}, ensure_ascii=False).encode(), "application/json")
            elif path == "/web_opfs.js":
                self._send((TOOL / "web_opfs.js").read_bytes(), "text/javascript")
            elif path.startswith("/files/"):
                target = (folder / path[len("/files/"):]).resolve()
                if folder not in target.parents or not target.is_file():
                    self.send_error(404)
                    return
                self._send(target.read_bytes(), "application/octet-stream")
            else:
                self.send_error(404)

    print(f"{folder} を http://localhost:{args.port} で配る（Ctrl+C で止める）")
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
