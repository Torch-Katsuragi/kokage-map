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
// こかげマップ: フォルダ設定（KMeta）を `<dir名>.qgs` に読み書きする
//
// 設計は [[docs/technical/project-format-design#正典を `.qgs` に移す（2026-09-06 決定・設計）]]。
// 2026-09-29 に `.kmeta.json` をやめ、`.qgs` の `<properties><kokage><meta>` に一本化した。
//
// - QGIS が表現できる部分（可視性・フィルタ・単一シンボル・並び）は [QgsProjectBuilder] が
//   QGIS の形で書く。こちらはアプリのモデルそのもの（写真の可視性・オーバーレイの変換・
//   View の定義・リンク情報）を丸ごと持つ。QGIS 側で保存されたら読み戻しがモデルを直す
// - 旧 `.kmeta.json` は読んだ時点で `.qgs` に移し、`.kmeta.json.migrated` に改名する
// - 同じ `.qgs` をここと [QgsProjectBuilder] の両方が書くので、[QgsFileLock] で順番に書く

import 'dart:async';
import 'dart:convert';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/kmeta.dart';
import '../../utils/app_logger.dart';
import 'qgs_document.dart';
import 'qgs_writer.dart';

/// アプリ側の `.qgs` の読み方の版。印（`kokage/schemaVersion`）に書く。
///
/// 2 から `kokage/meta`（アプリのフォルダ設定）を持つ。
const int kQgsSchemaVersion = 2;

/// 移し終えた旧 `.kmeta.json` の改名先
const String kMigratedMetaFileName = '$kMetaFileName.migrated';

/// 同じ `.qgs` への書き込みを 1 本ずつにする（読んで直して書く途中で他が書くと片方が消える）
abstract final class QgsFileLock {
  static final Map<String, Future<void>> _tails = {};

  static Future<T> run<T>(String path, Future<T> Function() body) async {
    final key = p.normalize(path).replaceAll('\\', '/');
    final previous = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    final tail = done.future;
    _tails[key] = tail;
    try {
      await previous;
    } on Object {
      // 前の書き込みの失敗はこちらに持ち込まない
    }
    try {
      return await body();
    } finally {
      done.complete();
      if (identical(_tails[key], tail)) unawaited(_tails.remove(key));
    }
  }
}

/// dir の `.qgs` を探す・名前を決める
///
/// > [!IMPORTANT] Drive 連携している dir は `<Drive のフォルダ名>.qgs`（2026-09-29）
/// > `.qgs` は Drive で共有される。`<dir名>.qgs` のままだと、端末ごとにローカルの dir 名が
/// > 違うとき（A 端末は「北山」、B 端末は「北山 (1)」…）互いに自分の名前へ改名し合い、
/// > 同期のたびに消して上げ直す。連携していれば全端末で同じ Drive のフォルダ名を使う。
/// > プロジェクト名と印の `dirName` も同じ理由でこの名前にする。
abstract final class QgsProjectFile {
  /// [dirPath] の `.qgs` のパス。無ければ null。
  ///
  /// `<dir名>.qgs` → 旧名 `project.qgs`（`<dir名>.qgs` に改名する）→ 自分の印と設定を持つ
  /// 別名の `.qgs`（Drive のフォルダ名で書いたもの・dir を改名する前の名前のもの）の順に探す。
  /// 印の無い別名の `.qgs` は他人のファイルなので採らない。名前の付け替えは書くとき
  /// （[QgsMetaStore]）にやる。
  static Future<String?> find(String dirPath) async {
    final path = p.join(dirPath, qgsFileNameFor(dirNameOf(dirPath)));
    if (await fs.exists(path)) return path;
    if (!await fs.isDirectory(dirPath)) return null;

    final legacy = p.join(dirPath, kLegacyQgsFileName);
    if (await fs.exists(legacy)) {
      await fs.rename(legacy, path);
      AppLogger.debug('[QgsProjectFile] $kLegacyQgsFileName を ${p.basename(path)} に改名');
      return path;
    }

    for (final entry in await fs.list(dirPath)) {
      if (entry.isDirectory || !entry.path.toLowerCase().endsWith('.qgs')) continue;
      try {
        final doc = QgsDocument.parse(await fs.readAsString(entry.path));
        if (doc.stamp == null || doc.kokageMeta == null) continue;
        return entry.path;
      } on Object {
        continue;
      }
    }
    return null;
  }

  /// プロジェクト名。Drive 連携していれば Drive のフォルダ名、していなければ dir 名
  static String projectNameFor(String dirPath, KMeta? meta) {
    final sync = meta?.sync;
    final drive = sync != null && sync.isLinked ? sync.driveFolderName?.trim() : null;
    if (drive == null || drive.isEmpty) return dirNameOf(dirPath);
    return drive.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  /// [dirPath] の `.qgs` があるべきパス（設定 [meta] で名前が決まる）
  static String pathFor(String dirPath, [KMeta? meta]) =>
      p.join(dirPath, qgsFileNameFor(projectNameFor(dirPath, meta)));

  static String dirNameOf(String dirPath) => p.basename(p.normalize(dirPath));
}

/// フォルダ設定の読み書き
abstract final class QgsMetaStore {
  /// [dirPath] が自分の設定を持つか（`.qgs` か、まだ移していない `.kmeta.json` がある）
  static Future<bool> exists(String dirPath) async =>
      await fs.exists(p.join(dirPath, kMetaFileName)) || await QgsProjectFile.find(dirPath) != null;

  /// [dirPath] の設定を読む。`.qgs` も `.kmeta.json` も無ければ null。
  ///
  /// `.qgs` はあるが `kokage/meta` が無い（QGIS で作ったもの）ときは空の設定を返す。
  /// 中身は開いたときの読み戻しが QGIS の形から取り込む。
  ///
  /// 旧 `.kmeta.json` を移したら [onMigrated] を呼ぶ（QGIS が読む部分も書き直させる）。
  static Future<KMeta?> read(String dirPath, {void Function()? onMigrated}) async {
    final legacyPath = p.join(dirPath, kMetaFileName);
    final hasLegacy = await fs.exists(legacyPath);
    var qgsPath = await QgsProjectFile.find(dirPath);

    KMeta? fromQgs;
    var qgsReadable = false;
    if (qgsPath != null) {
      try {
        final doc = QgsDocument.parse(await fs.readAsString(qgsPath));
        qgsReadable = true;
        final json = doc.kokageMeta;
        if (json != null) fromQgs = KMeta.fromJson(jsonDecode(json) as Map<String, dynamic>);
      } on Object catch (e) {
        AppLogger.debug('[QgsMetaStore] ${p.basename(qgsPath)} を読めない: $e');
      }
    }
    // 名前が設定と合っていなければ付け替える（dir を改名した・連携を始めた／やめた）
    if (qgsPath != null && fromQgs != null) qgsPath = await _renameToTarget(qgsPath, dirPath, fromQgs);

    if (!hasLegacy) {
      if (fromQgs != null) return fromQgs;
      return qgsReadable ? KMeta.empty : null;
    }

    // 旧 `.kmeta.json` が残っている
    if (fromQgs != null) {
      // 両方あれば `.qgs` が勝つ（旧版アプリが別の端末で書いたものは読まない）
      AppLogger.debug('[QgsMetaStore] $dirPath: .qgs に設定があるので $kMetaFileName は使わず退避する');
      await _retireLegacy(legacyPath);
      return fromQgs;
    }
    final legacy = await KMeta.loadFromFile(dirPath);
    if (legacy == null) return qgsReadable ? KMeta.empty : null;
    if (await write(dirPath, legacy)) {
      AppLogger.debug('[QgsMetaStore] $dirPath: $kMetaFileName を ${p.basename(QgsProjectFile.pathFor(dirPath, legacy))} に移した');
      await _retireLegacy(legacyPath);
      onMigrated?.call();
    }
    return legacy;
  }

  /// [meta] を [dirPath] の `.qgs` に書く。無ければ作る。中身が同じなら書かない。
  static Future<bool> write(String dirPath, KMeta meta) async {
    final found = await QgsProjectFile.find(dirPath);
    final path = found == null
        ? QgsProjectFile.pathFor(dirPath, meta)
        : await _renameToTarget(found, dirPath, meta);
    final name = QgsProjectFile.projectNameFor(dirPath, meta);
    return QgsFileLock.run(path, () async {
      try {
        String? existing;
        QgsDocument doc;
        if (await fs.exists(path)) {
          existing = await fs.readAsString(path);
          try {
            doc = QgsDocument.parse(existing);
          } on Object catch (e) {
            // 壊れていたら退避して作り直す（黙って上書きしない）
            AppLogger.debug('[QgsMetaStore] 既存の .qgs を読めないので退避: $e');
            await fs.rename(path, '$path.bak');
            existing = null;
            doc = QgsDocument.create(projectName: name);
          }
        } else {
          await fs.createDirectory(dirPath);
          doc = QgsDocument.create(projectName: name);
        }

        final json = jsonEncode(meta.toJson());
        if (existing != null && doc.kokageMeta == json && doc.lastWrittenByKokage && doc.stamp?.dirName == name) {
          return true;
        }
        doc.kokageMeta = json;
        doc.setStamp(
          KokageStamp(
            schemaVersion: kQgsSchemaVersion,
            app: await appLabel(),
            savedAt: DateTime.now(),
            dirName: name,
          ),
        );
        await fs.writeAsString(path, doc.toXmlString());
        return true;
      } on Object catch (e) {
        AppLogger.debug('[QgsMetaStore] $path に書けない: $e');
        return false;
      }
    });
  }

  /// [path] を設定 [meta] で決まる名前に付け替える。付け替え先が既にあれば付け替えずにそちらを返す
  static Future<String> _renameToTarget(String path, String dirPath, KMeta meta) async {
    final target = QgsProjectFile.pathFor(dirPath, meta);
    if (p.equals(path, target)) return path;
    if (await fs.exists(target)) return target;
    return QgsFileLock.run(path, () async {
      if (!await fs.exists(path)) return target;
      await fs.rename(path, target);
      AppLogger.debug('[QgsMetaStore] ${p.basename(path)} を ${p.basename(target)} に改名');
      return target;
    });
  }

  static Future<void> _retireLegacy(String legacyPath) async {
    try {
      final target = p.join(p.dirname(legacyPath), kMigratedMetaFileName);
      if (await fs.exists(target)) await fs.delete(target);
      await fs.rename(legacyPath, target);
    } on Object catch (e) {
      AppLogger.debug('[QgsMetaStore] $kMetaFileName を退避できない: $e');
    }
  }

  static String? _appLabelCache;

  /// 印に書くアプリ名。`kokage-map <version>+<build>`
  static Future<String> appLabel() async {
    if (_appLabelCache != null) return _appLabelCache!;
    try {
      final info = await PackageInfo.fromPlatform();
      return _appLabelCache = 'kokage-map ${info.version}+${info.buildNumber}';
    } on Object {
      return 'kokage-map';
    }
  }
}
