// Not in the design doc (SlicePay Screens.dc.html has no auth screen) but
// the SDK requires a signed-in user for everything else — the minimum
// gate to reach 1a. Styled to match the ledger paper/ink system.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../theme.dart';
import '../widgets/avatar.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.sdk, required this.onSignedIn, this.resetOverride});

  /// Null only in widget tests, which supply [resetOverride] instead.
  final SplitcoreSdk? sdk;
  final ValueChanged<AppUser> onSignedIn;

  /// Test seam for the password-reset request.
  @visibleForTesting
  final Future<void> Function(String email)? resetOverride;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _isSignUp = false;
  bool _loading = false;
  String? _error;
  XFile? _pickedPhoto;
  Uint8List? _pickedPhotoBytes;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _pickedPhoto = picked;
      _pickedPhotoBytes = bytes;
    });
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (_isSignUp && name.isEmpty) {
      setState(() => _error = 'Enter your name so people can recognise you.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final AppUser user;
      if (_isSignUp) {
        var created = await widget.sdk!.auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          name: name,
        );
        // Only after signUp: the avatar is a multipart update, and it needs
        // the session signUp just established. A failure here must not undo
        // an account that already exists — the photo is editable later from
        // the account sheet, so it is reported and skipped rather than
        // rolled back.
        if (_pickedPhotoBytes != null) {
          try {
            created = await widget.sdk!.auth.updateProfile(
              avatarBytes: _pickedPhotoBytes,
              avatarFilename: _pickedPhoto?.name,
            );
          } catch (_) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Account created — couldn't upload the photo.")),
              );
            }
          }
        }
        user = created;
      } else {
        user = await widget.sdk!.auth.signIn(email: _email.text.trim(), password: _password.text);
      }
      widget.onSignedIn(user);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email address first.');
      return;
    }
    final request = widget.resetOverride ?? widget.sdk!.auth.requestPasswordReset;
    await request(email);
    if (!mounted) return;
    setState(() => _error = null);
    // Deliberately non-committal: confirming that an address is registered
    // would make this button an account-enumeration oracle. The SDK is
    // silent about unknown addresses for the same reason.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('If that address has an account, a reset link is on its way.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('SlicePay', style: pageTitleStyle(slice.ink, size: 32)),
                const SizedBox(height: 28),
                if (_isSignUp) ...[
                  Center(
                    child: Semantics(
                      button: true,
                      label: 'Add a photo',
                      child: GestureDetector(
                        onTap: _loading ? null : _pickPhoto,
                        child: _pickedPhotoBytes != null
                            ? CircleAvatar(
                                radius: 40,
                                backgroundImage: MemoryImage(_pickedPhotoBytes!),
                              )
                            : Avatar(
                                _name.text.trim().isEmpty
                                    ? '+'
                                    : _name.text.trim()[0].toUpperCase(),
                                size: 80,
                                background: slice.ink,
                                foreground: slice.paper,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Add a photo (optional)',
                      style: TextStyle(color: slice.muted, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    // The avatar above falls back to the name's initial, so
                    // it has to repaint as the name is typed.
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: slice.negative)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: slice.paper),
                        )
                      : Text(_isSignUp ? 'Create account' : 'Sign in'),
                ),
                if (!_isSignUp)
                  TextButton(
                    onPressed: _loading ? null : _forgotPassword,
                    child: const Text('Forgot password?'),
                  ),
                TextButton(
                  onPressed: () => setState(() => _isSignUp = !_isSignUp),
                  child: Text(_isSignUp ? 'Have an account? Sign in' : 'New here? Create account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
