// こかげマップ web 版の GDAL を動かす専用 worker（lib/core/gdal/gdal_web.dart から使う）。設計は docs/technical/gdal.md「web」
//
// GDAL 3.13 + PROJ 9.9 を emscripten で焼いたもの（web/gdal3/<組>/gdal.{js,wasm,data}、third_party/gdal/build_web.sh）を
// この worker の中で起こし、GDAL のユーティリティ（gdal_utils.h）を引数の文字列のまま呼ぶ。
// Android の FFI 実装（lib/core/gdal/gdal_ffi.dart）と同じ形・同じ振る舞いにする:
//   - `-oo` `-if` は抜き出して GDALOpenEx に渡す（データセットは呼ぶ側が開く）
//   - shp に `.cpg` も DBF の LDID も無ければ `-oo ENCODING=CP932`（呼ぶ側が ENCODING を渡していればそちら）
//   - 1 回の呼び出しのあいだ CPL_ACCUM_ERROR_MSG=ON で、途中のエラーも最後のメッセージに溜める
//   - GDAL_DATA・proj.db の在処、PROJ_NETWORK=OFF はドライバ登録の前に 1 回だけ
//
// 受け渡し:
//   入力: ファイル（File）の配列。WORKERFS で /input/j<n>/ に mount する（中身はコピーせず、読むときに File から切り出す）
//   出力: /output/j<n>/ に書かせ、中のファイルを全部 { rel, bytes } で返す（ArrayBuffer は transfer。コピーは 1 回）
//   ジョブごとに作って、終わったら消す
//
// ⚠ WASM のメモリは 4GB まで伸びる。2GB を超えたポインタは JS の数としては負になりうるので、ヒープを引くときは `>>> 0` / `>>> 2`
'use strict';

const GDAL_OF_RASTER = 0x02;
const GDAL_OF_VECTOR = 0x04;
const GDAL_OF_VERBOSE_ERROR = 0x40;
const CE_FAILURE = 3;

// shp の文字コードの既定（gdal_ffi.dart の shapefileFallbackEncoding と同じ）
const SHAPEFILE_FALLBACK_ENCODING = 'CP932';

let ready = null; // Promise（init の完了）
let M = null; // emscripten の Module
let C = null; // cwrap した C 関数
let log = []; // いまのジョブの stderr
let seq = 0;
let broken = null; // abort した理由（以後は何も受けない）

self.onmessage = onMessage;

function onMessage(event) {
  const msg = event.data;
  if (msg.op === 'init') {
    ready = Promise.resolve().then(() => init(msg.base));
    ready.then(
      () => self.postMessage({ id: msg.id, ok: true, result: null }),
      (e) => self.postMessage({ id: msg.id, ok: false, fatal: true, error: String((e && e.message) || e) }),
    );
    return;
  }
  (ready || Promise.reject(new Error('init の前に呼ばれた'))).then(() => {
    if (broken) throw new Error(`GDAL が停止している: ${broken}`);
    log = [];
    const transfer = [];
    const result = msg.op === 'version' ? C.versionInfo('RELEASE_NAME') : run(msg, transfer);
    self.postMessage({ id: msg.id, ok: true, result, log }, transfer);
  }).catch((e) => {
    // WebAssembly の RuntimeError（メモリ不足など）や abort の後は Module が壊れている。呼び手に作り直させる
    const fatal = !!broken || (e instanceof WebAssembly.RuntimeError);
    if (fatal && !broken) broken = String(e && e.message);
    self.postMessage({ id: msg.id, ok: false, fatal, error: String((e && e.message) || e), log });
  });
}

async function init(base) {
  importScripts(`${base}gdal.js`);
  M = await self.createGdalModule({
    locateFile: (name) => `${base}${name}`,
    print: (text) => log.push(text),
    printErr: (text) => log.push(text),
    onAbort: (what) => { broken = String(what); },
  });
  const n = 'number';
  const s = 'string';
  C = {
    allRegister: M.cwrap('GDALAllRegister', null, []),
    versionInfo: M.cwrap('GDALVersionInfo', s, [s]),
    openEx: M.cwrap('GDALOpenEx', n, [s, n, n, n, n]),
    close: M.cwrap('GDALClose', n, [n]),
    errorReset: M.cwrap('CPLErrorReset', null, []),
    lastErrorMsg: M.cwrap('CPLGetLastErrorMsg', s, []),
    lastErrorType: M.cwrap('CPLGetLastErrorType', n, []),
    setGlobalConfig: M.cwrap('CPLSetConfigOption', null, [s, s]),
    setConfig: M.cwrap('CPLSetThreadLocalConfigOption', null, [s, s]),
    setProjPaths: M.cwrap('OSRSetPROJSearchPaths', null, [n]),
    infoOptionsNew: M.cwrap('GDALInfoOptionsNew', n, [n, n]),
    info: M.cwrap('GDALInfo', n, [n, n]),
    infoOptionsFree: M.cwrap('GDALInfoOptionsFree', null, [n]),
    vectorInfoOptionsNew: M.cwrap('GDALVectorInfoOptionsNew', n, [n, n]),
    vectorInfo: M.cwrap('GDALVectorInfo', n, [n, n]),
    vectorInfoOptionsFree: M.cwrap('GDALVectorInfoOptionsFree', null, [n]),
    vtOptionsNew: M.cwrap('GDALVectorTranslateOptionsNew', n, [n, n]),
    vectorTranslate: M.cwrap('GDALVectorTranslate', n, [s, n, n, n, n, n]),
    vtOptionsFree: M.cwrap('GDALVectorTranslateOptionsFree', null, [n]),
    warpOptionsNew: M.cwrap('GDALWarpAppOptionsNew', n, [n, n]),
    warp: M.cwrap('GDALWarp', n, [s, n, n, n, n, n]),
    warpOptionsFree: M.cwrap('GDALWarpAppOptionsFree', null, [n]),
    trOptionsNew: M.cwrap('GDALTranslateOptionsNew', n, [n, n]),
    translate: M.cwrap('GDALTranslate', n, [s, n, n, n]),
    trOptionsFree: M.cwrap('GDALTranslateOptionsFree', null, [n]),
    fileList: M.cwrap('GDALGetFileList', n, [n]),
    cslDestroy: M.cwrap('CSLDestroy', null, [n]),
    vsiFree: M.cwrap('VSIFree', null, [n]),
  };
  // プロセス全体の設定（gdal_ffi.dart の initProcess と同じ）。データは gdal.data から MEMFS に展開済み
  withArgv(['/proj'], (argv) => C.setProjPaths(argv));
  C.setGlobalConfig('PROJ_DATA', '/proj');
  C.setGlobalConfig('GDAL_DATA', '/gdal_data');
  C.setGlobalConfig('CPL_TMPDIR', '/tmp');
  C.setGlobalConfig('PROJ_NETWORK', 'OFF');
  C.allRegister();
  M.FS.mkdir('/input');
  M.FS.mkdir('/output');
}

// =============================================
// ジョブ
// =============================================

function run(msg, transfer) {
  const job = `j${++seq}`;
  const inDir = `/input/${job}`;
  const outDir = `/output/${job}`;
  const files = msg.files || [];
  M.FS.mkdir(inDir);
  M.FS.mount(M.FS.filesystems.WORKERFS, { files }, inDir);
  const config = splitConfig(msg.args || []);
  const src = splitSource(config.args);
  // KMZ などは呼ぶ側が /vsizip/ を付けてくる（msg.vsi）
  const main = `${msg.vsi || ''}${inDir}/${msg.main}`;
  for (const [k, v] of config.pairs) C.setConfig(k, v);
  C.setConfig('CPL_ACCUM_ERROR_MSG', 'ON');
  try {
    switch (msg.op) {
      case 'rasterInfo':
        return withDataset(main, GDAL_OF_RASTER, src, (ds) => runInfo(ds, src.rest, false));
      case 'vectorInfo':
        addShapefileEncoding(src, msg.main, files);
        return withDataset(main, GDAL_OF_VECTOR, src, (ds) => runInfo(ds, src.rest, true));
      case 'fileList':
        return withDataset(main, GDAL_OF_RASTER | GDAL_OF_VECTOR, src, (ds) => fileList(ds, `${inDir}/`));
      case 'vectorTranslate':
      case 'warp':
      case 'translate':
        M.FS.mkdir(outDir);
        try {
          for (const f of msg.dstFiles || []) {
            M.FS.writeFile(`${outDir}/${f.name}`, new Uint8Array(new FileReaderSync().readAsArrayBuffer(f)));
          }
          if (msg.op === 'vectorTranslate') addShapefileEncoding(src, msg.main, files);
          const flags = msg.op === 'vectorTranslate' ? GDAL_OF_VECTOR : GDAL_OF_RASTER;
          withDataset(main, flags, src, (ds) => runUtility(msg.op, ds, `${outDir}/${msg.dstName}`, src.rest));
          return collect(outDir, '', transfer);
        } finally {
          removeTree(outDir);
        }
      default:
        throw new Error(`知らない操作: ${msg.op}`);
    }
  } finally {
    C.setConfig('CPL_ACCUM_ERROR_MSG', null);
    for (const [k] of config.pairs) C.setConfig(k, null);
    M.FS.unmount(inDir);
    M.FS.rmdir(inDir);
  }
}

/// `--config KEY VALUE` を抜き出す（コマンドラインと同じ書き方を受ける）
function splitConfig(args) {
  const pairs = [];
  const rest = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--config' && i + 2 < args.length) {
      pairs.push([args[i + 1], args[i + 2]]);
      i += 2;
    } else {
      rest.push(args[i]);
    }
  }
  return { pairs, args: rest };
}

/// 元のデータセットを開くための `-oo`（オープンオプション）と `-if`（ドライバ）を抜き出す（gdal_ffi.dart の _SourceArgs と同じ）
function splitSource(args) {
  const openOptions = [];
  const drivers = [];
  const rest = [];
  for (let i = 0; i < args.length; i += 1) {
    const a = args[i];
    if ((a === '-oo' || a === '-if') && i + 1 < args.length) {
      (a === '-oo' ? openOptions : drivers).push(args[i + 1]);
      i += 1;
    } else {
      rest.push(a);
    }
  }
  return { openOptions, drivers, rest };
}

/// `.cpg` も DBF の LDID も無い shp（か dbf）なら ENCODING=CP932 を足す（gdal_ffi.dart の needsShapefileFallbackEncoding と同じ）
function addShapefileEncoding(src, main, files) {
  if (src.openOptions.some((o) => o.toUpperCase().startsWith('ENCODING='))) return;
  const dot = main.lastIndexOf('.');
  if (dot < 0) return;
  const ext = main.substring(dot).toLowerCase();
  if (ext !== '.shp' && ext !== '.dbf') return;
  const base = main.substring(0, dot);
  const named = (e) => files.find((f) => f.name.startsWith(base) && f.name.length === base.length + 4
    && f.name.substring(base.length).toLowerCase() === e);
  if (named('.cpg')) return;
  const dbf = named('.dbf');
  if (!dbf || dbf.size < 32) return;
  const head = new Uint8Array(new FileReaderSync().readAsArrayBuffer(dbf.slice(0, 32)));
  if (head[29] === 0) src.openOptions.push(`ENCODING=${SHAPEFILE_FALLBACK_ENCODING}`);
}

function withDataset(path, flags, src, fn) {
  C.errorReset();
  const ds = withArgv(src.drivers, (drivers) => withArgv(src.openOptions, (oo) => C.openEx(
    path,
    flags | GDAL_OF_VERBOSE_ERROR,
    src.drivers.length ? drivers : 0,
    src.openOptions.length ? oo : 0,
    0,
  )));
  if (!ds) throw new Error(lastError(`開けない: ${path}`));
  try {
    return fn(ds);
  } finally {
    C.close(ds);
  }
}

function runInfo(ds, args, vector) {
  const what = vector ? 'ogrinfo' : 'gdalinfo';
  return withArgv(['-json', ...args], (argv) => {
    C.errorReset();
    const opts = vector ? C.vectorInfoOptionsNew(argv, 0) : C.infoOptionsNew(argv, 0);
    if (!opts) throw new Error(lastError(`${what} の引数が不正: ${args.join(' ')}`));
    try {
      const p = vector ? C.vectorInfo(ds, opts) : C.info(ds, opts);
      if (!p) throw new Error(lastError(`${what} に失敗した`));
      try {
        return M.UTF8ToString(p >>> 0);
      } finally {
        C.vsiFree(p);
      }
    } finally {
      if (vector) C.vectorInfoOptionsFree(opts);
      else C.infoOptionsFree(opts);
    }
  });
}

function runUtility(op, ds, dst, args) {
  const what = { vectorTranslate: 'ogr2ogr', warp: 'gdalwarp', translate: 'gdal_translate' }[op];
  return withArgv(args, (argv) => {
    C.errorReset();
    const newOpts = { vectorTranslate: C.vtOptionsNew, warp: C.warpOptionsNew, translate: C.trOptionsNew }[op];
    const freeOpts = { vectorTranslate: C.vtOptionsFree, warp: C.warpOptionsFree, translate: C.trOptionsFree }[op];
    const opts = newOpts(argv, 0);
    if (!opts) throw new Error(lastError(`${what} の引数が不正: ${args.join(' ')}`));
    const srcList = M._malloc(4) >>> 0;
    const usageError = M._malloc(4) >>> 0;
    M.HEAPU32[srcList >>> 2] = ds;
    M.HEAPU32[usageError >>> 2] = 0;
    try {
      C.errorReset();
      let out;
      if (op === 'translate') out = C.translate(dst, ds, opts, usageError);
      else if (op === 'warp') out = C.warp(dst, 0, 1, srcList, opts, usageError);
      else out = C.vectorTranslate(dst, 0, 1, srcList, opts, usageError);
      if (!out) {
        throw new Error(lastError(`${what} に失敗した`, M.HEAPU32[usageError >>> 2] !== 0));
      }
      // 書き出し先を閉じる（ここで書き切る。閉じる時の失敗も失敗として返す）
      C.errorReset();
      C.close(out);
      if (C.lastErrorType() >= CE_FAILURE) throw new Error(lastError(`${what} の書き出しを閉じるときに失敗した`));
    } finally {
      M._free(srcList);
      M._free(usageError);
      freeOpts(opts);
    }
    return null;
  });
}

/// GDALGetFileList。mount 先の接頭辞を外した名前で返す
function fileList(ds, prefix) {
  const list = C.fileList(ds) >>> 0;
  if (!list) return [];
  const out = [];
  try {
    for (let i = 0; ; i += 1) {
      const p = M.HEAPU32[(list >>> 2) + i];
      if (!p) break;
      const name = M.UTF8ToString(p);
      out.push(name.startsWith(prefix) ? name.substring(prefix.length) : name);
    }
  } finally {
    C.cslDestroy(list);
  }
  return out;
}

/// 文字列の配列を NULL 終端の char** にして [fn] に渡す
function withArgv(args, fn) {
  const ptrs = args.map((a) => {
    const len = M.lengthBytesUTF8(a) + 1;
    const p = M._malloc(len) >>> 0;
    M.stringToUTF8(a, p, len);
    return p;
  });
  const argv = M._malloc((ptrs.length + 1) * 4) >>> 0;
  ptrs.forEach((p, i) => { M.HEAPU32[(argv >>> 2) + i] = p; });
  M.HEAPU32[(argv >>> 2) + ptrs.length] = 0;
  try {
    return fn(argv);
  } finally {
    ptrs.forEach((p) => M._free(p));
    M._free(argv);
  }
}

/// gdal_ffi.dart の _error と同じ形（引数の誤りなら頭に付け、GDAL のメッセージが無ければ [fallback]）
function lastError(fallback, usage = false) {
  const msg = C.lastErrorMsg();
  return [usage ? '引数の誤り' : null, msg || fallback].filter((s) => s).join(': ');
}

/// [dir] の下のファイルを { rel, bytes } で集める（bytes の ArrayBuffer は transfer に積む）
function collect(dir, rel, transfer) {
  const out = [];
  for (const name of M.FS.readdir(dir)) {
    if (name === '.' || name === '..') continue;
    const path = `${dir}/${name}`;
    const relPath = rel ? `${rel}/${name}` : name;
    if (M.FS.isDir(M.FS.stat(path).mode)) {
      out.push(...collect(path, relPath, transfer));
    } else {
      const bytes = M.FS.readFile(path); // MEMFS の中身のコピー（新しい ArrayBuffer）
      transfer.push(bytes.buffer);
      out.push({ rel: relPath, bytes });
    }
  }
  return out;
}

function removeTree(dir) {
  for (const name of M.FS.readdir(dir)) {
    if (name === '.' || name === '..') continue;
    const path = `${dir}/${name}`;
    if (M.FS.isDir(M.FS.stat(path).mode)) removeTree(path);
    else M.FS.unlink(path);
  }
  M.FS.rmdir(dir);
}
