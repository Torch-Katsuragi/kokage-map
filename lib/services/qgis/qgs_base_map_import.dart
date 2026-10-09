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
// こかげマップ: `.qgs` の XYZ タイルを背景地図のレイヤに足す
//
// > [!IMPORTANT] 背景地図は端末の設定（プロジェクトの設定ではない）
// > `.qgs` を読むたびに足していくと、開くたびに積み上がり、消しても次の読み戻しで戻ってくる。
// > そこで **一度でも `.qgs` から足したプロバイダは二度と自動では足さない**（端末に印を持つ）。
// > すでに一覧にあるプロバイダは、可視・不透明度も含めて触らない（端末の利用者の選択を優先）。
// > 決定は [[docs/technical/external-formats#`.qgs` との往復]]。

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/basemap_layer.dart';
import '../../models/basemap_provider.dart';
import '../../utils/app_logger.dart';
import '../basemap_service.dart';
import 'qgs_raster_source.dart';

abstract final class QgsBaseMapImport {
  /// `.qgs` から足したことのあるプロバイダ id（端末ごと）
  static const prefsKey = 'basemap_qgs_imported';

  /// [current]（下から上へ）に [incoming] を上へ足した並びと、足したプロバイダ id。
  ///
  /// 足すのは「一覧に無い」かつ「[alreadyImported] に無い」ものだけ。同じプロバイダが
  /// [incoming] に複数あれば最初の 1 枚
  static ({List<BaseMapLayer> layers, List<String> added}) merge(
    List<BaseMapLayer> current,
    List<QgsBaseMap> incoming,
    Set<String> alreadyImported,
  ) {
    final layers = [...current];
    final added = <String>[];
    for (final b in incoming) {
      if (alreadyImported.contains(b.providerId)) continue;
      if (layers.any((l) => l.providerId == b.providerId)) continue;
      if (BaseMapProvider.getProviderById(b.providerId) == null) continue;
      layers.add(BaseMapLayer(providerId: b.providerId, visible: b.visible, opacity: b.opacity));
      added.add(b.providerId);
    }
    return (layers: layers, added: added);
  }

  /// [incoming] を端末の背景地図に足し、足したプロバイダの名前を返す
  static Future<List<String>> apply(List<QgsBaseMap> incoming, {BaseMapService? service}) async {
    if (incoming.isEmpty) return const [];
    final svc = service ?? BaseMapService();
    final prefs = await SharedPreferences.getInstance();
    final imported = (prefs.getStringList(prefsKey) ?? const <String>[]).toSet();

    await svc.initialize();
    // 初期化に失敗して一覧が空のまま書くと、端末の背景地図を消してしまう
    if (svc.layers.isEmpty) {
      AppLogger.debug('[QgsBaseMapImport] 背景地図の設定が読めていないので足さない');
      return const [];
    }

    final (:layers, :added) = merge(svc.layers, incoming, imported);
    if (added.isNotEmpty) await svc.setLayers(layers);
    // 一覧に既にあったものも印を付ける（あとで消したときに戻さない）
    final next = {...imported, for (final b in incoming) b.providerId};
    if (next.length != imported.length) await prefs.setStringList(prefsKey, next.toList()..sort());

    AppLogger.debug('[QgsBaseMapImport] 背景地図に ${added.join(', ')} を足した（.qgs の XYZ ${incoming.length} 枚）');
    return [for (final id in added) BaseMapProvider.getProviderById(id)!.name];
  }
}
