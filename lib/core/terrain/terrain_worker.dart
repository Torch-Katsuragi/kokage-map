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
/// 地形まわりの重い計算（DEM の組み立て・メッシュの前計算）を流す常駐 isolate の小さなプール
///
/// `compute` は呼ぶたびに isolate を起動する。引いた瞬間に 40 枚ぶん同時に起動すると
/// debug では 1 本 30MB 超・起動 1 秒超で、メモリが 1GB 以上膨らんだ（Android 実機で実測）。
/// io では [TerrainWorker.size] 本を起動したまま使い回し、web ではその場で実行する。
/// 使い方: `TerrainWorker.instance.run(staticFn, arg)`（fn は静的関数か top-level 関数、arg と戻り値は isolate 間で送れる型）
library;

export 'terrain_worker_io.dart' if (dart.library.js_interop) 'terrain_worker_web.dart';
