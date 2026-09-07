"""Play Console を Android Publisher API から操作する。

    python tool/play/play.py status
    python tool/play/play.py upload build/app/outputs/bundle/release/app-release.aab --track alpha \
        --notes-ja assets/changelog/ja.md --notes-en assets/changelog/en.md [--apply] [--hold]
    python tool/play/play.py listing [--lang ja-JP] [--title ...] [--short ...] [--full FILE] [--apply]
    python tool/play/play.py images phoneScreenshots --lang ja-JP --add a.png b.png [--replace] [--apply]
    python tool/play/play.py testers --track alpha [--group kokage-map-testers@googlegroups.com ...] [--apply]
      ⚠ 2026-09-07 実測: この app の alpha は「クローズドテスト（新方式）」なので 403
        （"upgraded to use open or closed testing; switch back to communities-based testing"）。
        Google グループの紐づけは Play Console の テスト → クローズドテスト → テスター で行う

規約:
  - 書き込み系は --apply を付けたときだけ commit する。付けなければ edit を作って
    最後まで通し、commit の直前で捨てる（dry-run）。公開中の情報には触れない。
  - commit は「審査に送信」と同義。--hold を付けると変更を保存だけして
    送信は Play Console の「公開の概要」から本人が押す形になる。

⚠ API で触れないもの（Play Console 専用）:
  アプリのコンテンツ（権限宣言・データセーフティ・プライバシーポリシーURL・対象ユーザー）、
  本番アクセス申請、テスターのオプトイン状況、メーリングリスト方式のテスター。

⚠ サービスアカウント play-console@nemurigi-kobo は Play Console 側で招待して
  権限を付ける必要がある（API 有効化だけでは 403）。commit に必要なのは
  「テスト版トラックとしてのアプリのリリース」。掲載情報だけなら「ストアでの表示の管理」。
"""

import argparse
import sys
from pathlib import Path

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload

KEY = Path.home() / '.gcp-keys' / 'nemurigi-play-console.json'
PACKAGE = 'com.k_root.k_maps'
SCOPES = ['https://www.googleapis.com/auth/androidpublisher']
IMAGE_TYPES = (
    'phoneScreenshots', 'sevenInchScreenshots', 'tenInchScreenshots',
    'icon', 'featureGraphic', 'tvBanner', 'tvScreenshots', 'wearScreenshots',
)


class Play:
    def __init__(self):
        creds = service_account.Credentials.from_service_account_file(str(KEY), scopes=SCOPES)
        self.api = build('androidpublisher', 'v3', credentials=creds, cache_discovery=False)
        self.edits = self.api.edits()
        self.edit_id = self.edits.insert(packageName=PACKAGE, body={}).execute()['id']

    def _kw(self, **extra):
        return dict(packageName=PACKAGE, editId=self.edit_id, **extra)

    def finish(self, apply, hold=False):
        if apply:
            self.edits.commit(**self._kw(changesNotSentForReview=hold)).execute()
            print('commit した。' + ('審査には送っていない（公開の概要から送信する）' if hold else '審査に送信された'))
        else:
            self.edits.delete(**self._kw()).execute()
            print('edit を捨てた（dry-run。--apply で実行）')

    # ---- テスター（Google グループ） ----
    def testers(self, track, groups, apply):
        """トラックのテスター一覧に Google グループを紐づける。
        メールアドレス一覧（Play Console で作るもの）は API に無いので触らない・消えない。
        --group を省けば現状表示だけ。"""
        cur = self.edits.testers().get(**self._kw(track=track)).execute()
        print('track %s googleGroups: %r' % (track, cur.get('googleGroups', [])))
        if groups is None:
            self.edits.delete(**self._kw()).execute()
            return
        self.edits.testers().update(**self._kw(track=track), body={'googleGroups': groups}).execute()
        print('track %s <- googleGroups %r' % (track, groups))
        self.finish(apply)

    # ---- 読む ----
    def status(self):
        tracks = self.edits.tracks().list(**self._kw()).execute().get('tracks', [])
        for t in tracks:
            for r in t.get('releases', []):
                print('track %-9s %-12s %-10s versionCodes=%s' % (
                    t['track'], r.get('name'), r.get('status'), r.get('versionCodes')))
        bundles = self.edits.bundles().list(**self._kw()).execute().get('bundles', [])
        print('bundles:', [b['versionCode'] for b in bundles])
        for l in self.edits.listings().list(**self._kw()).execute().get('listings', []):
            print('listing %-6s title=%r short=%r' % (l['language'], l.get('title'), l.get('shortDescription')))
            for it in ('phoneScreenshots', 'sevenInchScreenshots', 'tenInchScreenshots'):
                n = len(self.edits.images().list(**self._kw(language=l['language'], imageType=it))
                        .execute().get('images', []))
                print('        %-22s %d 枚' % (it, n))

    # ---- AAB ----
    def upload(self, aab, track, notes, apply, hold):
        media = MediaFileUpload(aab, mimetype='application/octet-stream', resumable=True,
                                chunksize=8 * 1024 * 1024)
        req = self.edits.bundles().upload(**self._kw(media_body=media))
        resp = None
        while resp is None:
            st, resp = req.next_chunk()
            if st:
                print('  upload %3d%%' % int(st.progress() * 100), end='\r')
        vc = resp['versionCode']
        print('\nbundle versionCode=%s sha256=%s' % (vc, resp.get('sha256', '')[:12]))

        cur = self.edits.tracks().get(**self._kw(track=track)).execute()
        prev = (cur.get('releases') or [{}])[0]
        release = {
            'name': notes.get('name') or str(vc),
            'versionCodes': [str(vc)],
            'status': 'completed',
        }
        if prev.get('countryTargeting'):
            release['countryTargeting'] = prev['countryTargeting']
        rn = [{'language': lang, 'text': text} for lang, text in notes.get('text', {}).items()]
        if rn:
            release['releaseNotes'] = rn
        self.edits.tracks().update(**self._kw(track=track, body={'track': track, 'releases': [release]})).execute()
        print('track %s <- release %r (%s)' % (track, release['name'], ', '.join(x['language'] for x in rn) or 'no notes'))
        self.finish(apply, hold)

    # ---- 掲載情報 ----
    def listing(self, lang, title, short, full, apply):
        cur = {l['language']: l for l in self.edits.listings().list(**self._kw()).execute().get('listings', [])}
        body = dict(cur.get(lang, {'language': lang}))
        print('%s: title=%r short=%r full=%d字' % (lang, body.get('title'), body.get('shortDescription'),
                                                    len(body.get('fullDescription', ''))))
        changed = False
        for key, val in (('title', title), ('shortDescription', short), ('fullDescription', full)):
            if val is not None and body.get(key) != val:
                body[key] = val
                changed = True
                print('  -> %s = %r' % (key, val if key != 'fullDescription' else '%d字' % len(val)))
        if not changed:
            print('変更なし')
            self.edits.delete(**self._kw()).execute()
            return
        self.edits.listings().update(**self._kw(language=lang, body=body)).execute()
        self.finish(apply)

    # ---- 画像 ----
    def images(self, image_type, lang, add, replace, apply):
        cur = self.edits.images().list(**self._kw(language=lang, imageType=image_type)).execute().get('images', [])
        print('%s/%s: 現在 %d 枚' % (lang, image_type, len(cur)))
        if replace and cur:
            self.edits.images().deleteall(**self._kw(language=lang, imageType=image_type)).execute()
            print('  全削除')
        for f in add:
            mime = 'image/png' if f.lower().endswith('.png') else 'image/jpeg'
            r = self.edits.images().upload(**self._kw(language=lang, imageType=image_type,
                                                       media_body=MediaFileUpload(f, mimetype=mime))).execute()
            print('  + %s -> id=%s' % (f, r['image']['id']))
        self.finish(apply)


def read_notes(path):
    """changelog の先頭エントリを Play のリリースノート（500字上限）に切り出す。"""
    text = Path(path).read_text(encoding='utf-8')
    lines = text.splitlines()
    heads = [i for i, l in enumerate(lines) if l.startswith('## ')]
    if heads:
        start = heads[0] + 1
        end = heads[1] if len(heads) > 1 else len(lines)
        lines = lines[start:end]
    body = '\n'.join(l for l in lines).strip()
    return body[:500]


def main(argv):
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')  # Windows の cp932 コンソールで絵文字入りノートが落ちる
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('status')

    u = sub.add_parser('upload')
    u.add_argument('aab')
    u.add_argument('--track', default='internal', help='internal / alpha / beta / production')
    u.add_argument('--name', help='リリース名（既定は versionCode）')
    u.add_argument('--notes-ja', help='日本語リリースノートの changelog md（先頭エントリを使う）')
    u.add_argument('--notes-en')
    u.add_argument('--apply', action='store_true')
    u.add_argument('--hold', action='store_true', help='保存だけして審査に送らない')

    l = sub.add_parser('listing')
    l.add_argument('--lang', default='ja-JP')
    l.add_argument('--title')
    l.add_argument('--short')
    l.add_argument('--full', help='詳細な説明を入れたテキストファイル')
    l.add_argument('--apply', action='store_true')

    i = sub.add_parser('images')
    i.add_argument('type', choices=IMAGE_TYPES)
    i.add_argument('--lang', default='ja-JP')
    i.add_argument('--add', nargs='*', default=[])
    i.add_argument('--replace', action='store_true', help='既存を全部消してから追加')
    i.add_argument('--apply', action='store_true')

    tt = sub.add_parser('testers')
    tt.add_argument('--track', default='alpha')
    tt.add_argument('--group', nargs='*', help='紐づける Google グループのアドレス（省略で現状表示）')
    tt.add_argument('--apply', action='store_true')

    a = p.parse_args(argv)
    play = Play()
    try:
        if a.cmd == 'status':
            play.status()
            play.edits.delete(**play._kw()).execute()
        elif a.cmd == 'upload':
            notes = {'name': a.name, 'text': {}}
            if a.notes_ja:
                notes['text']['ja-JP'] = read_notes(a.notes_ja)
            if a.notes_en:
                notes['text']['en-US'] = read_notes(a.notes_en)
            play.upload(a.aab, a.track, notes, a.apply, a.hold)
        elif a.cmd == 'listing':
            full = Path(a.full).read_text(encoding='utf-8').strip() if a.full else None
            play.listing(a.lang, a.title, a.short, full, a.apply)
        elif a.cmd == 'images':
            play.images(a.type, a.lang, a.add, a.replace, a.apply)
        elif a.cmd == 'testers':
            play.testers(a.track, a.group, a.apply)
    except HttpError as e:
        print('API error %s: %s' % (e.status_code, e.reason), file=sys.stderr)
        try:
            play.edits.delete(**play._kw()).execute()
        except HttpError:
            pass
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
