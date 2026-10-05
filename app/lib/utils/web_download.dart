import 'dart:typed_data';

import 'web_download_stub.dart'
    if (dart.library.html) 'web_download_web.dart';

Future<void> downloadPdfBytes(Uint8List bytes, String filename) {
  return downloadBytesInBrowser(bytes, filename);
}
