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
/// ファイルシステム抽象。
///
/// `dart:io` の `File` / `Directory` を直に触る代わりに、ここを通す。
/// web は `dart:io` を呼んだ瞬間に落ちるため、実装をプラットフォームごとに
/// 差し替えられるようにする（[[docs/technical/project-format-design]] 段2）。
///
/// > [!IMPORTANT] 同期APIは**意図的に生やさない**
/// > web の File System Access API に同期版は無い。`existsSync()` に相当するものが
/// > そもそも存在しないので、ここに同期メソッドを1つでも足すと web で実装できなくなる。
/// > 呼び出し側が `async` に変わるのは、この制約を受け入れた結果であって手抜きではない。
///
/// > [!NOTE] アドレスは今までどおり「パス文字列」
/// > web にファイルパスという概念は無く、あるのはディレクトリハンドルだけ。
/// > それでもこの抽象がパス文字列を受けるのは、`PathResolver` から
/// > `LayerTreeNode` まで既存の設計が全てパスで組まれているため。
/// > web実装側が「ルートハンドル + 相対パス」を解決して辻褄を合わせる。
library;

import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'k_file_system_io.dart'
    if (dart.library.js_interop) 'k_file_system_web.dart' as impl;

/// ディレクトリ列挙の1件
class KFileEntry {
  const KFileEntry({required this.path, required this.isDirectory});

  /// 絶対パス（web では仮想ルートからのパス）
  final String path;

  final bool isDirectory;

  String get name => p.basename(path);

  @override
  String toString() =>
      'KFileEntry($path, ${isDirectory ? "dir" : "file"})';
}

/// ファイルシステムの実体。プラットフォームごとに実装が差し替わる。
abstract class KFileSystem {
  /// ファイル・ディレクトリを問わず存在するか
  Future<bool> exists(String path);

  /// ディレクトリとして存在するか
  Future<bool> isDirectory(String path);

  /// 直下の要素を列挙する。存在しなければ空リスト
  Future<List<KFileEntry>> list(String path);

  Future<Uint8List> readAsBytes(String path);

  Future<String> readAsString(String path);

  Future<void> writeAsBytes(String path, Uint8List bytes);

  Future<void> writeAsString(String path, String contents);

  /// ディレクトリを作る（親が無ければ再帰的に作る／既にあれば何もしない）
  Future<void> createDirectory(String path);

  Future<void> delete(String path, {bool recursive = false});

  Future<void> rename(String from, String to);

  /// バイト長。存在しなければ null
  Future<int?> length(String path);

  /// 最終更新日時。存在しなければ null。
  ///
  /// Drive同期が「どちらが新しいか」を決めるのに使う。
  /// web でも `FileSystemFileHandle.getFile()` の `lastModified` で取れる。
  Future<DateTime?> lastModified(String path);

  /// シンボリックリンクをたどった実体のパス。たどれなければ [path] のまま。
  ///
  /// Android の `/sdcard/...` は `/storage/emulated/0/...` と同じ場所を指す。
  /// パスを「同じ場所か」の判定に使うときは、これを通してから比べる。web は [path] のまま。
  Future<String> canonicalPath(String path);

  /// ローカルの実ファイルとして扱えるか。
  ///
  /// ⚠ web は false。`sqflite` や外部プロセスに**パスを渡して開かせる**類の処理は
  /// この抽象では肩代わりできないので、呼ぶ前にここで弾く。
  bool get hasRealPaths;
}

KFileSystem? _override;
KFileSystem? _instance;

/// 現在のファイルシステム。
KFileSystem get fs => _override ?? (_instance ??= impl.createKFileSystem());

/// テスト用に差し替える。[reset] で戻す。
void setFileSystemOverrideForTest(KFileSystem? value) => _override = value;

/// [KFileSystem] に足したい、実装を1つで済ませられるもの。
///
/// 実装クラスは `implements KFileSystem` なので、抽象クラス側に本体を書いても
/// 継承されない。共通処理はここに置く。
extension KFileSystemRecursive on KFileSystem {
  /// 直下だけでなく、下位のディレクトリも全部たどって**ファイルだけ**を返す。
  ///
  /// `dart:io` の `Directory.list(recursive: true)` の置き換え。
  /// web には再帰列挙が無いので [KFileSystem.list] を積み上げる
  /// （native も同じ実装で足りるので、ここで一度だけ書く）。
  ///
  /// > [!WARNING] 深いツリーでは高くつく
  /// > web はディレクトリ1つにつきハンドル走査が1回。
  /// > 呼ぶ側で回数を減らせるなら減らすこと。
  Future<List<KFileEntry>> listRecursive(String path) async {
    final result = <KFileEntry>[];
    final queue = <String>[path];
    while (queue.isNotEmpty) {
      final dir = queue.removeLast();
      for (final entry in await list(dir)) {
        if (entry.isDirectory) {
          queue.add(entry.path);
        } else {
          result.add(entry);
        }
      }
    }
    return result;
  }

  /// 下位のディレクトリを全部たどって**ディレクトリだけ**を返す。
  ///
  /// `dart:io` の `Directory.list(recursive: true).whereType<Directory>()` 相当。
  /// 空フォルダの掃除などに使う。
  Future<List<KFileEntry>> listDirectoriesRecursive(String path) async {
    final result = <KFileEntry>[];
    final queue = <String>[path];
    while (queue.isNotEmpty) {
      final dir = queue.removeLast();
      for (final entry in await list(dir)) {
        if (!entry.isDirectory) continue;
        result.add(entry);
        queue.add(entry.path);
      }
    }
    return result;
  }
}
