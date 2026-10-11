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
// こかげマップ: `.qgs` のラスタレイヤ（gdal の GeoTIFF・wms の XYZ タイル）を読む部品
//
// 設計は [[docs/technical/external-formats#`.qgs` との往復]]。
// dir に置かれたファイルが正で、`.qgs` からは表示の設定（可視・不透明度）だけを取る。

import 'package:xml/xml.dart';

import '../../models/basemap_provider.dart';

/// `.qgs` の XYZ タイルのレイヤを、背景地図の一覧のどれに当たるか読んだもの
class QgsBaseMap {
  const QgsBaseMap({
    required this.providerId,
    required this.layerName,
    required this.visible,
    required this.opacity,
    this.custom,
  });

  /// 当たった [BaseMapProvider.id]（一覧に無い URL なら [custom] の id）
  final String providerId;

  /// 一覧に無い URL の XYZ / WMS から作った利用者の地図の定義。足すときに端末の利用者の地図にも入れる
  final BaseMapProvider? custom;

  /// QGIS 上のレイヤ名（報告用）
  final String layerName;

  /// レイヤツリーの checked（祖先のグループで畳んだもの）
  final bool visible;

  /// 0〜100（`<rasterrenderer opacity=>` を百分率にしたもの）
  final int opacity;
}

/// `<maplayer type="raster">` の読み取り
abstract final class QgsRasterSource {
  /// wms プロバイダの URI（`type=xyz&url=https%3A%2F%2F…&zmax=18`）を分解する。
  /// 値は URL エンコードを外す（QGIS は `url` を符号化して書く）
  static Map<String, String> parseWmsUri(String uri) {
    final result = <String, String>{};
    for (final part in uri.split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final key = (eq < 0 ? part : part.substring(0, eq)).trim();
      final raw = eq < 0 ? '' : part.substring(eq + 1);
      String value;
      try {
        value = Uri.decodeComponent(raw);
      } on ArgumentError {
        value = raw;
      }
      result.putIfAbsent(key, () => value);
    }
    return result;
  }

  /// XYZ タイルなら URL テンプレート、そうでなければ（本物の WMS / WMTS）null
  static String? xyzUrl(String uri) {
    final params = parseWmsUri(uri);
    if (params['type']?.toLowerCase() != 'xyz') return null;
    final url = params['url'];
    return url == null || url.isEmpty ? null : url;
  }

  /// 本物の WMS（`type=xyz` でも WMTS でもない）を、EPSG:3857 のタイルとして引く GetMap の URL テンプレートにする。
  /// 扱えなければ null（WMTS・`url` か `layers` が無い）。
  ///
  /// ⚠ `.qgs` の `crs` に関係なく EPSG:3857 で頼む（地図は Web メルカトルのタイルで描くので）。
  /// サーバーが 3857 を出さなければ白いまま（設定画面の「タイルを 1 枚取ってみる」で分かる）
  static String? wmsGetMapTemplate(String uri) {
    final layers = <String>[];
    final styles = <String>[];
    String? url;
    String? format;
    var wmts = false;
    for (final part in uri.split('&')) {
      final eq = part.indexOf('=');
      final key = (eq < 0 ? part : part.substring(0, eq)).trim().toLowerCase();
      final raw = eq < 0 ? '' : part.substring(eq + 1);
      String value;
      try {
        value = Uri.decodeComponent(raw);
      } on ArgumentError {
        value = raw;
      }
      switch (key) {
        case 'url':
          url ??= value;
        case 'layers':
          layers.add(value);
        case 'styles':
          styles.add(value);
        case 'format':
          format ??= value;
        case 'tilematrixset':
          wmts = true;
        case 'type':
          if (value.toLowerCase() != 'wms') wmts = true; // xyz / wmts / mbtiles など
      }
    }
    if (wmts || url == null || url.isEmpty || layers.isEmpty || layers.every((l) => l.isEmpty)) return null;
    String enc(Iterable<String> v) => v.map(Uri.encodeQueryComponent).join(',');
    final sep = url.contains('?') ? (url.endsWith('?') || url.endsWith('&') ? '' : '&') : '?';
    return '$url${sep}SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap'
        '&LAYERS=${enc(layers)}&STYLES=${enc(styles.length == layers.length ? styles : layers.map((_) => ''))}'
        '&FORMAT=${Uri.encodeQueryComponent(format ?? 'image/png')}&TRANSPARENT=TRUE'
        '&CRS=EPSG:3857&WIDTH=256&HEIGHT=256&BBOX={bbox-epsg-3857}';
  }

  /// ファイルとして持ち歩けないデータソース（`/vsicurl/`、`https://`、`GPKG:…:table` のようなドライバ指定）
  static bool isNonFileSource(String source) {
    final s = source.trim();
    if (s.startsWith('/vsi') || s.contains('://')) return true;
    // `GPKG:` `NETCDF:` などのドライバ接頭辞。Windows のドライブレター（`C:\`）は 1 文字なので除く
    return RegExp('^[A-Za-z][A-Za-z0-9_]+:').hasMatch(s);
  }

  /// `<pipe><rasterrenderer opacity="0.6">` を 0〜100 で。無ければ 100
  static int opacityPercent(XmlElement maplayer) {
    final renderer = maplayer.getElement('pipe')?.getElement('rasterrenderer');
    final value = double.tryParse(renderer?.getAttribute('opacity') ?? '');
    if (value == null) return 100;
    return (value * 100).round().clamp(0, 100);
  }
}
