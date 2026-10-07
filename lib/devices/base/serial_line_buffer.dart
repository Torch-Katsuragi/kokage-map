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
/// Bluetooth SPP で届くバイト列を行に切る（外部 GNSS・TruPulse 共通）
library;

import 'dart:convert';

class SerialLineBuffer {
  String _partial = '';

  /// [data] を足して、揃った行を返す（前後の空白を除き、空行は除く）。
  /// 行の途中で切れたぶんは次に回す。UTF-8 として読めないかたまりは例外（何も足さない）
  List<String> add(List<int> data) {
    _partial += utf8.decode(data);
    final lines = _partial.split('\n');
    _partial = lines.removeLast();
    return [
      for (final line in lines)
        if (line.trim() case final trimmed when trimmed.isNotEmpty) trimmed,
    ];
  }

  void clear() => _partial = '';
}
