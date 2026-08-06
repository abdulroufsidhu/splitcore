// Wraps PocketBase's built-in `users` auth collection. Converts every
// RecordModel to AppUser at the boundary — no PocketBase type crosses out
// of this layer.
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../models.dart';

class AuthApi {
  AuthApi(this._pb);

  final PocketBase _pb;

  /// The refresh currently in flight, if any. The app refreshes both at
  /// startup and on every resume, so two refreshes routinely overlap; each
  /// redundant authRefresh is another chance for one call's failure
  /// handler to clear the session while another is still succeeding.
  /// Collapsing them onto one future removes both the waste and the race.
  Future<AppUser?>? _inFlightRefresh;

  AppUser? get currentUser {
    final record = _pb.authStore.record;
    if (record == null) return null;
    return _userFromRecord(record);
  }

  Future<AppUser> signUp({required String email, required String password}) async {
    await _pb
        .collection('users')
        .create(body: {'email': email, 'password': password, 'passwordConfirm': password});
    return signIn(email: email, password: password);
  }

  Future<AppUser> signIn({required String email, required String password}) async {
    final auth = await _pb.collection('users').authWithPassword(email, password);
    return _userFromRecord(auth.record);
  }

  /// Updates the signed-in user's display name and/or avatar. Pass
  /// [avatarBytes] (with [avatarFilename]) to replace the photo; both name
  /// and avatar are optional so a caller can update just one.
  Future<AppUser> updateProfile({
    String? name,
    Uint8List? avatarBytes,
    String? avatarFilename,
  }) async {
    final id = _pb.authStore.record!.id;
    final record = await _pb
        .collection('users')
        .update(
          id,
          body: {if (name != null) 'name': name},
          files: [
            if (avatarBytes != null)
              http.MultipartFile.fromBytes(
                'avatar',
                avatarBytes,
                filename: avatarFilename ?? 'avatar.jpg',
              ),
          ],
        );
    await _pb.collection('users').authRefresh();
    return _userFromRecord(record);
  }

  void signOut() => _pb.authStore.clear();

  /// Closes the signed-in user's account and clears the local session.
  ///
  /// Returns what the server actually did:
  ///
  ///  * `'deleted'` — the account had no ledger history and was erased.
  ///  * `'anonymized'` — the user appears in expenses or settlements, so
  ///    their group membership rows must stay for everyone else's balances
  ///    to remain correct. The identity on the account is stripped instead
  ///    (see server/hooks/account.go). The UI must say so rather than
  ///    claiming everything was deleted.
  ///
  /// Throws when the server refuses — notably while any of the user's
  /// groups still shows a non-zero balance for them, which the user has to
  /// settle first.
  Future<String> deleteAccount() async {
    if (_pb.authStore.record == null) return 'deleted';
    final response = await _pb.send('/api/splitcore/delete-account', method: 'POST');
    _pb.authStore.clear();
    return (response as Map<String, dynamic>)['status'] as String? ?? 'deleted';
  }

  /// Whether the signed-in user has confirmed their email address. False
  /// when nobody is signed in.
  bool get isEmailVerified => _pb.authStore.record?.getBoolValue('verified') ?? false;

  /// Asks the server to mail a password-reset token to [email].
  ///
  /// Always resolves, even for an address with no account: a caller that
  /// could tell the two apart would have an account-enumeration oracle.
  /// The UI must therefore say "if that address has an account, check your
  /// inbox" rather than confirming the address exists.
  Future<void> requestPasswordReset(String email) async {
    try {
      await _pb.collection('users').requestPasswordReset(email);
    } catch (_) {
      // Deliberately swallowed — see above.
    }
  }

  /// Completes a reset with the token from the emailed link. Throws when
  /// the token is wrong, expired, or already used; the caller must surface
  /// that, since the user needs to know their new password did not take.
  Future<void> confirmPasswordReset({required String token, required String password}) =>
      _pb.collection('users').confirmPasswordReset(token, password, password);

  /// Asks the server to mail a verification token to [email]. Silent about
  /// unknown addresses for the same reason as [requestPasswordReset].
  Future<void> requestEmailVerification(String email) async {
    try {
      await _pb.collection('users').requestVerification(email);
    } catch (_) {
      // Deliberately swallowed — see requestPasswordReset.
    }
  }

  /// Completes verification with the token from the emailed link. Throws on
  /// a bad or expired token.
  Future<void> confirmEmailVerification(String token) =>
      _pb.collection('users').confirmVerification(token);

  /// Refreshes the current session's token (call on app resume/start so a
  /// long-backgrounded token doesn't sit expired). Returns the refreshed
  /// user, or null if there's no session to refresh or the refresh failed
  /// (e.g. the token already expired) — callers should treat null as
  /// "signed out".
  /// Concurrent calls share one request: the second caller awaits the
  /// first's result rather than issuing its own.
  Future<AppUser?> tryRefresh() {
    if (_pb.authStore.record == null) return Future.value(null);
    return _inFlightRefresh ??= _refresh().whenComplete(() => _inFlightRefresh = null);
  }

  Future<AppUser?> _refresh() async {
    try {
      final auth = await _pb.collection('users').authRefresh();
      return _userFromRecord(auth.record);
    } on ClientException catch (e) {
      // Only an outright rejection means the session is dead. A network
      // failure is indistinguishable from an expired token at this call
      // site, and treating it as one signed the user out on every launch
      // without a connection — precisely when the cached session matters
      // most. Keep it; the next successful refresh settles the question.
      if (e.statusCode == 401 || e.statusCode == 403) {
        _pb.authStore.clear();
      }
      return null;
    }
  }

  /// Whether a session is stored. Answerable offline, without a request —
  /// the stored token is the best available evidence of who is signed in.
  bool get isSignedIn => _pb.authStore.isValid;

  AppUser _userFromRecord(RecordModel record) => AppUser(
    id: record.id,
    email: record.getStringValue('email'),
    name: record.getStringValue('name'),
    avatarUrl: _pb.files.getUrl(record, record.getStringValue('avatar')).toString(),
  );
}
