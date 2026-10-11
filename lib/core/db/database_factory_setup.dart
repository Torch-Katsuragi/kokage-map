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
/// sqflite の実装をプラットフォームごとに選ぶ。
///
/// - モバイル … 標準実装（何もしない）
/// - web … `sqflite_common_ffi_web`（sqlite3 WASM）
library;

import 'database_factory_setup_io.dart'
    if (dart.library.js_interop) 'database_factory_setup_web.dart' as impl;

/// アプリ起動時に一度だけ呼ぶ。
void setupDatabaseFactory() => impl.setupDatabaseFactory();
