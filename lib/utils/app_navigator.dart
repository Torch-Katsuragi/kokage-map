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
// BuildContext を持たないところ（道具・状態のクラス）からダイアログを出す口

import 'package:flutter/widgets.dart';

/// アプリの Navigator（MaterialApp の navigatorKey）
final appNavigatorKey = GlobalKey<NavigatorState>();

/// ダイアログを出せる BuildContext（いちばん上の Overlay）。アプリが組まれていなければ null
BuildContext? get appDialogContext {
  final context = appNavigatorKey.currentState?.overlay?.context;
  return context != null && context.mounted ? context : null;
}
