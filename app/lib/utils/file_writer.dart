import 'file_writer_stub.dart' if (dart.library.io) 'file_writer_io.dart';

Future<void> saveFileBytes(String path, List<int> bytes) {
  return writeBytesToFile(path, bytes);
}
