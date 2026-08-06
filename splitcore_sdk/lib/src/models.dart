// Dart mirrors of the JSON shapes accepted/returned by splitcore/ffi/handler.
// Field names on the wire (json:"..." tags in handler.go) are the source of
// truth; keep these in lockstep with that file.

/// A single split-request entry. Which fields are populated depends on
/// [SplitSpec.type] — the handler switches on that to decide what it reads.
sealed class SplitRequestEntry {
  const SplitRequestEntry();

  Map<String, dynamic> toJson();
}

class EqualSplitEntry extends SplitRequestEntry {
  const EqualSplitEntry({required this.memberId});

  final String memberId;

  @override
  Map<String, dynamic> toJson() => {'member_id': memberId};
}

class ExactSplitEntry extends SplitRequestEntry {
  const ExactSplitEntry({required this.memberId, required this.amountCents});

  final String memberId;
  final int amountCents;

  @override
  Map<String, dynamic> toJson() => {'member_id': memberId, 'amount_cents': amountCents};
}

class PercentSplitEntry extends SplitRequestEntry {
  const PercentSplitEntry({required this.memberId, required this.basisPoints});

  final String memberId;
  final int basisPoints;

  @override
  Map<String, dynamic> toJson() => {'member_id': memberId, 'basis_points': basisPoints};
}

class ShareSplitEntry extends SplitRequestEntry {
  const ShareSplitEntry({required this.memberId, required this.shares});

  final String memberId;
  final int shares;

  @override
  Map<String, dynamic> toJson() => {'member_id': memberId, 'shares': shares};
}

/// Request body for SplitcoreComputeSplits: {type, total_cents, entries[]}.
class SplitSpec {
  const SplitSpec._(this.type, this.totalCents, this.entries);

  factory SplitSpec.equal({required int totalCents, required List<String> memberIds}) =>
      SplitSpec._('equal', totalCents, [for (final id in memberIds) EqualSplitEntry(memberId: id)]);

  factory SplitSpec.exact({required int totalCents, required List<ExactSplitEntry> entries}) =>
      SplitSpec._('exact', totalCents, entries);

  factory SplitSpec.percent({required int totalCents, required List<PercentSplitEntry> entries}) =>
      SplitSpec._('percent', totalCents, entries);

  factory SplitSpec.shares({required int totalCents, required List<ShareSplitEntry> entries}) =>
      SplitSpec._('shares', totalCents, entries);

  final String type;
  final int totalCents;
  final List<SplitRequestEntry> entries;

  Map<String, dynamic> toJson() => {
    'type': type,
    'total_cents': totalCents,
    'entries': [for (final e in entries) e.toJson()],
  };
}

/// A resolved split-line, returned by ComputeSplits and consumed by
/// ComputeBalances ({splits: [...]}).
class Split {
  const Split({required this.memberId, required this.amountCents});

  factory Split.fromJson(Map<String, dynamic> json) =>
      Split(memberId: json['member_id'] as String, amountCents: json['amount_cents'] as int);

  final String memberId;
  final int amountCents;

  Map<String, dynamic> toJson() => {'member_id': memberId, 'amount_cents': amountCents};

  @override
  bool operator ==(Object other) =>
      other is Split && other.memberId == memberId && other.amountCents == amountCents;

  @override
  int get hashCode => Object.hash(memberId, amountCents);

  @override
  String toString() => 'Split(memberId: $memberId, amountCents: $amountCents)';
}

/// A member's net position (+ = owed money, − = owes), matching
/// balance.Balance / settle.Balance's {member_id, net_cents}.
class Balance {
  const Balance({required this.memberId, required this.netCents});

  factory Balance.fromJson(Map<String, dynamic> json) =>
      Balance(memberId: json['member_id'] as String, netCents: json['net_cents'] as int);

  final String memberId;
  final int netCents;

  Map<String, dynamic> toJson() => {'member_id': memberId, 'net_cents': netCents};

  @override
  bool operator ==(Object other) =>
      other is Balance && other.memberId == memberId && other.netCents == netCents;

  @override
  int get hashCode => Object.hash(memberId, netCents);

  @override
  String toString() => 'Balance(memberId: $memberId, netCents: $netCents)';
}

/// A suggested settlement transfer from SimplifyDebts.
class Transfer {
  const Transfer({required this.fromMemberId, required this.toMemberId, required this.amountCents});

  factory Transfer.fromJson(Map<String, dynamic> json) => Transfer(
    fromMemberId: json['from_member_id'] as String,
    toMemberId: json['to_member_id'] as String,
    amountCents: json['amount_cents'] as int,
  );

  final String fromMemberId;
  final String toMemberId;
  final int amountCents;

  Map<String, dynamic> toJson() => {
    'from_member_id': fromMemberId,
    'to_member_id': toMemberId,
    'amount_cents': amountCents,
  };

  @override
  bool operator ==(Object other) =>
      other is Transfer &&
      other.fromMemberId == fromMemberId &&
      other.toMemberId == toMemberId &&
      other.amountCents == amountCents;

  @override
  int get hashCode => Object.hash(fromMemberId, toMemberId, amountCents);

  @override
  String toString() =>
      'Transfer(fromMemberId: $fromMemberId, toMemberId: $toMemberId, amountCents: $amountCents)';
}

/// One expense, as fed into ComputeBalances's {expenses: [...]}.
class ExpenseInput {
  const ExpenseInput({required this.payerId, required this.amountCents, required this.splits});

  final String payerId;
  final int amountCents;
  final List<Split> splits;

  Map<String, dynamic> toJson() => {
    'payer_id': payerId,
    'amount_cents': amountCents,
    'splits': [for (final s in splits) s.toJson()],
  };
}

/// A signed-in (or signed-up) PocketBase `users` record, exposed instead of
/// the raw PocketBase RecordModel — the SDK never leaks PocketBase types
/// across its public boundary.
class AppUser {
  const AppUser({required this.id, required this.email, this.name = '', this.avatarUrl = ''});

  final String id;
  final String email;

  /// Empty until the user sets one via `AuthApi.updateProfile`.
  final String name;

  /// Absolute URL to the avatar image, or '' if unset.
  final String avatarUrl;

  @override
  bool operator ==(Object other) =>
      other is AppUser &&
      other.id == id &&
      other.email == email &&
      other.name == name &&
      other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(id, email, name, avatarUrl);

  @override
  String toString() => 'AppUser(id: $id, email: $email, name: $name, avatarUrl: $avatarUrl)';
}

/// A `groups` record. `version` is server/hook-managed, never client-set.
class Group {
  const Group({
    required this.id,
    required this.name,
    required this.currency,
    required this.version,
    required this.ownerId,
    this.isDirect = false,
  });

  final String id;
  final String name;
  final String currency;
  final int version;
  final String ownerId;

  /// True for a group created via the app's "Add person" one-to-one flow —
  /// a display hint only, not a different kind of group.
  final bool isDirect;

  @override
  bool operator ==(Object other) =>
      other is Group &&
      other.id == id &&
      other.name == name &&
      other.currency == currency &&
      other.version == version &&
      other.ownerId == ownerId &&
      other.isDirect == isDirect;

  @override
  int get hashCode => Object.hash(id, name, currency, version, ownerId, isDirect);

  @override
  String toString() =>
      'Group(id: $id, name: $name, currency: $currency, version: $version, ownerId: $ownerId, isDirect: $isDirect)';
}

/// A `group_members` record.
class GroupMember {
  const GroupMember({
    required this.id,
    required this.groupId,
    required this.userId,
    required this.role,
    this.name = '',
    this.avatarUrl = '',
  });

  final String id;
  final String groupId;
  final String userId;

  /// Either "owner" or "member" (matches the server's SelectField values).
  final String role;

  /// This member's display name, or '' if they haven't set one (or this
  /// came from an endpoint that doesn't resolve it, e.g. addMember).
  final String name;

  /// Absolute URL to this member's avatar image, or '' if unset/unresolved.
  final String avatarUrl;

  @override
  bool operator ==(Object other) =>
      other is GroupMember &&
      other.id == id &&
      other.groupId == groupId &&
      other.userId == userId &&
      other.role == role &&
      other.name == name &&
      other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(id, groupId, userId, role, name, avatarUrl);

  @override
  String toString() =>
      'GroupMember(id: $id, groupId: $groupId, userId: $userId, role: $role, name: $name, avatarUrl: $avatarUrl)';
}

/// A created `expenses` record.
class Expense {
  const Expense({
    required this.id,
    required this.groupId,
    required this.payerMemberId,
    required this.description,
    required this.amountCents,
    required this.splitType,
    required this.date,
    this.updated,
    this.pending = false,
  });

  final String id;
  final String groupId;
  final String payerMemberId;
  final String description;
  final int amountCents;
  final String splitType;
  final DateTime date;

  /// The server's own `updated` stamp, or null for a row created locally
  /// that the server has not seen yet. This is the base a queued edit is
  /// measured against: if the server's stamp has moved by the time the edit
  /// is replayed, somebody else changed the expense and the edit parks as a
  /// conflict rather than overwriting them.
  final DateTime? updated;

  /// True while a write to this expense is still queued in the outbox. The
  /// UI greys such a row: the numbers are real and local, but nobody else
  /// can see them yet.
  final bool pending;

  @override
  bool operator ==(Object other) =>
      other is Expense &&
      other.id == id &&
      other.groupId == groupId &&
      other.payerMemberId == payerMemberId &&
      other.description == description &&
      other.amountCents == amountCents &&
      other.splitType == splitType &&
      other.date == date &&
      other.updated == updated &&
      other.pending == pending;

  @override
  int get hashCode => Object.hash(
    id,
    groupId,
    payerMemberId,
    description,
    amountCents,
    splitType,
    date,
    updated,
    pending,
  );

  @override
  String toString() =>
      'Expense(id: $id, groupId: $groupId, payerMemberId: $payerMemberId, '
      'description: $description, amountCents: $amountCents, splitType: $splitType, date: $date)';
}

/// A created `split_entries` record.
class SplitEntry {
  const SplitEntry({
    required this.id,
    required this.expenseId,
    required this.memberId,
    required this.amountCents,
    this.receiptFilename,
  });

  final String id;
  final String expenseId;
  final String memberId;
  final int amountCents;

  /// Filename of the attached receipt in PocketBase's file storage, or
  /// null if no receipt is attached.
  final String? receiptFilename;

  @override
  bool operator ==(Object other) =>
      other is SplitEntry &&
      other.id == id &&
      other.expenseId == expenseId &&
      other.memberId == memberId &&
      other.amountCents == amountCents &&
      other.receiptFilename == receiptFilename;

  @override
  int get hashCode => Object.hash(id, expenseId, memberId, amountCents, receiptFilename);

  @override
  String toString() =>
      'SplitEntry(id: $id, expenseId: $expenseId, memberId: $memberId, '
      'amountCents: $amountCents, receiptFilename: $receiptFilename)';
}

/// Response of GET /api/splitcore/staleness.
class StalenessResult {
  const StalenessResult({required this.current, required this.serverVersion});

  final bool current;
  final int serverVersion;

  @override
  bool operator ==(Object other) =>
      other is StalenessResult && other.current == current && other.serverVersion == serverVersion;

  @override
  int get hashCode => Object.hash(current, serverVersion);

  @override
  String toString() => 'StalenessResult(current: $current, serverVersion: $serverVersion)';
}

/// A created `settlements` record.
class Settlement {
  const Settlement({
    required this.id,
    required this.groupId,
    required this.fromMemberId,
    required this.toMemberId,
    required this.amountCents,
    required this.date,
    this.note = '',
  });

  final String id;
  final String groupId;
  final String fromMemberId;
  final String toMemberId;
  final int amountCents;
  final DateTime date;
  final String note;

  @override
  bool operator ==(Object other) =>
      other is Settlement &&
      other.id == id &&
      other.groupId == groupId &&
      other.fromMemberId == fromMemberId &&
      other.toMemberId == toMemberId &&
      other.amountCents == amountCents &&
      other.date == date &&
      other.note == note;

  @override
  int get hashCode => Object.hash(id, groupId, fromMemberId, toMemberId, amountCents, date, note);

  @override
  String toString() =>
      'Settlement(id: $id, groupId: $groupId, fromMemberId: $fromMemberId, '
      'toMemberId: $toMemberId, amountCents: $amountCents, date: $date, note: $note)';
}

/// One settlement, as fed into ComputeBalances's {settlements: [...]}.
class SettlementInput {
  const SettlementInput({
    required this.fromMemberId,
    required this.toMemberId,
    required this.amountCents,
  });

  final String fromMemberId;
  final String toMemberId;
  final int amountCents;

  Map<String, dynamic> toJson() => {
    'from_member_id': fromMemberId,
    'to_member_id': toMemberId,
    'amount_cents': amountCents,
  };
}

/// One page of a listing, with enough metadata for a UI to decide whether
/// to fetch the next one. Returned instead of a bare List so a caller
/// physically cannot ask for "all rows" by accident.
class Page<T> {
  const Page({
    required this.items,
    required this.page,
    required this.perPage,
    required this.totalItems,
    required this.totalPages,
  });

  /// The empty case — a group with no expenses yet.
  const Page.empty({this.perPage = 50})
    : items = const [],
      page = 1,
      totalItems = 0,
      totalPages = 0;

  final List<T> items;
  final int page;
  final int perPage;
  final int totalItems;
  final int totalPages;

  bool get hasMore => page < totalPages;
}
