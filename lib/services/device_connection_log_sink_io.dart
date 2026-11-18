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

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// ネイティブ環境では ApplicationSupportDirectory 配下の JSONL ファイルにも書き出す
Future<void> writeDeviceConnectionLogFile(List<String> jsonLines) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'device_connection_events.jsonl'));
    final content = jsonLines.isEmpty ? '' : '${jsonLines.join('\n')}\n';
    await file.writeAsString(content, flush: true);
  } catch (_) {
    // テスト環境等で path_provider が未初期化の場合は SharedPreferences 側のみで保持
  }
}
