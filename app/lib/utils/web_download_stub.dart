import 'dart:typed_data';

Future<void> downloadBytesInBrowser(Uint8List bytes, String filename) async {
  throw UnsupportedError('Browser download is only supported on web.');
}
