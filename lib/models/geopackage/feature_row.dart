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
// 読んだ行（FeatureRepository.getFeature など）の、列でない値の鍵。
//
// 行のほかの鍵は列の名前と値そのまま（主キーの列も、id・fid・geometry というふつうの列も）。
// 鍵は NUL で始めて、表の列の名前と重ならないようにしている（SQLite の識別子は NUL を含められない）。

/// 地物番号を入れる鍵。値は主キーの値（主キーの無い表は rowid）。
///
/// 以前は `id` に入れていて、主キーが fid の表や主キーの無い表にある `id` というふつうの列
/// （林業のデータでよくある）が地物番号で上書きされ、属性表・情報パネル・ラベルに地物番号が出ていた
const featureIdKey = '\u0000fid';
