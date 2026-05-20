import 'package:flutter/material.dart';

// ──────────────────────────────────────────────────────────────────────
// BlurEffect는 이 파일에서 중앙 정의합니다.
// blur_service.dart에 기존 enum이 있다면 제거하고 이 파일을 import 하세요.
// ──────────────────────────────────────────────────────────────────────
enum BlurEffect {
  gaussian,     // 가우시안 흐림
  mosaic,       // 모자이크 픽셀화
  blackBar,     // 검은 바로 완전 가리기  (NEW)
  frostedGlass, // 반투명 유리 효과        (NEW)
  // sticker → 완전 제거됨
}

// manual: 사용자가 직접 그린 블러 박스
enum DetectionType { face, licensePlate, document, card, shippingLabel, manual }

class DetectionResult {
  final DetectionType type;
  final Rect boundingBox;
  final double confidence;
  final List<String> privacyTexts;

  const DetectionResult({
    required this.type,
    required this.boundingBox,
    this.confidence = 1.0,
    this.privacyTexts = const [],
  });

  /// boundingBox만 교체한 복사본 생성 (리사이즈 오버라이드용)
  DetectionResult withRect(Rect rect) => DetectionResult(
    type: type,
    boundingBox: rect,
    confidence: confidence,
    privacyTexts: privacyTexts,
  );

  String get typeLabel {
    switch (type) {
      case DetectionType.face:          return '얼굴';
      case DetectionType.licensePlate:  return '번호판';
      case DetectionType.document:      return '문서';
      case DetectionType.card:          return '카드';
      case DetectionType.shippingLabel: return '운송장';
      case DetectionType.manual:        return '수동';
    }
  }

  Color get typeColor {
    switch (type) {
      case DetectionType.face:          return const Color(0xFFFF6B6B);
      case DetectionType.licensePlate:  return const Color(0xFF6C63FF);
      case DetectionType.document:      return const Color(0xFF43E97B);
      case DetectionType.card:          return Colors.orange;
      case DetectionType.shippingLabel: return Colors.purple;
      case DetectionType.manual:        return const Color(0xFF00BCD4); // 시안
    }
  }
}