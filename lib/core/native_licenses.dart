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
// pub のパッケージではない同梱物（ネイティブライブラリ）のライセンスを「オープンソースライセンス」画面
// （showLicensePage）に載せる。pub のパッケージは Flutter が自動で載せるが、これらは載らない。
//
// 本文は assets/licenses/ に原文のまま置く（third_party/gdal/README.md）。
// GDAL の LICENSE.TXT は同梱の libtiff・libgeotiff・libjpeg・libpng・json-c・LERC・flatbuffers などの条文も含む。
// SQLite はパブリックドメインなので載せる条文が無い。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _entries = <(List<String>, String)>[
  (['GDAL'], 'assets/licenses/gdal.txt'),
  (['PROJ'], 'assets/licenses/proj.txt'),
  (['Expat'], 'assets/licenses/expat.txt'),
  (['GNU libiconv'], 'assets/licenses/libiconv.txt'),
];

/// main() で 1 回呼ぶ。本文は画面を開いたときに読む
void registerNativeLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (packages, asset) in _entries) {
      yield LicenseEntryWithLineBreaks(packages, await rootBundle.loadString(asset));
    }
  });
}
