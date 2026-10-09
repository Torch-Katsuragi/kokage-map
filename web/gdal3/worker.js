// こかげマップ web 版の GDAL を動かす専用 worker（lib/core/gdal/gdal_web.dart から使う）。設計は docs/technical/gdal.md「web」
//
// gdal3.js（web/gdal3/<版>/、tool/web/fetch_gdal3.sh で置く）をこの worker の中で useWorker:false で起こし、
// GDAL のユーティリティ（gdal_utils.h）を引数の文字列のまま呼ぶ。Android の FFI 実装と同じ形にするため、
// gdal3.js の JS 関数（Gdal.ogr2ogr など）は使わず、同梱の emscripten Module から C API を cwrap して直接呼ぶ。
// gdal3.js 自身の worker 方式（initGdalJs({useWorker: true})）を使わない理由:
//   - 出力は /output/<名前>.<-f から決めた拡張子> に固定され、出力先の名前で形式を推定できない
//   - 出力を worker の MEMFS から消す口が無い（呼ぶたびにメモリが増え続ける）
//   - open が毎回 gdalinfo / ogrinfo を走らせる。1 回の操作が open → 実行 → close の 3 往復になり、
//     並んだ呼び出しどうしで入力の mount を外し合う
//
// 受け渡し:
//   入力: ファイル（File）の配列。WORKERFS で /input/j<n>/ に mount する（中身はコピーせず、読むときに File から切り出す）
//   出力: /output/j<n>/ に書かせ、中のファイルを全部 { rel, bytes } で返す（ArrayBuffer は transfer。コピーは 1 回）
//   ジョブごとに作って、終わったら消す
'use strict';

const GDAL_OF_RASTER = 0x02;
const GDAL_OF_VECTOR = 0x04;
const GDAL_OF_VERBOSE_ERROR = 0x40;
const CE_FAILURE = 3;

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
    const result = run(msg, transfer);
    self.postMessage({ id: msg.id, ok: true, result, log }, transfer);
  }).catch((e) => {
    // WebAssembly の RuntimeError（メモリ不足など）や abort の後は Module が壊れている。呼び手に作り直させる
    const fatal = !!broken || (e instanceof WebAssembly.RuntimeError);
    if (fatal && !broken) broken = String(e && e.message);
    self.postMessage({ id: msg.id, ok: false, fatal, error: String((e && e.message) || e), log });
  });
}

function init(base) {
  // gdal3.js は importScripts されると自分の onmessage を差し込むので、読んだ後に戻す
  importScripts(`${base}gdal3.js`);
  self.onmessage = onMessage;
  return self.initGdalJs({
    path: base,
    useWorker: false,
    logHandler: (text) => log.push(text),
    errorHandler: (text) => log.push(text),
  }).then((gdal) => {
    M = gdal.Module;
    const prevAbort = M.onAbort;
    M.onAbort = (what) => {
      broken = String(what);
      if (prevAbort) prevAbort(what);
    };
    const n = 'number';
    const s = 'string';
    C = {
      openEx: M.cwrap('GDALOpenEx', n, [s, n, n, n, n]),
      close: M.cwrap('GDALClose', null, [n]),
      errorReset: M.cwrap('CPLErrorReset', null, []),
      lastErrorMsg: M.cwrap('CPLGetLastErrorMsg', s, []),
      lastErrorType: M.cwrap('CPLGetLastErrorType', n, []),
      setConfig: M.cwrap('CPLSetThreadLocalConfigOption', null, [s, s]),
      infoOptionsNew: M.cwrap('GDALInfoOptionsNew', n, [n, n]),
      info: M.cwrap('GDALInfo', s, [n, n]),
      infoOptionsFree: M.cwrap('GDALInfoOptionsFree', null, [n]),
      vectorInfoOptionsNew: M.cwrap('GDALVectorInfoOptionsNew', n, [n, n]),
      vectorInfo: M.cwrap('GDALVectorInfo', s, [n, n]),
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
    };
  });
}

// =============================================
// ジョブ
// =============================================

function run(msg, transfer) {
  const job = `j${++seq}`;
  const inDir = `/input/${job}`;
  const outDir = `/output/${job}`;
  M.FS.mkdir(inDir);
  M.FS.mount(M.WORKERFS, { files: msg.files || [] }, inDir);
  const config = splitConfig(msg.args || []);
  for (const [k, v] of config.pairs) C.setConfig(k, v);
  try {
    switch (msg.op) {
      case 'rasterInfo':
        return withDataset(`${inDir}/${msg.main}`, GDAL_OF_RASTER, (ds) => runInfo(ds, config.args, false));
      case 'vectorInfo':
        return withDataset(`${inDir}/${msg.main}`, GDAL_OF_VECTOR, (ds) => runInfo(ds, config.args, true));
      case 'fileList':
        return withDataset(`${inDir}/${msg.main}`, 0, (ds) => fileList(ds, `${inDir}/`));
      case 'vectorTranslate':
      case 'warp':
      case 'translate':
        M.FS.mkdir(outDir);
        try {
          for (const f of msg.dstFiles || []) {
            M.FS.writeFile(`${outDir}/${f.name}`, new Uint8Array(new FileReaderSync().readAsArrayBuffer(f)));
          }
          const flags = msg.op === 'vectorTranslate' ? GDAL_OF_VECTOR : GDAL_OF_RASTER;
          withDataset(`${inDir}/${msg.main}`, flags, (ds) => runUtility(msg.op, ds, `${outDir}/${msg.dstName}`, config.args));
          return collect(outDir, '', transfer);
        } finally {
          removeTree(outDir);
        }
      default:
        throw new Error(`知らない操作: ${msg.op}`);
    }
  } finally {
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

function withDataset(path, flags, fn) {
  C.errorReset();
  const ds = C.openEx(path, flags | GDAL_OF_VERBOSE_ERROR, 0, 0, 0);
  if (!ds) throw new Error(lastError(`開けない: ${path}`));
  try {
    return fn(ds);
  } finally {
    C.close(ds);
  }
}

function runInfo(ds, args, vector) {
  return withArgv(['-json', ...args], (argv) => {
    C.errorReset();
    const opts = vector ? C.vectorInfoOptionsNew(argv, 0) : C.infoOptionsNew(argv, 0);
    if (!opts) throw new Error(lastError('引数が正しくない'));
    try {
      const json = vector ? C.vectorInfo(ds, opts) : C.info(ds, opts);
      if (json == null || C.lastErrorType() >= CE_FAILURE) throw new Error(lastError('情報を取れない'));
      return json;
    } finally {
      if (vector) C.vectorInfoOptionsFree(opts);
      else C.infoOptionsFree(opts);
    }
  });
}

function runUtility(op, ds, dst, args) {
  return withArgv(args, (argv) => {
    C.errorReset();
    const newOpts = { vectorTranslate: C.vtOptionsNew, warp: C.warpOptionsNew, translate: C.trOptionsNew }[op];
    const freeOpts = { vectorTranslate: C.vtOptionsFree, warp: C.warpOptionsFree, translate: C.trOptionsFree }[op];
    const opts = newOpts(argv, 0);
    if (!opts) throw new Error(lastError('引数が正しくない'));
    const srcList = M._malloc(4);
    const usageError = M._malloc(4);
    M.HEAP32[srcList >> 2] = ds;
    M.HEAP32[usageError >> 2] = 0;
    try {
      let out;
      if (op === 'translate') out = C.translate(dst, ds, opts, usageError);
      else if (op === 'warp') out = C.warp(dst, 0, 1, srcList, opts, usageError);
      else out = C.vectorTranslate(dst, 0, 1, srcList, opts, usageError);
      if (!out) {
        const usage = M.HEAP32[usageError >> 2] !== 0;
        throw new Error(lastError(usage ? '引数が正しくない' : '変換に失敗'));
      }
      C.close(out); // ここで書き切られる
      if (C.lastErrorType() >= CE_FAILURE) throw new Error(lastError('変換に失敗'));
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
  const list = C.fileList(ds);
  const out = [];
  if (!list) return out;
  for (let i = 0; ; i += 1) {
    const p = M.HEAP32[(list >> 2) + i];
    if (!p) break;
    const name = M.UTF8ToString(p);
    out.push(name.startsWith(prefix) ? name.substring(prefix.length) : name);
    M._free(p); // CSLDestroy と同じ（CPLMalloc は malloc）
  }
  M._free(list);
  return out;
}

function withArgv(args, fn) {
  const ptrs = args.map((a) => {
    const len = M.lengthBytesUTF8(a) + 1;
    const p = M._malloc(len);
    M.stringToUTF8(a, p, len);
    return p;
  });
  const argv = M._malloc((ptrs.length + 1) * 4);
  ptrs.forEach((p, i) => { M.HEAP32[(argv >> 2) + i] = p; });
  M.HEAP32[(argv >> 2) + ptrs.length] = 0;
  try {
    return fn(argv);
  } finally {
    ptrs.forEach((p) => M._free(p));
    M._free(argv);
  }
}

function lastError(fallback) {
  const msg = C.lastErrorMsg();
  const tail = log.length ? `\n${log.slice(-5).join('\n')}` : '';
  return `${msg || fallback}${tail}`;
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
