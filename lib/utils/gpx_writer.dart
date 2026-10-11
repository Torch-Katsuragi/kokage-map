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
/// GPS 軌跡を GPX 1.1 に書く（trk / trkseg / trkpt、時刻と標高つき）。
///
/// レイヤの書き出し（GDAL）の GPX は線の形だけで、点ごとの時刻が残らない。軌跡は記録した点（時刻・標高）から直接書く
library;

import '../models/gps_track.dart';

/// [segments]（区間ごとの点の列）を 1 本の trk にして GPX 1.1 の文字列にする。
/// 空の区間は書かない。標高（[GpsTrackPoint.altitude]）が無い点は `<ele>` を省く
String buildTrackGpx(
  List<List<GpsTrackPoint>> segments, {
  required String name,
  String creator = 'Kokage Map',
}) {
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<gpx version="1.1" creator="${_esc(creator)}" xmlns="http://www.topografix.com/GPX/1/1" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
      'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">',
    );
  final first = segments.expand((s) => s).firstOrNull;
  b
    ..writeln('  <metadata>')
    ..writeln('    <name>${_esc(name)}</name>');
  if (first != null) b.writeln('    <time>${_time(first.timestamp)}</time>');
  b
    ..writeln('  </metadata>')
    ..writeln('  <trk>')
    ..writeln('    <name>${_esc(name)}</name>');
  for (final seg in segments) {
    if (seg.isEmpty) continue;
    b.writeln('    <trkseg>');
    for (final p in seg) {
      b.write('      <trkpt lat="${p.latitude.toStringAsFixed(8)}" lon="${p.longitude.toStringAsFixed(8)}">');
      // GPX 1.1 の順序: ele → time
      if (p.altitude case final ele? when ele.isFinite) b.write('<ele>${ele.toStringAsFixed(2)}</ele>');
      b.writeln('<time>${_time(p.timestamp)}</time></trkpt>');
    }
    b.writeln('    </trkseg>');
  }
  b
    ..writeln('  </trk>')
    ..writeln('</gpx>');
  return b.toString();
}

/// GPX の時刻（UTC、秒まで + Z）
String _time(DateTime t) {
  final s = t.toUtc().toIso8601String();
  final dot = s.indexOf('.');
  return dot < 0 ? s : '${s.substring(0, dot)}Z';
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
