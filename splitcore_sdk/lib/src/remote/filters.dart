// Every PocketBase filter in this package is built here. Interpolating a
// value into a filter string lets a quote in that value terminate the
// literal and inject filter syntax — pb.filter() binds and escapes
// instead. There is no "the id is trusted" exception: the point of
// funnelling every filter through one place is that no future caller has
// to remember which values are trusted.
import 'package:pocketbase/pocketbase.dart';

/// Rows belonging to [groupId].
String byGroup(PocketBase pb, String groupId) => pb.filter('group = {:g}', {'g': groupId});

/// Split entries belonging to [expenseId].
String byExpense(PocketBase pb, String expenseId) => pb.filter('expense = {:e}', {'e': expenseId});
