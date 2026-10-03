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
// こかげマップ: 地図のツリーに出さない旧フォルダ（絶対パス、正規化済み）
//
// 2026-10-03 に Global と練習用フォルダを `Documents/KokageMap/.kokage/` に移した。移せなかった旧 Global と
// 旧練習用フォルダは「地図を開く」で開いたときに地図に出さない（GlobalFolderLocator が入れる）。
// ⚠ 後方互換。オープンベータに移るときに消す（web でも読むので dart:io を持ち込まない別ファイル）

final Set<String> hiddenLegacyDirs = {};
