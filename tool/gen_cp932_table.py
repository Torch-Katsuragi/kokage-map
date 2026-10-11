"""CP932（Windows の Shift_JIS）の 2 バイト文字の表を Dart の文字列にして lib/services/table/cp932_table.dart を作る。

    python tool/gen_cp932_table.py

Python の cp932 コーデック（Windows と同じ。NEC 特殊文字・IBM 拡張文字を含む）から作る。
"""
import os

LEADS = list(range(0x81, 0xA0)) + list(range(0xE0, 0xFD))
TRAILS = range(0x40, 0xFD)


def esc(c):
    if c in "\\'$":
        return '\\' + c
    if ord(c) < 0x20 or ord(c) == 0xFFFD or ord(c) == 0x7F:
        return '\\u{%x}' % ord(c)
    return c


chars = []
for lead in LEADS:
    for trail in TRAILS:
        try:
            ch = bytes([lead, trail]).decode('cp932')
        except UnicodeDecodeError:
            ch = '�'
        assert len(ch) == 1
        chars.append(ch)
half = ''.join(bytes([b]).decode('cp932') for b in range(0xA1, 0xE0))

row = len(TRAILS)
lines = ["    '" + ''.join(esc(c) for c in chars[i:i + row]) + "'" for i in range(0, len(chars), row)]
out = os.path.join(os.path.dirname(__file__), '..', 'lib', 'services', 'table', 'cp932_table.dart')
with open(out, 'w', encoding='utf-8', newline='\n') as f:
    f.write('''// 生成物（tool/gen_cp932_table.py）。手で直さない
// CP932 の 2 バイト文字: 先頭 0x81-0x9F・0xE0-0xFC、2 バイト目 0x40-0xFC の順に 1 文字ずつ（無い番号は U+FFFD）
// ignore_for_file: lines_longer_than_80_chars

/// 半角カナ（0xA1-0xDF）
const cp932HalfKana = '%s';

/// 2 バイト文字
const cp932DoubleByte =
%s;
''' % (half, '\n'.join(lines)))
print('wrote', out, len(chars))
