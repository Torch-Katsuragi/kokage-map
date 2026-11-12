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
// こかげマップ: QGIS 側で編集された `.qgs` / `.qgz`（および GeoPackage 内埋め込みスタイル）を読み戻す
//
// 印（`kokage/savedAt`）と root の `saveDateTime` が食い違っていれば、
// 最後に書いたのはこかげマップではない＝QGIS（か人）が保存した。そのときだけ
// 寛容インポータで View・スタイル・可視性を取り込み、続く自動更新で
// 正規化＋印つきの `.qgs` に書き戻す。
//
// `<dir名>.qgz`（QGIS の既定保存形式）があれば XML を `<dir名>.qgs` に展開して `.qgz.bak` に退避する。
// また初回オープン時にまだ `<dir名>.qgs` が無いルートフォルダでは、単一の `.qgz` / 別名 `.qgs` や
// GeoPackage 内 `qgis_projects` / `layer_styles` / 横置き `.qml` からも初期設定を救済する。

import 'dart:async';

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/nodes/folder_node.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'qgs_auto_refresh.dart';
import 'qgs_base_map_import.dart';
import 'qgs_document.dart';
import 'qgs_embedded_style_loader.dart';
import 'qgs_importer.dart';
import 'qgs_meta_store.dart';
import 'qgs_raster_source.dart';

/// 読み戻した結果。何もしなかったときは [QgsReadBack.run] が null を返す
class QgsReadBackResult {
  const QgsReadBackResult({
    required this.fileName,
    required this.importedViewCount,
    required this.discarded,
    this.overlayCount = 0,
    this.baseMapsAdded = const [],
  });

  final String fileName;
  final int importedViewCount;
  final List<String> discarded;

  /// 可視性を読み戻したオーバーレイ画像（GeoTIFF）の数
  final int overlayCount;

  /// `.qgs` の XYZ タイルから背景地図に足したプロバイダの名前
  final List<String> baseMapsAdded;
}

class QgsReadBack {
  const QgsReadBack();

  static final _hasQgisRenderer = RegExp(
    'type="(categorizedSymbol|graduatedSymbol|RuleRenderer|invertedPolygonRenderer|mergedFeatureRenderer|pointCluster|pointDisplacement|nullSymbol)"',
  );

  /// QGIS で属性フォームを設定した跡（編集ウィジェット・別名・既定値・制約の式・読み取り専用・配置）
  static final _hasQgisForm = RegExp(
    '<editWidget type="[A-Za-z]|<alias [^>]*name="[^"]|<default [^>]*expression="[^"]|'
    '<constraint [^>]*exp="[^"]|<field editable="0"|<editorlayout>tablayout',
  );

  /// 走っている読み戻し（終わるまで次を待たせる）
  static Future<void> _last = Future.value();

  /// [root] の `<dir名>.qgs` / `<dir名>.qgz` を見て、QGIS 側で保存されていれば取り込む。
  ///
  /// ツリーの子（gpkg とレイヤ）が読み込まれてから呼ぶこと。
  Future<QgsReadBackResult?> run(FolderNode root) {
    final done = Completer<void>();
    final previous = _last;
    _last = done.future;
    return previous.then((_) => _run(root)).whenComplete(done.complete);
  }

  Future<QgsReadBackResult?> _run(FolderNode root) async {
    final rootPath = root.getAbsoluteFilePath();

    // どの `.qgs` にも子孫の写しが入るので、同じ設定が複数のファイルで QGIS に直されうる。
    // 古い保存から順に取り込み、後のものが勝つようにする
    final saved = <_QgisSaved>[];
    await _collect(root, saved, isRoot: true);
    saved.sort((a, b) => a.savedAt.compareTo(b.savedAt));
    final ownerWrittenAt = <String, DateTime?>{};
    final results = <QgsReadBackResult>[];
    final baseMaps = <QgsBaseMap>[];
    for (final s in saved) {
      final one = await _import(s, ownerWrittenAt, baseMaps);
      if (one != null) results.add(one);
    }

    // プロジェクト側でスタイルが未設定のレイヤについて、GeoPackage 内 `layer_styles` や `.qml` から救済
    final embeddedApplied = await QgsEmbeddedStyleLoader.applyFallbackLayerStyles(root);

    // 開いたら一度は書き直す（中身が同じなら書かない）。まだ `.qgs` が無ければ最初の1本になり、
    // 旧 `.kmeta.json` や埋め込みスタイルから移したばかりなら QGIS が読む部分もそろう
    if (rootPath != null) QgsAutoRefresh.instance.schedule(rootPath);

    if (results.isEmpty) {
      if (embeddedApplied > 0 && rootPath != null) {
        return QgsReadBackResult(
          fileName: p.basename(QgsProjectFile.pathFor(rootPath)),
          importedViewCount: embeddedApplied,
          discarded: const [],
        );
      }
      return null;
    }

    // XYZ タイルは端末の背景地図へ（一度足したものは二度と足さない。[QgsBaseMapImport]）
    var baseMapsAdded = const <String>[];
    try {
      baseMapsAdded = await QgsBaseMapImport.apply(baseMaps);
    } on Object catch (e) {
      AppLogger.debug('[QgsReadBack] 背景地図に足せない: $e');
    }
    return QgsReadBackResult(
      fileName: results.map((r) => r.fileName).join(', '),
      importedViewCount: results.fold(0, (s, r) => s + r.importedViewCount),
      discarded: [for (final r in results) ...r.discarded],
      overlayCount: results.fold(0, (s, r) => s + r.overlayCount),
      baseMapsAdded: baseMapsAdded,
    );
  }

  /// root と、独立した `.qgs` を持つ子 dir から、QGIS 側で保存されたものを集める
  Future<void> _collect(FolderNode folder, List<_QgisSaved> out, {bool isRoot = false}) async {
    final one = await _qgisSaved(folder, isRoot: isRoot);
    if (one != null) out.add(one);
    for (final child in folder.children.whereType<FolderNode>()) {
      await _collect(child, out);
    }
  }

  /// `<dir名>.qgz` があれば展開して `<dir名>.qgs` に書き出し、`.qgz.bak` へ退避する。
  /// さらにルートフォルダ初回オープン時（まだ `<dir名>.qgs` が無い）は、単一の `.qgz`・単一の別名 `.qgs`・
  /// または GeoPackage 内 `qgis_projects` から `<dir名>.qgs` へ展開する。
  Future<String?> _findOrMaterializeProjectFile(FolderNode folder, String dirPath, {required bool isRoot}) async {
    final names = await QgsProjectFile.fileNames(dirPath);
    if (names == null) return null;

    final dirName = QgsProjectFile.dirNameOf(dirPath);
    final ownQgs = '$dirName.qgs';
    final ownQgz = '$dirName.qgz';

    // 1. 同名の `<dir名>.qgz` が置かれていれば（QGIS の既定保存形式）、常に展開して `.qgz.bak` に退避する
    final lowerToActual = {for (final n in names) n.toLowerCase(): n};
    final matchedOwnQgz = lowerToActual[ownQgz.toLowerCase()];
    if (matchedOwnQgz != null) {
      final qgzPath = p.join(dirPath, matchedOwnQgz);
      final targetQgsPath = p.join(dirPath, ownQgs);
      if (await _unpackQgzToQgs(qgzPath, targetQgsPath)) {
        return targetQgsPath;
      }
    }

    if (!isRoot && !await KMetaService.instance.hasMetaFile(dirPath)) {
      return null;
    }

    final existing = await QgsProjectFile.find(dirPath, names: names);
    if (existing != null) return existing;

    if (!isRoot) return null;

    // 2. ルートフォルダに `<dir名>.qgs` がまだ無い場合: 単一の `.qgz` があれば展開して退避
    final qgzFiles = [for (final n in names) if (n.toLowerCase().endsWith('.qgz')) n];
    if (qgzFiles.length == 1) {
      final qgzPath = p.join(dirPath, qgzFiles.single);
      final targetQgsPath = p.join(dirPath, ownQgs);
      if (await _unpackQgzToQgs(qgzPath, targetQgsPath)) {
        return targetQgsPath;
      }
    }

    // 3. ルートフォルダに `<dir名>.qgs` がまだ無く、別名の `.qgs` が 1 つだけある場合:
    //    元の別名 `.qgs` は変更せず、内容を `<dir名>.qgs` に写して初期取り込みする
    final qgsFiles = [for (final n in names) if (n.toLowerCase().endsWith('.qgs')) n];
    if (qgsFiles.length == 1) {
      final foreignPath = p.join(dirPath, qgsFiles.single);
      final targetQgsPath = p.join(dirPath, ownQgs);
      try {
        final xml = await fs.readAsString(foreignPath);
        if (xml.contains('<qgis')) {
          await QgsFileWriter.write(targetQgsPath, xml);
          AppLogger.debug('[QgsReadBack] 別名プロジェクト ${qgsFiles.single} を $ownQgs に初期複写して取り込み');
          return targetQgsPath;
        }
      } on Object catch (e) {
        AppLogger.debug('[QgsReadBack] 別名 .qgs の初期複写に失敗: $e');
      }
    }

    // 4. ファイルとしての `.qgs` / `.qgz` が一切無く、GeoPackage 内 `qgis_projects` テーブルがある場合
    if (qgsFiles.isEmpty && qgzFiles.isEmpty) {
      final embeddedXml = await QgsEmbeddedStyleLoader.readEmbeddedProjectXml(folder);
      if (embeddedXml != null) {
        final targetQgsPath = p.join(dirPath, ownQgs);
        try {
          await QgsFileWriter.write(targetQgsPath, embeddedXml);
          AppLogger.debug('[QgsReadBack] GeoPackage 内 qgis_projects を $ownQgs に展開して取り込み');
          return targetQgsPath;
        } on Object catch (e) {
          AppLogger.debug('[QgsReadBack] qgis_projects の書き出しに失敗: $e');
        }
      }
    }

    return null;
  }

  Future<bool> _unpackQgzToQgs(String qgzPath, String targetQgsPath) async {
    try {
      final xml = await QgsImporter.readQgsText(qgzPath);
      await QgsFileWriter.write(targetQgsPath, xml);
      final bakPath = '$qgzPath.bak';
      if (await fs.exists(bakPath)) await fs.delete(bakPath);
      await fs.rename(qgzPath, bakPath);
      AppLogger.debug('[QgsReadBack] ${p.basename(qgzPath)} を ${p.basename(targetQgsPath)} に展開し .bak へ退避');
      return true;
    } on Object catch (e) {
      AppLogger.debug('[QgsReadBack] .qgz の展開に失敗 ($qgzPath): $e');
      return false;
    }
  }

  Future<_QgisSaved?> _qgisSaved(FolderNode root, {required bool isRoot}) async {
    final rootPath = root.getAbsoluteFilePath();
    if (rootPath == null) return null;

    final path = await _findOrMaterializeProjectFile(root, rootPath, isRoot: isRoot);
    if (path == null) return null;

    final String xml;
    try {
      xml = await fs.readAsString(path);
    } on Object catch (e) {
      AppLogger.debug('[QgsReadBack] 読めない: $e');
      return null;
    }

    QgsDocument doc;
    try {
      doc = QgsDocument.parse(xml);
    } on Object catch (e) {
      AppLogger.debug('[QgsReadBack] XML として読めない（自動更新で退避される）: $e');
      return null;
    }

    if (doc.lastWrittenByKokage) {
      AppLogger.debug('[QgsReadBack] ${p.basename(path)} は自分が書いたもの。読み戻し不要');
      // 描き分けの中身を持たない古い取り込みだけ補う（[QgsImporter.backfillRendererDefs]）
      if (_hasQgisRenderer.hasMatch(xml)) {
        try {
          await const QgsImporter().backfillRendererDefs(path, root);
        } on Object catch (e) {
          AppLogger.debug('[QgsReadBack] 描き分けの補完に失敗: $e');
        }
      }
      // 属性フォームの設定を持たないレイヤだけ補う（[QgsImporter.backfillForms]）
      if (_hasQgisForm.hasMatch(xml)) {
        try {
          await const QgsImporter().backfillForms(path, root);
        } on Object catch (e) {
          AppLogger.debug('[QgsReadBack] 属性フォームの補完に失敗: $e');
        }
      }
      return null;
    }

    AppLogger.debug(
      '[QgsReadBack] ${p.basename(path)} は QGIS 側で保存されている'
      '（saveDateTime=${doc.root.getAttribute('saveDateTime')} '
      'savedAt=${doc.stamp?.savedAtText}）',
    );
    // 保存時刻が読めなければ最古扱い（他の保存に負ける）
    final savedAt = DateTime.tryParse(doc.root.getAttribute('saveDateTime') ?? '') ?? DateTime(0);
    return _QgisSaved(folder: root, folderPath: rootPath, path: path, savedAt: savedAt);
  }

  Future<QgsReadBackResult?> _import(
    _QgisSaved s,
    Map<String, DateTime?> ownerWrittenAt,
    List<QgsBaseMap> baseMaps,
  ) async {
    final owners = <FolderNode, DateTime?>{};
    for (final f in _foldersOf(s.folder)) {
      final fp = f.getAbsoluteFilePath();
      if (fp == null) continue;
      owners[f] = ownerWrittenAt.containsKey(fp) ? ownerWrittenAt[fp] : (ownerWrittenAt[fp] = await _writtenAt(fp));
    }
    final result = await const QgsImporter().import(
      s.path,
      s.folder,
      acceptOwner: (owner) {
        final written = owners[owner];
        return written == null || s.savedAt.isAfter(written);
      },
    );

    baseMaps.addAll(result.baseMaps);

    // 取り込んだので印を付け直し（自動更新が書けるようになる）、取り込んだ結果（と正規化）を書き戻す
    await QgsMetaStore.claim(s.path);
    QgsAutoRefresh.instance.schedule(s.folderPath);

    return QgsReadBackResult(
      fileName: p.basename(s.path),
      importedViewCount: result.importedViewCount,
      discarded: result.discarded,
      overlayCount: result.overlayCount,
    );
  }

  /// [folder] 自身と子孫の dir
  static Iterable<FolderNode> _foldersOf(FolderNode folder) sync* {
    yield folder;
    for (final child in folder.children.whereType<FolderNode>()) {
      yield* _foldersOf(child);
    }
  }

  /// [dirPath] の `.qgs` にこかげマップが最後に書いた時刻。`.qgs` や印が無ければ null
  static Future<DateTime?> _writtenAt(String dirPath) async {
    if (!await KMetaService.instance.hasMetaFile(dirPath)) return null;
    final path = await QgsProjectFile.find(dirPath);
    if (path == null) return null;
    try {
      return QgsDocument.parse(await fs.readAsString(path)).stamp?.savedAt;
    } on Object {
      return null;
    }
  }
}

/// QGIS 側で保存された（まだ読み戻していない）`.qgs`
class _QgisSaved {
  const _QgisSaved({required this.folder, required this.folderPath, required this.path, required this.savedAt});

  final FolderNode folder;
  final String folderPath;
  final String path;

  /// QGIS が保存した時刻（root の `saveDateTime`）
  final DateTime savedAt;
}
