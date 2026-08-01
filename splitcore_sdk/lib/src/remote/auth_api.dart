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

  AppUser? get currentUser {
    final record = _pb.authStore.record;
    if (record == null) return null;
    return _userFromRecord(record);
  }

  Future<AppUser> signUp({required String email, required String password}) async {
    await _pb.collection('users').create(
      body: {'email': email, 'password': password, 'passwordConfirm': password},
    );
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
    final record = await _pb.collection('users').update(
          id,
          body: {if (name != null) 'name': name},
          files: [
            if (avatarBytes != null)
              http.MultipartFile.fromBytes('avatar', avatarBytes, filename: avatarFilename ?? 'avatar.jpg'),
          ],
        );
    await _pb.collection('users').authRefresh();
    return _userFromRecord(record);
  }

  void signOut() => _pb.authStore.clear();

  /// Refreshes the current session's token (call on app resume/start so a
  /// long-backgrounded token doesn't sit expired). Returns the refreshed
  /// user, or null if there's no session to refresh or the refresh failed
  /// (e.g. the token already expired) — callers should treat null as
  /// "signed out".
  Future<AppUser?> tryRefresh() async {
    if (_pb.authStore.record == null) return null;
    try {
      final auth = await _pb.collection('users').authRefresh();
      return _userFromRecord(auth.record);
    } catch (_) {
      _pb.authStore.clear();
      return null;
    }
  }

  AppUser _userFromRecord(RecordModel record) => AppUser(
        id: record.id,
        email: record.getStringValue('email'),
        name: record.getStringValue('name'),
        avatarUrl: _pb.files.getUrl(record, record.getStringValue('avatar')).toString(),
      );
}
