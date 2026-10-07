// Drive の検索式に名前を入れるときは `'` と `\` を逃がす（2026-10-07）。
//
// 以前はそのまま囲んでいたので、`'` を含む名前（例: `O'Neil 林班`）で検索式が壊れ、
// 同名のファイルを Drive にもう 1 つ作ったり、サブフォルダを解決できずに上げられなかったりしていた。
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/services/google_drive/google_drive_service.dart';

void main() {
  test('ふつうの名前はそのまま囲む', () {
    expect(GoogleDriveService.queryLiteral('林班1.gpkg'), "'林班1.gpkg'");
  });

  test("' と \\ を逃がす", () {
    expect(GoogleDriveService.queryLiteral("O'Neil"), r"'O\'Neil'");
    expect(GoogleDriveService.queryLiteral(r'a\b'), r"'a\\b'");
    expect(GoogleDriveService.queryLiteral(r"\'"), r"'\\\''");
  });
}
