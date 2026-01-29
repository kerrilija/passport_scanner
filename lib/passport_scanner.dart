import 'dart:io';

import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mrz_parser/mrz_parser.dart';
import 'package:path_provider/path_provider.dart';
import 'ml_kit_utils.dart';
import 'package:image/image.dart' as imglib;

class PassportScannerWidget extends StatefulWidget {
  final Function(MRZResult result, String? imagePath) onScanned;
  final Function(List<String> scannedLines)? onParsingFailed;
  final Function()? onNoMrzFound;
  final Function(String rawText)? onRawText;
  final int precision;
  final bool showFlashButton;

  const PassportScannerWidget({
    super.key,
    required this.onScanned,
    this.onParsingFailed,
    this.onNoMrzFound,
    this.onRawText,
    this.precision = 3,
    this.showFlashButton = false,
  });

  @override
  State<PassportScannerWidget> createState() => _PassportScannerWidgetState();
}

const double kMrzZoneRatio = 0.45;

class _PassportScannerWidgetState extends State<PassportScannerWidget> {
  final _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  String txt = '';
  List data = [];
  Map<String, int> dataCounts = {};
  bool _isProcessingFrame = false;
  bool _hasScannedSuccessfully = false;
  Map<MRZResult, int> results = {};
  String? savedImagePath;

  @override
  void dispose() {
    _textRecognizer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Align(
          alignment: Alignment.center,
          child: CameraAwesomeBuilder.awesome(
            imageAnalysisConfig: AnalysisConfig(
              androidOptions: const AndroidAnalysisOptions.nv21(width: 640),
              maxFramesPerSecond: 3,
              autoStart: true,
            ),
            sensorConfig: SensorConfig.single(
              sensor: Sensor.position(SensorPosition.back),
              flashMode: FlashMode.none,
              aspectRatio: CameraAspectRatios.ratio_4_3,
            ),
            previewFit: CameraPreviewFit.fitWidth,
            middleContentBuilder: (state) => Container(),
            bottomActionsBuilder: (state) => Container(),
            topActionsBuilder: (state) => widget.showFlashButton ? Row(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: IconButton(
                    icon: Icon(
                      Icons.flashlight_on_rounded,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      if (state.sensorConfig.flashMode == FlashMode.always) {
                        state.sensorConfig.setFlashMode(FlashMode.none);
                      } else {
                        state.sensorConfig.setFlashMode(FlashMode.always);
                      }
                    },
                  ),
                ),
              ],
            ) : Container(),
            theme: AwesomeTheme(
              bottomActionsBackgroundColor: Colors.transparent,
            ),
            previewDecoratorBuilder: (state, preview) {
              final cardWidth = preview.rect.width * 0.9;
              final cardHeight = cardWidth / 1.586;
              final scanArea = Size(cardWidth, cardHeight);
              return CustomPaint(
                size: Size.infinite,
                painter: BarcodeFocusAreaPainter(
                  scanArea: scanArea,
                  mrzZoneRatio: kMrzZoneRatio,
                ),
              );
            },
            onImageForAnalysis: (img) => _processImageMrz(img),
            saveConfig: SaveConfig.photo(),
          ),
        ),
      ],
    );
  }

  Future _processImageMrz(AnalysisImage img) async {
    if (_hasScannedSuccessfully) return;
    if (_isProcessingFrame) return;

    _isProcessingFrame = true;
    try {
      final inputImage = img.toInputImage();
      final RecognizedText recognizedText = await _textRecognizer.processImage(
        inputImage,
      );

      if (recognizedText.blocks.isEmpty) {
        widget.onNoMrzFound?.call();
        return;
      }

      final imageHeight = img.height.toDouble();
      final mrzZoneTop = imageHeight * kMrzZoneRatio;

      final bottomBlocks = recognizedText.blocks.where((block) {
        final blockTop = block.boundingBox.top;
        return blockTop >= mrzZoneTop;
      }).toList();

      if (bottomBlocks.isEmpty) return;

      final allText = bottomBlocks.map((b) => b.text).join('\n');
      widget.onRawText?.call(allText);

      String cleanLine(String line) {
        var cleaned = line
            .replaceAll(' ', '')
            .replaceAll('«', '<')
            .replaceAll('‹', '<')
            .replaceAll('›', '<')
            .replaceAll('〈', '<')
            .replaceAll('〉', '<')
            .replaceAll('K<', '<<')
            .replaceAll('<K', '<<')
            .toUpperCase();
        cleaned = cleaned.replaceAll(RegExp(r'[^A-Z0-9<]'), '');
        return cleaned;
      }

      bool isMrzLine(String line) {
        final cleaned = cleanLine(line);
        if (cleaned.length < 28 || cleaned.length > 46) return false;
        if (!cleaned.contains('<')) return false;
        final validChars = RegExp(r'^[A-Z0-9<]+$');
        return validChars.hasMatch(cleaned);
      }

      final List<String> mrzLines = [];
      for (final block in bottomBlocks) {
        for (final line in block.lines) {
          if (isMrzLine(line.text)) {
            mrzLines.add(cleanLine(line.text));
          }
        }
      }

      if (mrzLines.length < 2 || mrzLines.length > 3) return;

      debugPrint('=== MRZ (bottom zone) ===');
      for (final line in mrzLines) {
        debugPrint('  $line (${line.length} chars)');
      }

      final mrz = mrzLines;

      try {
        final result = MRZParser.parse(mrz);
        if (results.keys.contains(result)) {
          if (results[result]! < widget.precision) {
            results[result] = results[result]! + 1;
            debugPrint(
              "MRZ SCANNED SUCCESSFULLY, BUT NEED MORE PRECISION: ${results[result]} / $widget.precision",
            );
          } else {
            debugPrint("MRZ SCANNED SUCCESSFULLY");
            _hasScannedSuccessfully = true;

            savedImagePath = await saveImageAndGetPath(img);
            widget.onScanned(result, savedImagePath);
          }
        } else {
          results[result] = 1;
        }
      } on MRZException catch (e) {
        debugPrint(e.toString());
        widget.onParsingFailed?.call(mrz);
      }
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<String?> saveImageAndGetPath(AnalysisImage img) async {
    try {
      final directory = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${directory.path}/passport_scan_$timestamp.jpg';

      // TODO: The following code is generated by AI, it must be tested and verified.
      imglib.Image? decodedImage = img.when(
        nv21: (image) {
          final int width = image.width;
          final int height = image.height;
          final bytes = image.bytes; // NV21: Y plane (W*H) then interleaved VU
          final int frameSize = width * height;
          final rgbImage = imglib.Image(width: width, height: height);
          for (int y = 0; y < height; y++) {
            final int yRow = y * width;
            final int uvRow = frameSize + (y >> 1) * width;
            for (int x = 0; x < width; x++) {
              final int yIndex = yRow + x;
              final int uvIndex = uvRow + (x & ~1);
              int Y = bytes[yIndex] & 0xff;
              int V = bytes[uvIndex] & 0xff;
              int U = bytes[uvIndex + 1] & 0xff;
              int C = Y - 16;
              if (C < 0) C = 0;
              int D = U - 128;
              int E = V - 128;
              int R = (298 * C + 409 * E + 128) >> 8;
              int G = (298 * C - 100 * D - 208 * E + 128) >> 8;
              int B = (298 * C + 516 * D + 128) >> 8;
              if (R < 0)
                R = 0;
              else if (R > 255)
                R = 255;
              if (G < 0)
                G = 0;
              else if (G > 255)
                G = 255;
              if (B < 0)
                B = 0;
              else if (B > 255)
                B = 255;
              rgbImage.setPixelRgb(x, y, R, G, B);
            }
          }
          return rgbImage;
        },
        bgra8888: (image) {
          final int width = image.width;
          final int height = image.height;
          final bytes = image.bytes;
          final rgbImage = imglib.Image(width: width, height: height);
          for (int y = 0; y < height; y++) {
            int base = y * width * 4;
            for (int x = 0; x < width; x++) {
              final int i = base + x * 4;
              final int b = bytes[i] & 0xff;
              final int g = bytes[i + 1] & 0xff;
              final int r = bytes[i + 2] & 0xff;
              rgbImage.setPixelRgb(x, y, r, g, b);
            }
          }
          return rgbImage;
        },
      );

      if (decodedImage == null) {
        debugPrint('Failed to decode image');
        return null;
      }

      decodedImage = imglib.copyRotate(decodedImage, angle: 90);

      final jpegBytes = imglib.encodeJpg(decodedImage, quality: 92);
      final file = File(filePath);
      await file.writeAsBytes(jpegBytes);
      return filePath;
    } catch (e) {
      debugPrint('Error saving image: $e');
      return null;
    }
  }
}

class BarcodeFocusAreaPainter extends CustomPainter {
  final Size scanArea;
  final double mrzZoneRatio;

  BarcodeFocusAreaPainter({
    required this.scanArea,
    this.mrzZoneRatio = kMrzZoneRatio,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final clippedRect = getClippedRect(size);
    canvas.drawPath(clippedRect, Paint()..color = Colors.black38);

    final cardRect = getCardRect(size);

    canvas.drawRRect(
      RRect.fromRectAndRadius(cardRect, const Radius.circular(16)),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white70
        ..strokeWidth = 3,
    );

    final mrzHeight = cardRect.height * 0.35;
    final mrzZoneRect = Rect.fromLTWH(
      cardRect.left,
      cardRect.bottom - mrzHeight,
      cardRect.width,
      mrzHeight,
    );
    canvas.drawRect(
      mrzZoneRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.red.withOpacity(0.8)
        ..strokeWidth = 2,
    );

    final labelPaint = Paint()
      ..color = Colors.red.withOpacity(0.6);
    canvas.drawRect(
      Rect.fromLTWH(mrzZoneRect.left + 5, mrzZoneRect.top + 5, 80, 20),
      labelPaint,
    );
    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'MRZ ZONE',
        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(mrzZoneRect.left + 10, mrzZoneRect.top + 8));

    // We apply the canvas transformation to the canvas so that the barcode
    // rect is drawn in the correct orientation. (Android only)
    // if (canvasTransformation != null) {
    //   canvas.save();
    //   canvas.applyTransformation(canvasTransformation!, size);
    // }
  }

  Rect getCardRect(Size size) {
    return Rect.fromLTWH(
      (size.width - scanArea.width) / 2,
      (size.height - scanArea.height) / 2.5,
      scanArea.width,
      scanArea.height,
    );
  }

  Path getClippedRect(Size size) {
    final fullRect = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final cardRect = getCardRect(size);
    final innerRect = Path()..addRRect(
      RRect.fromRectAndRadius(cardRect, const Radius.circular(16)),
    );
    return Path.combine(PathOperation.difference, fullRect, innerRect);
  }

  @override
  bool shouldRepaint(covariant BarcodeFocusAreaPainter oldDelegate) {
    return scanArea != oldDelegate.scanArea;
  }
}
