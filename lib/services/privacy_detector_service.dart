import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../models/detection_result.dart';

class PrivacyDetectorService {
  final _textRecognizer = TextRecognizer(script: TextRecognitionScript.korean);




  static final Map<String, RegExp> _patterns = {
    // 주민등록번호
    '주민등록번호': RegExp(r'\d{6}-[1-4]\d{6}'),

    // 전화번호 (하이픈 있음)
    '전화번호': RegExp(r'01[0-9]-\d{3,4}-\d{4}'),

    // 전화번호 (하이픈 없음)
    '전화번호(붙임)': RegExp(r'01[0-9]\d{7,8}'),

    // 일반 전화번호
    '전화번호(일반)': RegExp(r'0\d{1,2}-\d{3,4}-\d{4}'),

    // 이메일
    '이메일': RegExp(r'[\w.-]+@[\w.-]+\.\w+'),

    // 계좌번호
    '계좌번호': RegExp(r'\d{3,4}-\d{2,6}-\d{2,6}'),

    // 카드번호
    '카드번호': RegExp(r'\d{4}-\d{4}-\d{4}-\d{4}'),

    // 카드번호 (공백 구분)
    '카드번호(공백)': RegExp(r'\d{4}\s\d{4}\s\d{4}\s\d{4}'),

    // 카드 유효기간
    '유효기간': RegExp(r'\d{2}/\d{2}'),

    // 여권번호
    '여권번호': RegExp(r'[A-Z]{1,2}[0-9]{6,8}[A-Z0-9]{0,2}'),

    // 운전면허번호
    '운전면허': RegExp(r'\d{2}-\d{2}-\d{6}-\d{2}'),

    // 주소 (광역시/도 포함)
    '주소': RegExp(
        r'(서울|서울특별시|부산|부산광역시|대구|대구광역시|인천|인천광역시|광주|광주광역시|대전|대전광역시|울산|울산광역시|세종|경기|강원|충북|충남|전북|전남|경북|경남|제주).{1,30}(로|길|동|구|시|군)\s*\d+'),

    // 이름 (국문 + 님/씨/귀하)
    '이름': RegExp(r'[가-힣]{2,4}\s*(님|씨|귀하)'),

    // 이름 (콜론 뒤 한글 이름)
    '이름(수신)': RegExp(r'(수신|받는\s*분|구매자|고객|주문자|수령인)\s*[:：]\s*[가-힣]{2,4}'),

    // 생년월일 (숫자)
    '생년월일': RegExp(r'\d{4}[.\-/년]\s*\d{1,2}[.\-/월]\s*\d{1,2}'),

    // 생년월일 (여권)
    '생년월일(여권)': RegExp(
        r'\d{1,2}\s*(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\s*[I1l]?\d{3,4}',
        caseSensitive: false),

    // 운송장 번호
    '운송장번호': RegExp(r'\d{10,15}'),

    // 주문번호
    '주문번호': RegExp(r'(주문\s*번호|주문번호)\s*[:：]\s*[\d\-]+'),

    // 카드 소유자 이름 (2~20자 영문)
    '카드소유자': RegExp(r'\b[a-zA-Z]{2,20}\b'),

  };

  static const _mrzExcludeKeywords = [
    'REPUBLIC', 'KOREA', 'PASSPORT', 'MINISTRY',
    'FOREIGN', 'AFFAIRS', 'NATIONALITY', 'SURNAME',
    'DATE', 'ISSUE', 'EXPIRY', 'AUTHORITY',
  ];

  Future<List<DetectionResult>> detectFromRegion(
      File imageFile,
      Rect region,
      double imageWidth,
      double imageHeight,
      ) async {
    final inputImage = InputImage.fromFile(imageFile);
    final recognizedText = await _textRecognizer.processImage(inputImage);

    final privacyResults = <DetectionResult>[];
    String? mrzLine1;
    String? mrzLine2;
    Rect? mrzLine1Box;
    Rect? mrzLine2Box;

    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final text = line.text.trim();
        final lineBox = line.boundingBox;

        if (!region.overlaps(lineBox)) continue;

        debugPrint('OCR 텍스트: $text');

        // MRZ 라인 감지
        if (_isMrzLine(text)) {
          if (mrzLine1 == null) {
            mrzLine1 = text;
            mrzLine1Box = lineBox;
            debugPrint('MRZ Line1 감지: $text');
          } else if (mrzLine2 == null) {
            mrzLine2 = text;
            mrzLine2Box = lineBox;
            debugPrint('MRZ Line2 감지: $text');
          }
          continue;
        }

        // 일반 정규식 패턴 매칭
        for (final entry in _patterns.entries) {
          if (entry.value.hasMatch(text)) {
            debugPrint('개인정보 발견: ${entry.key} → $text');
            privacyResults.add(DetectionResult(
              type: DetectionType.document,
              boundingBox: Rect.fromLTRB(
                lineBox.left,
                lineBox.top,
                lineBox.right,
                lineBox.bottom,
              ),
              confidence: 0.99,
              privacyTexts: [entry.key],
            ));
            break;
          }
        }
      }
    }

    // MRZ 파싱
    if (mrzLine1 != null && mrzLine1Box != null) {
      final mrzResults = _parseMRZ(
        mrzLine1,
        mrzLine2,
        mrzLine1Box,
        mrzLine2Box,
      );
      privacyResults.addAll(mrzResults);
    }

    return _removeDuplicates(privacyResults);
  }

  bool _isMrzLine(String text) {
    final cleanText = text.replaceAll(' ', '');
    final hasAngles = '<'.allMatches(cleanText).length >= 3;
    final isAlphaNum = RegExp(r'^[A-Z0-9<«]{25,}$').hasMatch(cleanText);
    return hasAngles || isAlphaNum;
  }

  List<DetectionResult> _parseMRZ(
      String line1,
      String? line2,
      Rect line1Box,
      Rect? line2Box,
      ) {
    final results = <DetectionResult>[];
    final clean1 = line1.replaceAll(RegExp(r'[«\s]'), '<').toUpperCase();
    final clean2 = line2?.replaceAll(RegExp(r'[«\s]'), '<').toUpperCase();

    debugPrint('MRZ 파싱 Line1: $clean1');
    debugPrint('MRZ 파싱 Line2: $clean2');

    try {
      // Line1에서 이름 추출
      if (clean1.length >= 5) {
        final nameSection = clean1.substring(5).split('<')
            .where((s) => s.isNotEmpty && s.length >= 2)
            .where((s) => !_mrzExcludeKeywords.contains(s))
            .toList();

        if (nameSection.isNotEmpty) {
          final surname = nameSection[0];
          final givenNames = nameSection.length > 1
              ? nameSection.sublist(1).join(' ')
              : '';
          final fullName = givenNames.isNotEmpty
              ? '$surname $givenNames'
              : surname;

          debugPrint('MRZ 이름 추출: $fullName');
          results.add(DetectionResult(
            type: DetectionType.document,
            boundingBox: Rect.fromLTRB(
              line1Box.left,
              line1Box.top,
              line1Box.right,
              line1Box.top + line1Box.height / 2,
            ),
            confidence: 0.99,
            privacyTexts: ['이름(MRZ): $fullName'],
          ));
        }
      }

      // Line2에서 여권번호 + 생년월일 추출
      if (clean2 != null && clean2.length >= 28 && line2Box != null) {
        final boxWidth = line2Box.width;

        // 여권번호 (0~8자리)
        final passportNo = clean2.substring(0, 9).replaceAll('<', '');
        if (passportNo.isNotEmpty) {
          debugPrint('MRZ 여권번호 추출: $passportNo');
          results.add(DetectionResult(
            type: DetectionType.document,
            boundingBox: Rect.fromLTRB(
              line2Box.left,
              line2Box.top,
              line2Box.left + boxWidth * 0.3,
              line2Box.bottom,
            ),
            confidence: 0.99,
            privacyTexts: ['여권번호(MRZ): $passportNo'],
          ));
        }

        // 생년월일 (13~18자리)
        if (clean2.length >= 20) {
          final dobRaw = clean2.substring(13, 19);
          if (RegExp(r'^\d{6}$').hasMatch(dobRaw)) {
            final year = int.parse(dobRaw.substring(0, 2));
            final month = dobRaw.substring(2, 4);
            final day = dobRaw.substring(4, 6);
            final fullYear = year > 30 ? '19$year' : '20$year';
            final dob = '$fullYear.$month.$day';
            debugPrint('MRZ 생년월일 추출: $dob');
            results.add(DetectionResult(
              type: DetectionType.document,
              boundingBox: Rect.fromLTRB(
                line2Box.left + boxWidth * 0.35,
                line2Box.top,
                line2Box.left + boxWidth * 0.65,
                line2Box.bottom,
              ),
              confidence: 0.99,
              privacyTexts: ['생년월일(MRZ): $dob'],
            ));
          }
        }
      }
    } catch (e) {
      debugPrint('MRZ 파싱 오류: $e');
    }

    return results;
  }

  List<DetectionResult> _removeDuplicates(List<DetectionResult> results) {
    final selected = <DetectionResult>[];
    for (final result in results) {
      bool isDuplicate = false;
      for (final existing in selected) {
        if (_iouRect(result.boundingBox, existing.boundingBox) > 0.3) {
          isDuplicate = true;
          break;
        }
      }
      if (!isDuplicate) selected.add(result);
    }
    return selected;
  }

  double _iouRect(Rect a, Rect b) {
    final intersectLeft = a.left > b.left ? a.left : b.left;
    final intersectTop = a.top > b.top ? a.top : b.top;
    final intersectRight = a.right < b.right ? a.right : b.right;
    final intersectBottom = a.bottom < b.bottom ? a.bottom : b.bottom;

    if (intersectRight < intersectLeft || intersectBottom < intersectTop) {
      return 0.0;
    }

    final intersectArea =
        (intersectRight - intersectLeft) * (intersectBottom - intersectTop);
    final aArea = a.width * a.height;
    final bArea = b.width * b.height;

    return intersectArea / (aArea + bArea - intersectArea);
  }

  Future<void> close() async {
    await _textRecognizer.close();
  }
}