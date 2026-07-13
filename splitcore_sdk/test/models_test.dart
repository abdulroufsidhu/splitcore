import 'dart:convert';

import 'package:splitcore_sdk/src/models.dart';
import 'package:test/test.dart';

void main() {
  group('SplitSpec', () {
    test('equal split JSON matches handler wire format', () {
      final spec = SplitSpec.equal(totalCents: 10000, memberIds: ['a', 'b', 'c']);

      final json = jsonDecode(jsonEncode(spec.toJson())) as Map<String, dynamic>;

      expect(json['type'], 'equal');
      expect(json['total_cents'], 10000);
      expect(json['entries'], [
        {'member_id': 'a'},
        {'member_id': 'b'},
        {'member_id': 'c'},
      ]);
    });

    test('exact split JSON carries amount_cents per entry', () {
      final spec = SplitSpec.exact(totalCents: 500, entries: [
        const ExactSplitEntry(memberId: 'a', amountCents: 300),
        const ExactSplitEntry(memberId: 'b', amountCents: 200),
      ]);

      final json = spec.toJson();

      expect(json['type'], 'exact');
      expect(json['entries'], [
        {'member_id': 'a', 'amount_cents': 300},
        {'member_id': 'b', 'amount_cents': 200},
      ]);
    });

    test('percent split JSON carries basis_points per entry', () {
      final spec = SplitSpec.percent(totalCents: 1000, entries: [
        const PercentSplitEntry(memberId: 'a', basisPoints: 5000),
        const PercentSplitEntry(memberId: 'b', basisPoints: 5000),
      ]);

      final json = spec.toJson();

      expect(json['type'], 'percent');
      expect(json['entries'], [
        {'member_id': 'a', 'basis_points': 5000},
        {'member_id': 'b', 'basis_points': 5000},
      ]);
    });

    test('shares split JSON carries shares per entry', () {
      final spec = SplitSpec.shares(totalCents: 900, entries: [
        const ShareSplitEntry(memberId: 'a', shares: 1),
        const ShareSplitEntry(memberId: 'b', shares: 2),
      ]);

      final json = spec.toJson();

      expect(json['type'], 'shares');
      expect(json['entries'], [
        {'member_id': 'a', 'shares': 1},
        {'member_id': 'b', 'shares': 2},
      ]);
    });
  });

  group('Split.fromJson', () {
    test('parses member_id and amount_cents', () {
      final split = Split.fromJson({'member_id': 'a', 'amount_cents': 3334});

      expect(split.memberId, 'a');
      expect(split.amountCents, 3334);
    });
  });

  group('Balance', () {
    test('round-trips to/from JSON with net_cents', () {
      const balance = Balance(memberId: 'a', netCents: -150);

      final json = balance.toJson();
      final parsed = Balance.fromJson(json);

      expect(json, {'member_id': 'a', 'net_cents': -150});
      expect(parsed.memberId, 'a');
      expect(parsed.netCents, -150);
    });
  });

  group('Transfer.fromJson', () {
    test('parses from_member_id, to_member_id, amount_cents', () {
      final transfer = Transfer.fromJson({
        'from_member_id': 'a',
        'to_member_id': 'b',
        'amount_cents': 250,
      });

      expect(transfer.fromMemberId, 'a');
      expect(transfer.toMemberId, 'b');
      expect(transfer.amountCents, 250);
    });
  });

  group('ExpenseInput/SettlementInput', () {
    test('expense JSON carries payer, amount, splits', () {
      const expense = ExpenseInput(
        payerId: 'a',
        amountCents: 1000,
        splits: [Split(memberId: 'a', amountCents: 500), Split(memberId: 'b', amountCents: 500)],
      );

      final json = expense.toJson();

      expect(json, {
        'payer_id': 'a',
        'amount_cents': 1000,
        'splits': [
          {'member_id': 'a', 'amount_cents': 500},
          {'member_id': 'b', 'amount_cents': 500},
        ],
      });
    });

    test('settlement JSON carries from/to/amount', () {
      const settlement = SettlementInput(fromMemberId: 'a', toMemberId: 'b', amountCents: 500);

      final json = settlement.toJson();

      expect(json, {'from_member_id': 'a', 'to_member_id': 'b', 'amount_cents': 500});
    });
  });
}
