// "3 minutes ago" for the offline banner. Deliberately coarse: the banner
// says how stale the data is, not when precisely it was fetched.
String formatRelative(DateTime then, {DateTime? now}) {
  final delta = (now ?? DateTime.now()).difference(then);
  if (delta.inSeconds < 60) return 'just now';
  if (delta.inMinutes < 60) {
    return '${delta.inMinutes} minute${delta.inMinutes == 1 ? '' : 's'} ago';
  }
  if (delta.inHours < 24) {
    return '${delta.inHours} hour${delta.inHours == 1 ? '' : 's'} ago';
  }
  return '${delta.inDays} day${delta.inDays == 1 ? '' : 's'} ago';
}
