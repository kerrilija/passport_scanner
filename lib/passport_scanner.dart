import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mrz_parser/mrz_parser.dart';
import 'ml_kit_utils.dart';


class PassportScannerWidget extends StatefulWidget {
  final Function(MRZResult) onScanned;

  const PassportScannerWidget({super.key, required this.onScanned});

  @override
  State<PassportScannerWidget> createState() => _PassportScannerWidgetState();
}

class _PassportScannerWidgetState extends State<PassportScannerWidget> {
  final _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  String txt = '';
  List data = [];
  Map<String, int> dataCounts = {};

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
              androidOptions: const AndroidAnalysisOptions.nv21(
                width: 1024,
              ),
              maxFramesPerSecond: 15,
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
            topActionsBuilder: (state) => Container(),
            theme: AwesomeTheme(
              bottomActionsBackgroundColor: Colors.transparent,
            ),
            previewDecoratorBuilder: (state, preview) {
              final _scanArea = Rect.fromCenter(
                center: preview.rect.center,
                width: preview.rect.width * 0.9,
                height: preview.rect.height * 0.5,
              );
              return Positioned.fill(
                child: CustomPaint(
                  painter: BarcodeFocusAreaPainter(
                    scanArea: _scanArea.size,
                  ),
                ),
              );
            },
            onImageForAnalysis: (img) => _processImageBarcode(img),
            saveConfig: SaveConfig.photo(),
          ),
        ),
      ],
    );
  }

  Future _processImageBarcode(AnalysisImage img) async {
    final inputImage = img.toInputImage();
    final RecognizedText recognizedText = await _textRecognizer.processImage(
      inputImage,
    );

    if (recognizedText.blocks.isNotEmpty) {
      final block = recognizedText.blocks.last;
      if (block.lines.length != 2) return;

      final scannedLine1 = block.lines[0].text
          .replaceAll(' ', '')
          .replaceAll('«', '<');

      final scannedLine2 = block.lines[1].text
          .replaceAll(' ', '')
          .replaceAll('«', '<');

      debugPrint(scannedLine1);
      debugPrint(scannedLine2);

      final mrz = [scannedLine1, scannedLine2];

      try {
        final result = MRZParser.parse(mrz);
        debugPrint("MRZ SCANNED SUCCESSFULLY");
        widget.onScanned(result);
      } on MRZException catch (e) {
        debugPrint(e.toString());
      }
    }
  }
}

class BarcodeFocusAreaPainter extends CustomPainter {
  final Size scanArea;

  BarcodeFocusAreaPainter({required this.scanArea});

  @override
  void paint(Canvas canvas, Size size) {
    final clippedRect = getClippedRect(size);
    // Draw a semi-transparent overlay outside of the scan area
    canvas.drawPath(clippedRect, Paint()..color = Colors.black38);
    canvas.drawLine(
      Offset(size.width / 2 - scanArea.width / 2, size.height / 1.55),
      Offset(size.width / 2 + scanArea.width / 2, size.height / 1.55),
      Paint()
        ..color = Colors.red
        ..strokeWidth = 2,
    );
    // Add border around the scan area
    canvas.drawPath(
      getInnerRect(size),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white70
        ..strokeWidth = 3,
    );

    // We apply the canvas transformation to the canvas so that the barcode
    // rect is drawn in the correct orientation. (Android only)
    // if (canvasTransformation != null) {
    //   canvas.save();
    //   canvas.applyTransformation(canvasTransformation!, size);
    // }
  }

  Path getInnerRect(Size size) {
    return Path()..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          (size.width - scanArea.width) / 2,
          (size.height - scanArea.height) - 200,
          scanArea.width,
          scanArea.height,
        ),
        const Radius.circular(16),
      ),
    );
  }

  Path getClippedRect(Size size) {
    final fullRect = Path()
      ..addRect(Rect.fromLTWH(0, 100, size.width, size.height));
    final innerRect = getInnerRect(size);
    // Substract innerRect from fullRect
    return Path.combine(PathOperation.difference, fullRect, innerRect);
  }

  @override
  bool shouldRepaint(covariant BarcodeFocusAreaPainter oldDelegate) {
    return scanArea != oldDelegate.scanArea;
  }
}
