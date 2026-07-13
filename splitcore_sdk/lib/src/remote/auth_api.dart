// Wraps PocketBase's built-in `users` auth collection. Converts every
// RecordModel to AppUser at the boundary — no PocketBase type crosses out
// of this layer.
import 'package:pocketbase/pocketbase.dart';

import '../models.dart';

class AuthApi {
  AuthApi(this._pb);

  final PocketBase _pb;

  AppUser? get currentUser {
    final record = _pb.authStore.record;
    if (record == null) return null;
    return AppUser(id: record.id, email: record.getStringValue('email'));
  }

  Future<AppUser> signUp({required String email, required String password}) async {
    await _pb.collection('users').create(
      body: {'email': email, 'password': password, 'passwordConfirm': password},
    );
    return signIn(email: email, password: password);
  }

  Future<AppUser> signIn({required String email, required String password}) async {
    final auth = await _pb.collection('users').authWithPassword(email, password);
    return AppUser(id: auth.record.id, email: auth.record.getStringValue('email'));
  }

  void signOut() => _pb.authStore.clear();
}
