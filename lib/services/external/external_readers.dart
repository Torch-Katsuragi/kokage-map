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
// gpkg 以外の形式の読み手の一覧（拡張子で引く）
// 設計は docs/technical/external-formats.md

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../utils/app_logger.dart';
import 'external_dataset.dart';
import 'readers/geojson_reader.dart';
import 'readers/shapefile_reader.dart';

/// 読み手の一覧。形式を足すときはここに 1 行足す
final List<ExternalReader> externalReaders = [
  ShapefileReader(),
  GeoJsonReader(),
];

/// [path] の拡張子を受け持つ読み手（大文字小文字は区別しない）。無ければ null
ExternalReader? externalReaderFor(String path) {
  final ext = p.extension(path).toLowerCase();
  if (ext.isEmpty) return null;
  for (final reader in externalReaders) {
    if (reader.extensions.contains(ext)) return reader;
  }
  return null;
}

/// 中身で判定した結果の控え（パス → 更新時刻と大きさ・結果）。
/// フォルダを開くたびに `.json` を読み直さないため
final Map<String, ({DateTime? modified, int? size, bool accepted})> _acceptCache = {};

/// [path] が外部形式のレイヤとして開けるか（拡張子と中身の両方で判定）。開けるならその読み手
Future<ExternalReader?> acceptingExternalReader(String path) async {
  final reader = externalReaderFor(path);
  if (reader == null) return null;
  try {
    final modified = await fs.lastModified(path);
    final size = await fs.length(path);
    final cached = _acceptCache[path];
    if (cached != null && cached.modified == modified && cached.size == size) {
      return cached.accepted ? reader : null;
    }
    final accepted = await reader.accepts(path);
    _acceptCache[path] = (modified: modified, size: size, accepted: accepted);
    return accepted ? reader : null;
  } catch (e) {
    AppLogger.debug('[ExternalReaders] 判定できない: $path - $e');
    return null;
  }
}

/// [path] と一緒に扱う付属ファイルの実在するパス（[path] 自身は含まない）。
///
/// 付属ファイルは「拡張子を除いた名前 + 付属の拡張子」で、大文字小文字を区別せずに探す
/// （`林班.SHP` と `林班.dbf` が混ざっていることがある）
Future<List<String>> existingSidecars(String path, ExternalReader reader) async {
  final sidecars = reader.sidecarExtensions;
  if (sidecars.isEmpty) return const [];
  final stem = p.basenameWithoutExtension(path).toLowerCase();
  final self = p.basename(path).toLowerCase();
  final wanted = {for (final ext in sidecars) '$stem$ext'};
  final out = <String>[];
  for (final entry in await fs.list(p.dirname(path))) {
    if (entry.isDirectory) continue;
    final name = entry.name.toLowerCase();
    if (name == self) continue;
    if (wanted.contains(name)) out.add(entry.path);
  }
  out.sort();
  return out;
}

/// [path] の付属ファイルのうち拡張子が [ext]（小文字・点つき）のもの。無ければ null
Future<String?> findSidecar(String path, String ext) async {
  final want = '${p.basenameWithoutExtension(path)}$ext'.toLowerCase();
  for (final entry in await fs.list(p.dirname(path))) {
    if (!entry.isDirectory && entry.name.toLowerCase() == want) return entry.path;
  }
  return null;
}
