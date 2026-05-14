import 'package:flutter/material.dart';

enum DetectionType { face, licensePlate, document, card, shippingLabel }

class DetectionResult {
  final DetectionType type;
  final Rect boundingBox;
  final double confidence;
  final List<String> privacyTexts; // 문서에서 발견된 개인정보

  DetectionResult({
    required this.type,
    required this.boundingBox,
    required this.confidence,
    this.privacyTexts = const [],
  });

  String get typeLabel {
    switch (type) {
      case DetectionType.face:
        return '얼굴';
      case DetectionType.licensePlate:
        return '번호판';
      case DetectionType.document:
        return '문서';
      case DetectionType.card:
        return '카드';
      case DetectionType.shippingLabel:
        return '운송장';
    }
  }

  Color get typeColor {
    switch (type) {
      case DetectionType.face:
        return Colors.red;
      case DetectionType.licensePlate:
        return Colors.blue;
      case DetectionType.document:
        return Colors.green;
      case DetectionType.card:
        return Colors.orange;
      case DetectionType.shippingLabel:
        return Colors.purple;
    }
  }
}