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
// KMZ の中身の見取り図: GDAL に渡す KML と、その NetworkLink が指す zip の中の KML
// 設計は docs/technical/external-formats.md#KMZ の NetworkLink（2026-10-12）
//
// LIBKML・Google Earth で書いた KMZ は、doc.kml に NetworkLink だけを置き、地物は `files/a.kml` などに分ける。
// 同梱の GDAL は LIBKML を持たず、KML ドライバはリンクをたどらないので、リンク先をここで引いて 1 本ずつ開く。
// 外の URL（http など）は読まない（端末からネットへ取りに行かない）

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

class KmzLayout {
  const KmzLayout({required this.main, this.links = const [], this.skippedLinks = const []});

  /// GDAL に渡す KML（zip の中のパス）。KML が無ければ null
  final String? main;

  /// [main] の NetworkLink が指す、zip の中の KML（出てきた順・重複なし・[main] は除く）
  final List<String> links;

  /// 読まなかった NetworkLink の href（外の URL・zip の外・zip に無いもの・KML でないもの）
  final List<String> skippedLinks;

  /// zip の中身から作る（[main] の KML を読んで NetworkLink を引く）
  factory KmzLayout.fromArchive(Archive archive) {
    final files = archive.files.where((f) => f.isFile).toList();
    final main = mainEntryOf(files.map((f) => f.name));
    if (main == null) return const KmzLayout(main: null);
    final file = files.firstWhere((f) => f.name.replaceAll(r'\', '/') == main);
    final names = [for (final f in files) f.name.replaceAll(r'\', '/')];
    final (links, skipped) = resolveNetworkLinks(main, utf8.decode(file.content, allowMalformed: true), names);
    return KmzLayout(main: main, links: links, skippedLinks: skipped);
  }

  /// KMZ の中で読む KML（Google Earth と同じく、根の `doc.kml`、無ければ根の最初の `.kml`、無ければどこかの最初の `.kml`）。
  /// KML が無ければ null
  static String? mainEntryOf(Iterable<String> names) {
    final kmls = [for (final n in names) n.replaceAll(r'\', '/')].where((n) => n.toLowerCase().endsWith('.kml')).toList();
    bool atRoot(String n) => !n.contains('/');
    return kmls.where((n) => atRoot(n) && n.toLowerCase() == 'doc.kml').firstOrNull ??
        kmls.where(atRoot).firstOrNull ??
        kmls.firstOrNull;
  }

  /// [kml]（zip の中の [entry]）の NetworkLink の href を、zip の中のパスに直す。
  /// 返り値は（読む KML、読まなかった href）。KML として読めなければ両方空。
  ///
  /// href は [entry] のある dir からの相対パス。`%20` などは戻す。大文字小文字は zip の中の名前に合わせる。
  /// リンク先の中の NetworkLink はたどらない（QGIS の LIBKML も 1 段だけ）
  static (List<String>, List<String>) resolveNetworkLinks(String entry, String kml, Iterable<String> names) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(kml);
    } catch (_) {
      return (const [], const []);
    }
    final byLower = <String, String>{};
    for (final n in names) {
      byLower.putIfAbsent(n.toLowerCase(), () => n);
    }
    final links = <String>[];
    final skipped = <String>[];
    for (final link in doc.findAllElements('NetworkLink', namespaceUri: '*')) {
      // KML 2.2 は <Link><href>、2.0 は <Url><href>
      final href = link.findAllElements('href', namespaceUri: '*').firstOrNull?.innerText.trim();
      if (href == null || href.isEmpty) continue;
      final resolved = _resolve(entry, href, byLower);
      if (resolved == null) {
        if (!skipped.contains(href)) skipped.add(href);
      } else if (resolved != entry && !links.contains(resolved)) {
        links.add(resolved);
      }
    }
    return (links, skipped);
  }

  /// [href] を zip の中の KML のパスに。読めないものは null
  static String? _resolve(String entry, String href, Map<String, String> byLower) {
    final Uri uri;
    try {
      uri = Uri.parse(href);
    } catch (_) {
      return null;
    }
    // 外の URL（http・https・file など）と根からのパスは読まない。Windows のドライブ（`C:`）も scheme に見える
    if (uri.hasScheme || href.startsWith('/') || href.startsWith(r'\')) return null;
    final base = p.url.dirname(entry);
    for (final raw in {uri.path, _decode(uri.path)}) {
      final path = p.url.normalize(p.url.join(base, raw.replaceAll(r'\', '/')));
      if (path == '..' || path.startsWith('../')) return null;
      if (!path.toLowerCase().endsWith('.kml')) continue;
      final hit = byLower[path.toLowerCase()];
      if (hit != null) return hit;
    }
    return null;
  }

  static String _decode(String s) {
    try {
      return Uri.decodeFull(s);
    } catch (_) {
      return s;
    }
  }
}
