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
/// native のフォルダ選択（OSのピッカー）。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';

bool get canPickProjectFolder => true;

Future<String?> pickProjectFolder() => FilePicker.getDirectoryPath();

/// native はブラウザのような「権限が切れる」事情が無いので、この経路は使わない
Future<String?> lastProjectFolderName() async => null;

Future<String?> reopenLastProjectFolder() async => null;

Future<String?> openRequestedProjectFolder(String spec) async =>
    Directory(spec).existsSync() ? spec : null;

Future<String?> preparePracticeFolder(String name) async => null;
