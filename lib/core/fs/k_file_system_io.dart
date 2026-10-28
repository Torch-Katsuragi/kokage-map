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
/// `dart:io` を使う [KFileSystem] 実装（Android / iOS / Windows / macOS / Linux）。
///
/// 同期APIを持つプラットフォームだが、抽象側が非同期しか持たないので
/// ここでも非同期に揃える（`existsSync()` を使えば速いが、web と挙動を
/// 分岐させないことを優先する）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'k_file_system.dart';

KFileSystem createKFileSystem() => const IoFileSystem();

class IoFileSystem implements KFileSystem {
  const IoFileSystem();

  @override
  bool get hasRealPaths => true;

  @override
  Future<bool> exists(String path) async =>
      await File(path).exists() || await Directory(path).exists();

  @override
  Future<bool> isDirectory(String path) => Directory(path).exists();

  @override
  Future<List<KFileEntry>> list(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return const [];

    // Windows でのUI停止を避けるため同期走査（listSync）は使わない
    final entries = <KFileEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      entries.add(
        KFileEntry(
          path: entity.path,
          isDirectory: entity is Directory,
        ),
      );
    }
    return entries;
  }

  @override
  Future<Uint8List> readAsBytes(String path) => File(path).readAsBytes();

  @override
  Future<String> readAsString(String path) => File(path).readAsString();

  @override
  Future<void> writeAsBytes(String path, Uint8List bytes) async {
    await File(path).writeAsBytes(bytes);
  }

  @override
  Future<void> writeStream(
    String path,
    Stream<List<int>> stream, {
    void Function(int chunkBytes)? onChunk,
  }) async {
    final parent = Directory(p.dirname(path));
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    // 同一ディレクトリ内の隠し一時ファイル（.sync や LayerDrawer の列挙から除外される）に書き、
    // 完走後に rename でアトミックに置換する
    final partPath = p.join(
      p.dirname(path),
      '.${p.basename(path)}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    final partFile = File(partPath);
    final sink = partFile.openWrite();
    var completed = false;
    try {
      await for (final chunk in stream) {
        sink.add(chunk);
        onChunk?.call(chunk.length);
      }
      await sink.flush();
      await sink.close();
      completed = true;
      await partFile.rename(path);
    } finally {
      if (!completed) {
        try {
          await sink.close();
        } catch (_) {}
      }
      try {
        if (await partFile.exists()) {
          await partFile.delete();
        }
      } catch (_) {}
    }
  }

  @override
  Future<void> writeAsString(String path, String contents) async {
    await File(path).writeAsString(contents);
  }

  @override
  Future<void> createDirectory(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: recursive);
      return;
    }
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> rename(String from, String to) async {
    final dir = Directory(from);
    if (await dir.exists()) {
      await dir.rename(to);
      return;
    }
    await File(from).rename(to);
  }

  @override
  Future<String> canonicalPath(String path) async {
    try {
      return await Directory(path).resolveSymbolicLinks();
    } on FileSystemException {
      return path;
    }
  }

  @override
  Future<DateTime?> lastModified(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return (await file.stat()).modified;
  }

  @override
  Future<int?> length(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.length();
  }
}
