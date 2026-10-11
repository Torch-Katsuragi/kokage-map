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
// こかげマップ: 地物に付ける写真の置き場所と、写真の列の決まり（DB も FS も触らない）
//
// 置き場所: `<gpkg の dir>/photos/<レイヤ名>/<yyyyMMdd_HHmmss>_<fid>.jpg`
// 列: `photo`、2 枚目からは `photo_2`, `photo_3`, …（1 列 1 枚。QGIS の ExternalResource が 1 列 1 ファイルなので）
// 値: gpkg の dir からの相対パス（区切りは `/`）。例 `photos/林小班/20261011_093012_12.jpg`
//
// 詳細と理由は [[docs/features/feature-photos]]。

import 'package:path/path.dart' as p;

class FeaturePhotoPaths {
  FeaturePhotoPaths._();

  /// 写真を入れる dir の名前（gpkg と同じ dir の下）
  static const dirName = 'photos';

  /// 1 枚目の列
  static const baseColumn = 'photo';

  static final _columnPattern = RegExp(r'^photo(?:_(\d+))?$', caseSensitive: false);

  /// [index] 枚目（0 始まり）の列の名前。0 は `photo`、1 は `photo_2`
  static String columnAt(int index) => index == 0 ? baseColumn : '${baseColumn}_${index + 1}';

  /// 写真の列か（`photo`・`photo_2`…。大文字小文字は問わない）
  static bool isPhotoColumn(String name) {
    final m = _columnPattern.firstMatch(name);
    if (m == null) return false;
    final n = m.group(1);
    return n == null || (int.tryParse(n) ?? 0) >= 2;
  }

  /// 写真の列の並び順（`photo` が 0、`photo_2` が 1…）。写真の列でなければ null
  static int? columnOrder(String name) {
    if (!isPhotoColumn(name)) return null;
    final n = _columnPattern.firstMatch(name)!.group(1);
    return n == null ? 0 : int.parse(n) - 1;
  }

  /// 地物の属性から、写真の列と値（空でないもの）を列の順に
  static List<({String column, String path})> linksOf(Map<String, dynamic>? properties) {
    if (properties == null) return const [];
    final cols = properties.keys.where(isPhotoColumn).toList()
      ..sort((a, b) => columnOrder(a)!.compareTo(columnOrder(b)!));
    return [
      for (final c in cols)
        if ('${properties[c] ?? ''}'.trim().isNotEmpty) (column: c, path: '${properties[c]}'.trim()),
    ];
  }

  /// 次の写真を入れる列。空いている写真の列があればそこ（若い順）、無ければ新しい列の名前。
  /// [existingColumns] はレイヤの列、[properties] はその地物の値
  static ({String column, bool create}) nextColumn(
    Iterable<String> existingColumns,
    Map<String, dynamic>? properties,
  ) {
    final photoCols = existingColumns.where(isPhotoColumn).toList()
      ..sort((a, b) => columnOrder(a)!.compareTo(columnOrder(b)!));
    for (final c in photoCols) {
      if ('${properties?[c] ?? ''}'.trim().isEmpty) return (column: c, create: false);
    }
    final used = {for (final c in photoCols) columnOrder(c)!};
    var i = 0;
    while (used.contains(i)) {
      i++;
    }
    return (column: columnAt(i), create: true);
  }

  /// dir の名前に使えない文字を `_` に（Windows・Drive で困らないように）
  static String safeSegment(String name) {
    final s = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    // 末尾の点と空白は Windows が落とす
    final trimmed = s.replaceAll(RegExp(r'[. ]+$'), '');
    return trimmed.isEmpty ? '_' : trimmed;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// `yyyyMMdd_HHmmss_<fid>.jpg`（端末の時計の現地時刻）
  static String fileName(DateTime time, int fid, {String ext = '.jpg'}) {
    final d = '${time.year.toString().padLeft(4, '0')}${_two(time.month)}${_two(time.day)}';
    final t = '${_two(time.hour)}${_two(time.minute)}${_two(time.second)}';
    return '${d}_${t}_$fid${ext.toLowerCase()}';
  }

  /// gpkg の dir からの相対パス（`photos/<レイヤ>/<ファイル名>`。区切りは `/`）
  static String relativePath(String layerName, String fileName) =>
      '$dirName/${safeSegment(layerName)}/$fileName';

  /// [rel] と重ならない名前に（`_1`, `_2` … を足す）。[taken] は既にある相対パス（小文字で比べる）
  static String uniqueRelative(String rel, bool Function(String rel) taken) {
    if (!taken(rel)) return rel;
    final dir = p.posix.dirname(rel);
    final ext = p.posix.extension(rel);
    final base = p.posix.basenameWithoutExtension(rel);
    for (var i = 1;; i++) {
      final candidate = '$dir/${base}_$i$ext';
      if (!taken(candidate)) return candidate;
    }
  }

  /// 属性の値（相対パス・絶対パス）を実際のパスに。相対は gpkg の dir から解く。
  /// gpkg の dir の外へ出る相対パス（`../`）も QGIS と同じくそのまま解く
  static String resolve(String gpkgDir, String value) {
    final v = value.trim();
    if (p.isAbsolute(v) || p.windows.isAbsolute(v)) return v;
    return p.normalize(p.joinAll([gpkgDir, ...v.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty)]));
  }
}
