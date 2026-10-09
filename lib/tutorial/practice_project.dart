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
// チュートリアル用の練習プロジェクト（小班 2 つ・路網 1 本・空の調査点）
//
// 自分のデータが無くても始められるように、開くたびに作り直す。
// 置き場所は共有フォルダ（Global）の隣。Android なら Documents/KokageMap/練習 で、利用者からも見える。

import 'package:flutter/painting.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../core/fs/k_file_system.dart';
import '../core/fs/project_folder_picker.dart';
import '../i18n/strings.g.dart';
import '../models/geometry_type.dart';
import '../models/geopackage/geopackage_connection.dart';
import '../models/geopackage/geopackage_file.dart';
import '../models/kmeta.dart';
import '../services/global_folder_locator.dart';
import '../services/kmeta_service.dart';

class PracticeProject {
  PracticeProject._(this.dir);

  /// プロジェクトフォルダ（絶対パス）
  final String dir;

  String get gpkgPath => p.join(dir, '${t.tutorial.practice.gpkg}.gpkg');

  // 林業に寄せない一般的な名前にする（ユーザー 2026-10-01「エリアとか測点とか」）
  static String get areaLayer => t.tutorial.practice.area;
  static String get routeLayer => t.tutorial.practice.route;
  static String get pointsLayer => t.tutorial.practice.points;

  static Future<String> _dirPath() async {
    // Global の親（Android は Documents/KokageMap、ほかはアプリの文書フォルダ）
    final global = await GlobalFolderLocator.defaultPath();
    return p.join(p.dirname(global), t.tutorial.practice.folder);
  }

  /// 練習プロジェクトのパス（作らない）。ツリーのノードが練習用かを見分けるのに使う
  static String? knownDir;

  /// 作り直して返す。前回の練習で打った点などは消える（[at] はテスト用の置き場所）
  static Future<PracticeProject> recreate({String? at}) async {
    // web はブラウザのサイト専用領域（OPFS）に空で作ってそこを開く（ルートそのものなので消し直しも向こうで済む）
    final webDir = at == null ? await preparePracticeFolder(t.tutorial.practice.folder) : null;
    final dir = at ?? webDir ?? await _dirPath();
    final proj = PracticeProject._(dir);
    // 前回の練習の接続が残っていると、消して作り直したファイルに書けない（SQLITE_READONLY_DBMOVED）
    await GeoPackageConnection.closeAllFor(proj.gpkgPath);
    if (webDir == null) {
      if (await fs.exists(dir)) await fs.delete(dir, recursive: true);
      await fs.createDirectory(dir);
    }
    await proj._writeData();
    // 塗りの既定（黒 10%）は地形の上だとほとんど見えず、「見え方を変える」で色を変えても変わったと分からない
    await KMetaService.instance.setLayerStyle(
      dir,
      '${p.basename(proj.gpkgPath)}/$areaLayer',
      const KMetaLayerStyle(polygonFillColor: Color(0xFF2E7D32), polygonFillOpacity: 0.45),
    );
    knownDir = dir;
    return proj;
  }

  Future<void> _writeData() async {
    final name = p.basename(gpkgPath);
    final gpkg = GeoPackageFile([name], absolutePath: gpkgPath);
    if (!await gpkg.createEmptyDatabase()) {
      throw StateError('practice gpkg: create failed');
    }
    final pr = t.tutorial.practice;
    // 名前は `name` の列（アプリが地物の名前として読む列。線を引いたときの名前もここに入る）
    final fields = {'name': 'TEXT', pr.memo: 'TEXT'};

    await gpkg.addLayer(areaLayer, GeometryType.polygon);
    await gpkg.addAttributeColumns(areaLayer, fields);
    // 尾根を挟んで東西に並ぶ 2 つのエリア（おおよそ 250m 四方。北山村の大沼の南東の山）
    await gpkg.addPolygonWithAttributes(areaLayer, [
      const [
        LatLng(33.9312, 135.9707), LatLng(33.9316, 135.9736), LatLng(33.9291, 135.9741),
        LatLng(33.9278, 135.9723), LatLng(33.9287, 135.9703), LatLng(33.9312, 135.9707),
      ],
    ], {'name': pr.areaA, pr.memo: pr.memoExample});
    await gpkg.addPolygonWithAttributes(areaLayer, [
      const [
        LatLng(33.9316, 135.9736), LatLng(33.9309, 135.9772), LatLng(33.9282, 135.9768),
        LatLng(33.9274, 135.9747), LatLng(33.9291, 135.9741), LatLng(33.9316, 135.9736),
      ],
    ], {'name': pr.areaB, pr.memo: ''});

    await gpkg.addLayer(routeLayer, GeometryType.linestring);
    await gpkg.addAttributeColumns(routeLayer, fields);
    await gpkg.addLineWithAttributes(routeLayer, const [
      LatLng(33.9260, 135.9695), LatLng(33.9275, 135.9715), LatLng(33.9278, 135.9735),
      LatLng(33.9272, 135.9757), LatLng(33.9280, 135.9780),
    ], {'name': pr.route1});

    await gpkg.addLayer(pointsLayer, GeometryType.point);
    await gpkg.addAttributeColumns(pointsLayer, fields);

    await gpkg.dispose();
  }
}
