// QR で共有する地図のリンク（https://kokage-map.sleeptree.jp/open?drive=<ID>）の読み書き（2026-10-03）
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/shared_link.dart';
import 'package:root_maps/services/google_drive/google_drive_service.dart';

void main() {
  test('ID → リンク → ID', () {
    final link = sharedMapLink('1AbC_d-9');
    expect(link, 'https://kokage-map.sleeptree.jp/open?drive=1AbC_d-9');
    expect(driveIdFromSharedLink(link), '1AbC_d-9');
  });

  test('こかげマップのリンクでなければ null', () {
    expect(driveIdFromSharedLink('https://example.com/open?drive=x'), isNull);
    expect(driveIdFromSharedLink('https://kokage-map.sleeptree.jp/beta/?drive=x'), isNull);
    expect(driveIdFromSharedLink('https://kokage-map.sleeptree.jp/open'), isNull);
  });

  test('アプリ内の QR 読み取りは、新しいリンクも前からの Drive の URL も読める', () {
    expect(GoogleDriveService.extractFolderIdFromUrl('https://kokage-map.sleeptree.jp/open?drive=NEW1'), 'NEW1');
    expect(GoogleDriveService.extractFolderIdFromUrl('https://drive.google.com/drive/folders/OLD1?usp=sharing'), 'OLD1');
  });
}
