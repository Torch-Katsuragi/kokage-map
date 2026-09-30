// こかげマップ web 版の開発用: ブラウザのサイト専用領域（OPFS）にテスト用のプロジェクトを流し込む・読み出す。
//
// OPFS はフォルダ選択も許可の確認も要らないので、ブラウザを外から動かすだけで web 版の確認ができる
// （File System Access API のフォルダ選択は、人が押さないと通らない）。
// アプリは `#/map?project=opfs:<名前>` で OPFS の中のフォルダを開く。
//
// ⚠ OPFS はサイト（origin）ごと。必ずアプリのページ（例 http://localhost:8099）の中で動かす。
// 使い方は tool/web_opfs.py の冒頭。
//
//   const m = await import('http://localhost:8098/web_opfs.js');
//   await m.seed('http://localhost:8098', 'Kitayama-2026');   // 丸ごと入れ直す
//   await m.list('Kitayama-2026');                              // [[パス, 大きさ], ...]
//   await m.read('Kitayama-2026/Kitayama-2026.qgs');            // 中身（文字）

async function root() {
  return navigator.storage.getDirectory();
}

/// `a/b/c` の親フォルダを（作りながら）辿る
async function dirOf(path, create) {
  const parts = path.split('/').filter(Boolean);
  const name = parts.pop();
  let dir = await root();
  for (const p of parts) dir = await dir.getDirectoryHandle(p, { create });
  return [dir, name];
}

/// [name] を空にしてから、配信元 [base] の一覧どおりにファイルを書く
export async function seed(base, name) {
  const r = await root();
  try {
    await r.removeEntry(name, { recursive: true });
  } catch (_) {
    // 無ければよい
  }
  const manifest = await (await fetch(`${base}/manifest.json`)).json();
  for (const rel of manifest.files) {
    const res = await fetch(`${base}/files/${rel.split('/').map(encodeURIComponent).join('/')}`);
    if (!res.ok) throw new Error(`${rel}: ${res.status}`);
    const [dir, file] = await dirOf(`${name}/${rel}`, true);
    const handle = await dir.getFileHandle(file, { create: true });
    const w = await handle.createWritable();
    await w.write(await res.arrayBuffer());
    await w.close();
  }
  return manifest.files.length;
}

/// [name] の下のファイルを [パス, 大きさ] で返す（名前順）
export async function list(name) {
  const out = [];
  async function walk(dir, prefix) {
    for await (const [n, h] of dir.entries()) {
      if (h.kind === 'directory') await walk(h, `${prefix}${n}/`);
      else out.push([`${prefix}${n}`, (await h.getFile()).size]);
    }
  }
  const [parent, dirName] = await dirOf(name, false);
  await walk(await parent.getDirectoryHandle(dirName), '');
  return out.sort((a, b) => a[0].localeCompare(b[0]));
}

/// ファイルを文字で読む
export async function read(path) {
  const [dir, file] = await dirOf(path, false);
  return (await (await dir.getFileHandle(file)).getFile()).text();
}

/// [name] を消す
export async function remove(name) {
  await (await root()).removeEntry(name, { recursive: true });
}
