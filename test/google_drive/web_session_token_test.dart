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
// web のリロードをまたいでタブに残す Drive のトークン。失効の扱いと、壊れたものを捨てることを確かめる。

import 'package:flutter_test/flutter_test.dart';

import 'package:root_maps/services/google_drive/web_session_token.dart';

void main() {
  late String? stored;
  late DateTime now;
  late WebSessionTokenStore store;

  setUp(() {
    stored = null;
    now = DateTime(2026, 10, 12, 9);
    store = WebSessionTokenStore(
      read: () => stored,
      write: (v) => stored = v,
      remove: () => stored = null,
      now: () => now,
    );
  });

  test('置いたトークンは失効の手前まで読める', () {
    store.save('tok', expiresIn: const Duration(seconds: 3599));
    now = now.add(const Duration(minutes: 50));
    expect(store.load(), 'tok');
  });

  test('失効間近（残りが余白以下）は読めず、消える', () {
    store.save('tok', expiresIn: const Duration(minutes: 10));
    now = now.add(const Duration(minutes: 10) - WebSessionTokenStore.expiryMargin);
    expect(store.load(), isNull);
    expect(stored, isNull);
  });

  test('失効後は読めず、消える', () {
    store.save('tok', expiresIn: const Duration(hours: 1));
    now = now.add(const Duration(hours: 2));
    expect(store.load(), isNull);
    expect(stored, isNull);
  });

  test('寿命が分からなければ仮の寿命で置く', () {
    store.save('tok');
    now = now.add(WebSessionTokenStore.assumedLifetime - WebSessionTokenStore.expiryMargin - const Duration(seconds: 1));
    expect(store.load(), 'tok');
    now = now.add(const Duration(seconds: 2));
    expect(store.load(), isNull);
  });

  test('0 以下の寿命は仮の寿命に置き換える', () {
    store.save('tok', expiresIn: Duration.zero);
    now = now.add(const Duration(minutes: 30));
    expect(store.load(), 'tok');
  });

  test('空のトークンは置かない', () {
    store.save('');
    expect(stored, isNull);
  });

  test('上書きすると新しいトークンと寿命になる', () {
    store.save('old', expiresIn: const Duration(minutes: 5));
    now = now.add(const Duration(minutes: 4));
    store.save('new', expiresIn: const Duration(hours: 1));
    now = now.add(const Duration(minutes: 30));
    expect(store.load(), 'new');
  });

  test('clear で消える', () {
    store.save('tok', expiresIn: const Duration(hours: 1));
    store.clear();
    expect(store.load(), isNull);
  });

  group('壊れた中身は捨てる', () {
    for (final raw in ['', 'not json', '[]', '{"t":"tok"}', '{"t":"","exp":1}', '{"t":1,"exp":1}', '{"t":"tok","exp":"x"}']) {
      test(raw.isEmpty ? '(空)' : raw, () {
        stored = raw;
        expect(store.load(), isNull);
        expect(stored, isNull);
      });
    }
  });

  test('encode / decode は往復する', () {
    final token = WebSessionToken('abc', DateTime.fromMillisecondsSinceEpoch(1760000000000));
    final back = WebSessionToken.decode(token.encode())!;
    expect(back.accessToken, 'abc');
    expect(back.expiresAt, token.expiresAt);
  });

  test('native（platform）は何も持たない', () {
    final platform = WebSessionTokenStore.platform();
    platform.save('tok', expiresIn: const Duration(hours: 1));
    expect(platform.load(), isNull);
  });
}
