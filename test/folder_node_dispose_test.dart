// フォルダの削除（レイヤ一覧の長押し →「削除」）でノードを片付けるとき、
// 子が自分を親の children から外すので、children を回しながら消すと落ちていた
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/nodes/folder_node.dart';

void main() {
  test('子のあるフォルダを dispose しても落ちず、親からも外れる', () async {
    final root = FolderNode('Home', children: []);
    final folder = FolderNode('a', parent: root, children: []);
    root.children.add(folder);
    for (final name in ['x', 'y', 'z']) {
      folder.children.add(FolderNode(name, parent: folder, children: []));
    }

    await folder.dispose();

    expect(folder.children, isEmpty);
    expect(folder.parent, isNull);
    expect(root.children, isEmpty);
  });
}
