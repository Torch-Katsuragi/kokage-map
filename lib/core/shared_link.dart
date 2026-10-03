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
// こかげマップ: QR で共有する地図のリンクの形（読み書きだけ。取り込みは services/shared_map_link.dart）
//
// `https://kokage-map.sleeptree.jp/open?drive=<Drive フォルダ ID>`（2026-10-03）

const kSharedLinkHost = 'kokage-map.sleeptree.jp';
const kSharedLinkPath = '/open';

/// Drive フォルダ ID → QR に入れるリンク
String sharedMapLink(String driveId) => Uri.https(kSharedLinkHost, kSharedLinkPath, {'drive': driveId}).toString();

/// リンクから Drive フォルダ ID を取り出す（こかげマップのリンクだけ。Drive の URL は GoogleDriveService が読む）
String? driveIdFromSharedLink(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host != kSharedLinkHost || uri.path != kSharedLinkPath) return null;
  final id = uri.queryParameters['drive'];
  return id == null || id.isEmpty ? null : id;
}
