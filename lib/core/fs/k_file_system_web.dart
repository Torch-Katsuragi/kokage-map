// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
/// web の [KFileSystem] 実装（File System Access API）。
///
/// > [!IMPORTANT] パスは「仮想パス」
/// > ブラウザにファイルパスという概念は無い。あるのはユーザーが選んだフォルダの
/// > **ハンドル**だけ。既存の設計（`PathResolver` → `LayerTreeNode`）が全て
/// > パス文字列で組まれているので、ここで辻褄を合わせる:
/// >
/// > - ルートを `/<選んだフォルダ名>` という仮想パスとして登録する
/// > - 以降のパスはその接頭辞を剥がし、`/` で分割してハンドルを辿る
/// >
/// > つまりこのパスはOSのパスではなく**その都度決まる識別子**。
/// >
/// > ハンドル自体は IndexedDB に保存してある（[reopenLastDirectory]）。
/// > ただし再読み込み後に**そのまま使えるとは限らない**: ブラウザは
/// > 権限を切っていることがあり、`requestPermission()` はユーザー操作の中でしか
/// > 通らない。だから復元は「自動」ではなく**ボタンを押させる**形にしてある。
///
/// > [!WARNING] File System Access API は Chrome / Edge のみ
/// > Firefox / Safari には `showDirectoryPicker` が無い。
/// > [WebFileSystem.supportsDirectoryPicker] で判定し、非対応ブラウザには
/// > 「地図プレビューだけ」を出す。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:web/web.dart' as web;

import '../../utils/app_logger.dart';
import 'k_file_system.dart';

KFileSystem createKFileSystem() => WebFileSystem.instance;

/// `window.showDirectoryPicker()` — package:web には生えていないので自前で結ぶ
@JS('showDirectoryPicker')
external JSPromise<web.FileSystemDirectoryHandle> _showDirectoryPicker();

/// `values()` が返す非同期イテレータ（package:web 未定義）
extension type _AsyncIterator._(JSObject _) implements JSObject {
  external JSPromise<_IterResult> next();
}

extension type _IterResult._(JSObject _) implements JSObject {
  external bool get done;
  external JSAny? get value;
}

/// ハンドルの権限確認。package:web に生えていないので自前で結ぶ。
///
/// 戻り値は `'granted'` / `'denied'` / `'prompt'`。
extension type _PermissionHandle._(JSObject _) implements JSObject {
  external JSPromise<JSString> queryPermission(JSObject descriptor);
  external JSPromise<JSString> requestPermission(JSObject descriptor);
}

/// IndexedDB: ハンドルを1個だけ置いておく棚
const _dbName = 'k_rootmap_fs';
const _storeName = 'handles';
const _handleKey = 'projectRoot';

class WebFileSystem implements KFileSystem {
  WebFileSystem._();

  static final WebFileSystem instance = WebFileSystem._();

  /// 選択されたルート。未選択なら null
  web.FileSystemDirectoryHandle? _root;

  /// ルートの仮想パス（例: `/山林データ`）
  String? _rootPath;

  String? get rootPath => _rootPath;

  @override
  bool get hasRealPaths => false;

  /// このブラウザがフォルダ選択に対応しているか（Chrome / Edge のみ）
  static bool get supportsDirectoryPicker =>
      web.window.has('showDirectoryPicker');

  /// フォルダを選ばせ、仮想ルートパスを返す。キャンセル時は null
  Future<String?> pickDirectory() async {
    if (!supportsDirectoryPicker) return null;
    try {
      final handle = await _showDirectoryPicker().toDart;
      _adopt(handle);
      await _saveHandle(handle);
      return _rootPath;
    } catch (e) {
      // ユーザーがキャンセルすると AbortError が飛ぶ。異常ではない
      AppLogger.debug('[WebFileSystem] フォルダ選択を中止: $e');
      return null;
    }
  }

  void _adopt(web.FileSystemDirectoryHandle handle) {
    _root = handle;
    _rootPath = '/${handle.name}';
    AppLogger.debug('[WebFileSystem] ルートを選択: $_rootPath');
  }

  // =============================================
  // 前回のフォルダ（IndexedDB）
  // =============================================

  /// 前回開いたフォルダの名前。無ければ null。
  ///
  /// **権限は要求しない**（ボタンのラベルに出すためだけ）。
  Future<String?> lastDirectoryName() async {
    final handle = await _loadHandle();
    return handle?.name;
  }

  /// 前回のフォルダを開き直す。開けなければ null。
  ///
  /// > [!IMPORTANT] ユーザー操作の中から呼ぶこと
  /// > 権限が `prompt` に戻っていると `requestPermission()` が要る。
  /// > これはボタン押下などのユーザー操作起点でしか通らない
  /// > （起動直後に勝手に呼んでも `denied` が返るだけ）。
  Future<String?> reopenLastDirectory() async {
    final handle = await _loadHandle();
    if (handle == null) return null;

    final permission = handle as _PermissionHandle;
    final descriptor = {'mode': 'readwrite'}.jsify() as JSObject;
    try {
      var state = (await permission.queryPermission(descriptor).toDart).toDart;
      if (state != 'granted') {
        state = (await permission.requestPermission(descriptor).toDart).toDart;
      }
      if (state != 'granted') {
        AppLogger.debug('[WebFileSystem] 前回のフォルダへの権限が得られない: $state');
        return null;
      }
    } catch (e) {
      AppLogger.debug('[WebFileSystem] 権限確認に失敗: $e');
      return null;
    }

    _adopt(handle);
    return _rootPath;
  }

  /// 覚えているフォルダを忘れる
  Future<void> forgetLastDirectory() async {
    final db = await _openDb();
    if (db == null) return;
    try {
      final store = db
          .transaction(_storeName.toJS, 'readwrite')
          .objectStore(_storeName);
      await _await<JSAny?>(store.delete(_handleKey.toJS));
    } catch (e) {
      AppLogger.debug('[WebFileSystem] ハンドルの削除に失敗: $e');
    } finally {
      db.close();
    }
  }

  Future<void> _saveHandle(web.FileSystemDirectoryHandle handle) async {
    final db = await _openDb();
    if (db == null) return;
    try {
      final store = db
          .transaction(_storeName.toJS, 'readwrite')
          .objectStore(_storeName);
      await _await<JSAny?>(store.put(handle, _handleKey.toJS));
      AppLogger.debug('[WebFileSystem] ハンドルを保存: ${handle.name}');
    } catch (e) {
      // 保存に失敗しても選択そのものは成立しているので、握って続ける
      AppLogger.debug('[WebFileSystem] ハンドルの保存に失敗: $e');
    } finally {
      db.close();
    }
  }

  Future<web.FileSystemDirectoryHandle?> _loadHandle() async {
    final db = await _openDb();
    if (db == null) return null;
    try {
      final store = db
          .transaction(_storeName.toJS, 'readonly')
          .objectStore(_storeName);
      final value = await _await<JSAny?>(store.get(_handleKey.toJS));
      if (value == null) return null;
      return value as web.FileSystemDirectoryHandle;
    } catch (e) {
      AppLogger.debug('[WebFileSystem] ハンドルの読み出しに失敗: $e');
      return null;
    } finally {
      db.close();
    }
  }

  Future<web.IDBDatabase?> _openDb() async {
    try {
      final request = web.window.indexedDB.open(_dbName, 1);
      request.onupgradeneeded = (web.Event _) {
        final db = request.result as web.IDBDatabase;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName);
        }
      }.toJS;
      return await _await<web.IDBDatabase>(request);
    } catch (e) {
      // プライベートウィンドウなどで IndexedDB が使えないことがある
      AppLogger.debug('[WebFileSystem] IndexedDB を開けない: $e');
      return null;
    }
  }

  /// `IDBRequest` を Future にする
  Future<T> _await<T extends JSAny?>(web.IDBRequest request) {
    final completer = Completer<T>();
    request.onsuccess = (web.Event _) {
      if (!completer.isCompleted) completer.complete(request.result as T);
    }.toJS;
    request.onerror = (web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          KFileSystemException('IndexedDB: ${request.error?.message}'),
        );
      }
    }.toJS;
    return completer.future;
  }

  // =============================================
  // パス → ハンドル解決
  // =============================================

  /// 仮想パスをルートからの相対セグメントに分解する。
  /// ルート外を指していたら null
  List<String>? _segments(String path) {
    final root = _rootPath;
    if (root == null) return null;
    if (path == root) return const [];
    if (!path.startsWith('$root/')) return null;
    return path
        .substring(root.length + 1)
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<web.FileSystemDirectoryHandle?> _dirHandle(
    String path, {
    bool create = false,
  }) async {
    final segments = _segments(path);
    if (segments == null) return null;
    var handle = _root;
    if (handle == null) return null;
    for (final name in segments) {
      try {
        handle = await handle!
            .getDirectoryHandle(
              name,
              web.FileSystemGetDirectoryOptions(create: create),
            )
            .toDart;
      } catch (_) {
        return null;
      }
    }
    return handle;
  }

  Future<web.FileSystemFileHandle?> _fileHandle(
    String path, {
    bool create = false,
  }) async {
    final segments = _segments(path);
    if (segments == null || segments.isEmpty) return null;
    final parent = await _dirHandle(p.dirname(path), create: create);
    if (parent == null) return null;
    try {
      return await parent
          .getFileHandle(
            segments.last,
            web.FileSystemGetFileOptions(create: create),
          )
          .toDart;
    } catch (_) {
      return null;
    }
  }

  // =============================================
  // KFileSystem
  // =============================================

  @override
  Future<bool> exists(String path) async =>
      await _fileHandle(path) != null || await _dirHandle(path) != null;

  @override
  Future<bool> isDirectory(String path) async => await _dirHandle(path) != null;

  @override
  Future<List<KFileEntry>> list(String path) async {
    final dir = await _dirHandle(path);
    if (dir == null) return const [];

    final entries = <KFileEntry>[];
    // values() は非同期イテレータ。Dart の await for には乗らないので手で回す
    final iterator = dir.callMethod<_AsyncIterator>('values'.toJS);
    while (true) {
      final result = await iterator.next().toDart;
      if (result.done) break;
      final handle = result.value as web.FileSystemHandle?;
      if (handle == null) continue;
      entries.add(
        KFileEntry(
          path: p.join(path, handle.name),
          isDirectory: handle.kind == 'directory',
        ),
      );
    }
    return entries;
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    final handle = await _fileHandle(path);
    if (handle == null) throw _notFound(path);
    final file = await handle.getFile().toDart;
    final buffer = await file.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  @override
  Future<String> readAsString(String path) async {
    final handle = await _fileHandle(path);
    if (handle == null) throw _notFound(path);
    final file = await handle.getFile().toDart;
    return (await file.text().toDart).toDart;
  }

  @override
  Future<void> writeAsBytes(String path, Uint8List bytes) =>
      _write(path, bytes.toJS);

  @override
  Future<void> writeAsString(String path, String contents) =>
      _write(path, contents.toJS);

  Future<void> _write(String path, JSAny data) async {
    final handle = await _fileHandle(path, create: true);
    if (handle == null) throw _notFound(path);
    final writable = await handle.createWritable().toDart;
    await writable.write(data).toDart;
    await writable.close().toDart;
  }

  @override
  Future<void> createDirectory(String path) async {
    if (await _dirHandle(path, create: true) == null) throw _notFound(path);
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    final parent = await _dirHandle(p.dirname(path));
    if (parent == null) return;
    await parent
        .removeEntry(
          p.basename(path),
          web.FileSystemRemoveOptions(recursive: recursive),
        )
        .toDart;
  }

  @override
  Future<void> rename(String from, String to) async {
    // ⚠ File System Access API に rename は無い。
    // ファイルは「読んで書いて消す」で代用できるが、ディレクトリは中身を
    // 丸ごと作り直す話になるので、ここでは対応しない。
    if (await _dirHandle(from) != null) {
      throw UnsupportedError('web ではフォルダ名の変更に未対応です');
    }
    final bytes = await readAsBytes(from);
    await writeAsBytes(to, bytes);
    await delete(from);
  }

  @override
  Future<String> canonicalPath(String path) async => path;

  @override
  Future<DateTime?> lastModified(String path) async {
    final handle = await _fileHandle(path);
    if (handle == null) return null;
    final file = await handle.getFile().toDart;
    // JS の lastModified はエポックミリ秒
    return DateTime.fromMillisecondsSinceEpoch(file.lastModified);
  }

  @override
  Future<int?> length(String path) async {
    final handle = await _fileHandle(path);
    if (handle == null) return null;
    final file = await handle.getFile().toDart;
    return file.size;
  }

  Exception _notFound(String path) =>
      KFileSystemException('パスを解決できません（ルート未選択か範囲外）: $path');
}

/// `dart:io` の `FileSystemException` に相当する軽い代用
class KFileSystemException implements Exception {
  const KFileSystemException(this.message);

  final String message;

  @override
  String toString() => 'KFileSystemException: $message';
}
