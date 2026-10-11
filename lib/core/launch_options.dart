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
/// 起動時に外から渡せるオプション（`--dart-define`）。
///
/// 開発・デバッグ用。毎回フォルダピッカーを手で操作しないと地図画面に
/// 入れないと、起動〜地図描画の検証が回せないため用意している。
library;

/// `--dart-define` で渡された起動オプション。
class LaunchOptions {
  const LaunchOptions._();

  /// 起動時に自動で開くプロジェクトフォルダ。
  ///
  /// ```
  /// flutter run -d <端末> --dart-define=PROJECT_DIR=/path/to/project
  /// ```
  ///
  /// 指定が無ければ空文字。存在しないパスを渡した場合は無視して
  /// 通常どおりフォルダ選択画面を出す（呼び出し側で判定する）。
  static const String projectDir = String.fromEnvironment('PROJECT_DIR');

  /// [projectDir] の指定があるか
  static bool get hasProjectDir => projectDir.isNotEmpty;
}
