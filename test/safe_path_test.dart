// 外から来た名前を手元のパスにするときの検査（2026-10-09）。
//
// Drive の名前は `/` や `..` を含められる。共有リンクで取り込んだフォルダから外へ書けないこと、
// ふつうの名前（日本語・スペース入り）はそのまま通ることを押さえる。
// 起動ルートの `project=` と、Drive の ID・URL の検査もここで見る。
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/fs/safe_path.dart';
import 'package:root_maps/core/launch_request.dart';
import 'package:root_maps/core/shared_link.dart';
import 'package:root_maps/services/google_drive/google_drive_service.dart';
import 'package:root_maps/services/google_drive/sync_base_store.dart';

void main() {
  final base = p.join(p.current, 'proj');

  group('resolveUnder', () {
    test('ふつうの名前はそのまま下に置く（日本語・スペース入り）', () {
      expect(resolveUnder(base, '林班 1.gpkg'), p.join(base, '林班 1.gpkg'));
      expect(resolveUnder(base, '北山村/第2 林班/写真 A.jpg'), p.join(base, '北山村', '第2 林班', '写真 A.jpg'));
      expect(resolveUnder(base, '.hidden.jpg'), p.join(base, '.hidden.jpg'));
      expect(resolveUnder(base, 'a..b.jpg'), p.join(base, 'a..b.jpg'));
    });

    for (final bad in [
      '../x',
      'a/../../x',
      '..',
      '.',
      'a/./b',
      'C:x',
      r'a\..\x',
      r'..\x',
      '/abs',
      'a//b',
      'a/',
      '',
      'a\u0000b',
      'a\nb',
    ]) {
      test('外を指しうるものは投げる: ${bad.replaceAll('\n', r'\n').replaceAll('\u0000', r'\0')}', () {
        expect(() => resolveUnder(base, bad), throwsA(isA<UnsafePathException>()));
        expect(isSafeRelativePath(bad), isFalse);
      });
    }
  });

  test('3-way マージの base も同じ検査を通る', () {
    expect(SyncBaseStore.basePath(base, 'a/b.gpkg'), p.join(base, '.sync', 'base', 'a', 'b.gpkg'));
    expect(() => SyncBaseStore.basePath(base, '../../x.gpkg'), throwsA(isA<UnsafePathException>()));
  });

  test('toLocalFolderName: フォルダ名 1 段にする。使えなければ代わりの名前', () {
    expect(toLocalFolderName(' 北山村 共有 ', fallback: 'ID'), '北山村 共有');
    expect(toLocalFolderName('a/../b', fallback: 'ID'), 'a_.._b');
    expect(toLocalFolderName(r'C:\x', fallback: 'ID'), 'C__x');
    expect(toLocalFolderName('..', fallback: 'ID'), 'ID');
    expect(toLocalFolderName('.', fallback: 'ID'), 'ID');
    expect(toLocalFolderName('...', fallback: 'ID'), 'ID');
    expect(toLocalFolderName('  ', fallback: 'ID'), 'ID');
  });

  group('Drive の ID', () {
    test('ID の形だけ通す', () {
      expect(isDriveId('1AbC_d-9'), isTrue);
      expect(isDriveId(''), isFalse);
      expect(isDriveId("x' or 'a' in parents"), isFalse);
      expect(isDriveId('a b'), isFalse);
    });

    test('検索式に入れるときも ID の形でなければ投げる', () {
      expect(GoogleDriveService.inParents('1AbC_d-9'), "'1AbC_d-9' in parents");
      expect(() => GoogleDriveService.inParents("x' or trashed = true or '"), throwsArgumentError);
    });

    test('URL は google.com とその下だけ', () {
      expect(GoogleDriveService.extractFolderIdFromUrl('https://drive.google.com/drive/folders/1AbC'), '1AbC');
      expect(GoogleDriveService.extractFolderIdFromUrl('https://google.com/open?id=1AbC'), '1AbC');
      expect(GoogleDriveService.extractFolderIdFromUrl('https://evilgoogle.com/drive/folders/1AbC'), isNull);
      expect(GoogleDriveService.extractFolderIdFromUrl('https://drive.google.com.evil.example/drive/folders/1AbC'), isNull);
      expect(GoogleDriveService.extractFolderIdFromUrl("https://drive.google.com/open?id=x'y"), isNull);
    });

    test('共有リンクも ID の形だけ', () {
      expect(driveIdFromSharedLink('https://kokage-map.sleeptree.jp/open?drive=1AbC'), '1AbC');
      expect(driveIdFromSharedLink("https://kokage-map.sleeptree.jp/open?drive=x'y"), isNull);
      expect(driveIdFromSharedLink('https://kokage-map.sleeptree.jp/openx?drive=1AbC'), isNull);
    });
  });

  test('起動ルートの project: native は開発用ビルドだけ、web は opfs:<1 段の名前> だけ', () {
    expect(LaunchRequest.acceptsProject('/sdcard/x', web: false, devBuild: true), isTrue);
    expect(LaunchRequest.acceptsProject('/sdcard/x', web: false, devBuild: false), isFalse);
    expect(LaunchRequest.acceptsProject('opfs:練習', web: true), isTrue);
    expect(LaunchRequest.acceptsProject('opfs:../x', web: true), isFalse);
    expect(LaunchRequest.acceptsProject('opfs:..', web: true), isFalse);
    expect(LaunchRequest.acceptsProject('/sdcard/x', web: true), isFalse);
  });
}
