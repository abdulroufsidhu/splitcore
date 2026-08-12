import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/remote/filters.dart';
import 'package:test/test.dart';

/// True when every `'` inside the expression is backslash-escaped except
/// the two that delimit the literal — i.e. no value can terminate its own
/// literal and have the remainder parsed as filter syntax.
bool _quotesAreBalanced(String expression) {
  final body = expression.substring(expression.indexOf("'") + 1, expression.lastIndexOf("'"));
  for (var i = 0; i < body.length; i++) {
    if (body[i] == "'" && (i == 0 || body[i - 1] != r'\')) return false;
  }
  return true;
}

void main() {
  final pb = PocketBase('http://127.0.0.1:1');

  test('byGroup binds the id instead of interpolating it', () {
    expect(byGroup(pb, 'abc123'), "group = 'abc123'");
  });

  test('a quote in the id is escaped, so it cannot terminate the literal', () {
    // Interpolation would produce  group = 'x' || id != ''  — a filter
    // matching every row the caller may read. Binding escapes the quote,
    // so the `||` stays inert text inside a single string literal.
    final injected = byGroup(pb, r"x' || id != '");

    expect(injected, r"group = 'x\' || id != \''");
    expect(_quotesAreBalanced(injected), isTrue, reason: 'filter injection: $injected');
  });

  test('byExpense binds the same way', () {
    expect(byExpense(pb, 'exp1'), "expense = 'exp1'");
    expect(_quotesAreBalanced(byExpense(pb, r"x' || id != '")), isTrue);
  });

  test('a backslash in the value is itself escaped', () {
    // Otherwise a trailing backslash would escape the closing quote and
    // swallow the rest of the expression.
    expect(_quotesAreBalanced(byGroup(pb, r'ends with backslash \')), isTrue);
  });
}
