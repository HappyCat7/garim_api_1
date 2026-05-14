import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../models/detection_result.dart';
import 'package:flutter/services.dart' show rootBundle;
enum BlurEffect { gaussian, mosaic, sticker }

class BlurService {
  img.Image? decodedSticker;

  Future<void> loadSticker() async {
    try {
      final data = await rootBundle.load('assets/sticker.png');
      final bytes = data.buffer.asUint8List();
      if (bytes.isNotEmpty) {
        decodedSticker = img.decodeImage(bytes);
        debugPrint('스티커 로드 성공');
      }
    } catch (e) {
      debugPrint('스티커 로드 실패: $e');
    }
  }

  Future<Uint8List> applyBlur(
      File imageFile,
      List<DetectionResult> detections,
      double imageWidth,
      double imageHeight, {
        BlurEffect effect = BlurEffect.mosaic,
        double blurIntensity = 20.0,
      }) async {
    final imageBytes = await imageFile.readAsBytes();
    img.Image originalImage = img.decodeImage(imageBytes)!;

    img.Image result = originalImage.clone();

    for (final detection in detections) {
      final box = detection.boundingBox;

      final left = box.left.clamp(0, originalImage.width - 1).toInt();
      final top = box.top.clamp(0, originalImage.height - 1).toInt();
      final right = box.right.clamp(0, originalImage.width.toDouble()).toInt();
      final bottom =
      box.bottom.clamp(0, originalImage.height.toDouble()).toInt();

      if (right <= left || bottom <= top) continue;

      debugPrint('블러 적용: left=$left, top=$top, right=$right, bottom=$bottom');

      final cropWidth = right - left;
      final cropHeight = bottom - top;

      final croppedArea = img.copyCrop(
        result,
        x: left,
        y: top,
        width: cropWidth,
        height: cropHeight,
      );

      if (effect == BlurEffect.sticker && decodedSticker != null) {
        // 스티커 효과
        final stickerRatio = decodedSticker!.width / decodedSticker!.height;
        final targetRatio = cropWidth / cropHeight;

        int finalW, finalH;
        if (targetRatio > stickerRatio) {
          finalH = cropHeight;
          finalW = (cropHeight * stickerRatio).toInt();
        } else {
          finalW = cropWidth;
          finalH = (cropWidth / stickerRatio).toInt();
        }

        final resizedSticker = img.copyResize(
          decodedSticker!,
          width: finalW,
          height: finalH,
        );

        final dstX = left + (cropWidth - finalW) ~/ 2;
        final dstY = top + (cropHeight - finalH) ~/ 2;

        img.compositeImage(result, resizedSticker, dstX: dstX, dstY: dstY);
        continue;
      }

      img.Image effectArea;

      if (effect == BlurEffect.gaussian) {
        effectArea = img.gaussianBlur(
          croppedArea,
          radius: blurIntensity.toInt(),
        );
      } else {
        effectArea = img.pixelate(
          croppedArea,
          size: blurIntensity.toInt(),
          mode: img.PixelateMode.upperLeft,
        );
      }

      // 타원형으로 블러 적용
      final centerX = cropWidth / 2;
      final centerY = cropHeight / 2;
      final radiusX = cropWidth / 2;
      final radiusY = cropHeight / 2;

      for (final p in effectArea) {
        final dx = p.x - centerX;
        final dy = p.y - centerY;
        final insideOval = (dx * dx) / (radiusX * radiusX) +
            (dy * dy) / (radiusY * radiusY) <=
            1.0;

        if (insideOval) {
          result.setPixel(left + p.x, top + p.y, p);
        }
      }
    }

    return Uint8List.fromList(img.encodeJpg(result, quality: 90));
  }
}