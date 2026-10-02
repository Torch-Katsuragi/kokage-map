// テストのプロセスごとに一時フォルダ（TMP）を分ける（2026-10-02）。
//
// geodiff.dll は一時ファイル名を rand() で作るが srand() を呼ばないので、どのプロセスでも同じ名前の並び
// （`geodiff_rgRYwT_base2modified.bin` …）になる。`flutter test` はテストファイルを別プロセスで並べて走らせるため、
// geodiff を使うテストが 2 つ重なると同じ一時ファイルを取り合い、ときどき rebase が落ちていた
// （「時々落ちるテスト」の正体。アプリは 1 プロセスなので起きない）。
// geodiff は一時フォルダを GetTempPath（= 環境変数 TMP）から取るので、プロセスの TMP を専用のフォルダに向ける。
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final dir = Platform.isWindows ? _isolateTempDir() : null;
  // 全部終わったら片付ける（testMain はテストを登録するだけなので、その後ろでは消さない）
  if (dir != null) {
    tearDownAll(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {} // テストが掴んだままのファイルがあれば残す
    });
  }
  await testMain();
}

Directory _isolateTempDir() {
  final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}kokage_test_$pid')..createSync(recursive: true);
  final setEnv = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>(
          'SetEnvironmentVariableW');
  for (final name in ['TMP', 'TEMP']) {
    final n = name.toNativeUtf16();
    final v = dir.path.toNativeUtf16();
    setEnv(n, v);
    malloc
      ..free(n)
      ..free(v);
  }
  return dir;
}
