import 'package:flutter_test/flutter_test.dart';

// CI 里 flutter create 不会覆盖已存在的文件，用这个占位测试
// 避免 flutter analyze 报默认 widget_test 引用不存在类的问题
void main() {
  test('placeholder', () {
    expect(1 + 1, 2);
  });
}
