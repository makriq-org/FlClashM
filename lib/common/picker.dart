import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/state.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class Picker {
  // A profile/config file is tiny; a much larger pick is a mistake. Reading one
  // (a user picked ~120 MB) OOM'd — file_picker's withData streamed the whole
  // file through the platform channel, which allocated a >100 MB direct
  // ByteBuffer. So don't stream bytes over the channel: take the path and read
  // it in Dart, bounded by this cap.
  static const _maxImportBytes = 20 * 1024 * 1024;

  Future<PlatformFile?> pickerFile() async {
    final filePickerResult = await FilePicker.platform.pickFiles(
      withData: false,
      allowMultiple: false,
      initialDirectory: await appPath.downloadDirPath,
    );
    final file = filePickerResult?.files.first;
    if (file == null) return null;
    if (file.size > _maxImportBytes) {
      globalState.showNotifier(appLocalizations.fileTooLarge);
      return null;
    }
    final path = file.path;
    // No path (e.g. web) — return whatever the picker provided as-is.
    if (path == null) return file;
    final bytes = await File(path).readAsBytes();
    return PlatformFile(
      name: file.name,
      size: file.size,
      path: path,
      bytes: bytes,
    );
  }

  Future<String?> saveFile(String fileName, Uint8List bytes) async {
    final path = await FilePicker.platform.saveFile(
      fileName: fileName,
      initialDirectory: await appPath.downloadDirPath,
      bytes: Platform.isAndroid ? bytes : null,
    );
    if (!Platform.isAndroid && path != null) {
      final file = await File(path).create(recursive: true);
      await file.writeAsBytes(bytes);
    }
    return path;
  }

  Future<String?> pickerConfigQRCode() async {
    final xFile = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (xFile == null) {
      return null;
    }
    final controller = MobileScannerController();
    final capture = await controller.analyzeImage(xFile.path, formats: [
      BarcodeFormat.qrCode,
    ]);
    final result = capture?.barcodes.first.rawValue;
    if (result == null || !result.isUrl) {
      throw appLocalizations.pleaseUploadValidQrcode;
    }
    return result;
  }
}

final picker = Picker();
