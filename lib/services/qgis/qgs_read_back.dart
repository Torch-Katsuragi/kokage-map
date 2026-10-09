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
// こかげマップ: QGIS 側で編集された `.qgs` をプロジェクトを開いたときに読み戻す
//
// 印（`kokage/savedAt`）と root の `saveDateTime` が食い違っていれば、
// 最後に書いたのはこかげマップではない＝QGIS（か人）が保存した。そのときだけ
// 寛容インポータで View・スタイル・可視性を取り込み、続く自動更新で
// 正規化＋印つきの `.qgs` に書き戻す。
//
// 印が一致していれば何もしない（自分が書いたものを読み直す意味は無い）。
// 印が無い `.qgs` は他人のファイルとして読む（旧 `project.qgs` を含む）。

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/nodes/folder_node.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'qgs_auto_refresh.dart';
import 'qgs_base_map_import.dart';
import 'qgs_document.dart';
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

  /// [root] の `<dir名>.qgs`（無ければ旧 `project.qgs`）を見て、QGIS 側で保存されていれば取り込む。
  ///
  /// ツリーの子（gpkg とレイヤ）が読み込まれてから呼ぶこと。
  Future<QgsReadBackResult?> run(FolderNode root) async {
    // 開いたら一度は書き直す（中身が同じなら書かない）。まだ `.qgs` が無ければ最初の1本になり、
    // 旧 `.kmeta.json` から移したばかりなら QGIS が読む部分（スタイル・可視性）がそろう
    // （手動の書き出しメニューは撤去したので、ここが唯一の入口）
    final rootPath = root.getAbsoluteFilePath();
    if (rootPath != null) QgsAutoRefresh.instance.schedule(rootPath);

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
    if (results.isEmpty) return null;
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

  /// `<dir名>.qgs`（旧名・改名前の名前からの引き継ぎ込み）。無ければ null。
  /// 設定を持たない dir（キャッシュで分かる）は列挙しない。開いた根は設定が無くても
  /// `.qgs` を書いている（自動更新が必ず書く）ので見る
  Future<String?> _findProjectFile(String dirPath, {required bool isRoot}) async {
    if (!isRoot && !await KMetaService.instance.hasMetaFile(dirPath)) return null;
    return QgsProjectFile.find(dirPath);
  }

  Future<_QgisSaved?> _qgisSaved(FolderNode root, {required bool isRoot}) async {
    final rootPath = root.getAbsoluteFilePath();
    if (rootPath == null) return null;

    final path = await _findProjectFile(rootPath, isRoot: isRoot);
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
    // 持ち主の dir にこかげマップが最後に書いた時刻（印の savedAt）。この保存がそれより古ければ、
    // その持ち主の分は古い写しなので取り込まない（持ち主が別の端末で直されて同期で届いた等）
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
