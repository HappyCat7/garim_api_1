

import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../services/face_detector_service.dart';
import '../services/plate_detector_service.dart';
import '../services/document_detector_service.dart';
import '../services/card_detector_service.dart';
import '../services/privacy_detector_service.dart';
import '../services/blur_service.dart';
import '../services/shipping_label_detector_service.dart';
import '../models/detection_result.dart';
import '../models/manual_blur_box.dart';
import '../widgets/detection_overlay.dart';
import 'document_text_screen.dart';

// ── 편집 모드 열거형 ────────────────────────────────────────────────────
enum EditorMode { view, edit }

// ════════════════════════════════════════════════════════════════════════
// ResultScreen
// ════════════════════════════════════════════════════════════════════════
class ResultScreen extends StatefulWidget {
  final File imageFile;
  const ResultScreen({super.key, required this.imageFile});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  // ── 서비스 ──────────────────────────────────────────────────────────
  final _faceService          = FaceDetectorService();
  final _plateService         = PlateDetectorService();
  final _documentService      = DocumentDetectorService();
  final _cardService          = CardDetectorService();
  final _shippingLabelService = ShippingLabelDetectorService();
  final _privacyService       = PrivacyDetectorService();
  final _blurService          = BlurService();

  // ── 탐지 결과 ────────────────────────────────────────────────────────
  List<DetectionResult> _detections            = [];
  List<DetectionResult> _documentDetections    = [];
  List<DetectionResult> _cardDetections        = [];
  List<DetectionResult> _privacyDetections     = [];
  List<DetectionResult> _cardPrivacyDetections = [];

  // ── 자동 탐지 rect 오버라이드 (리사이즈 반영용) ────────────────────────
  final Map<int, Rect> _detectionOverrides = {};

  // ── 수동 블러 박스 ───────────────────────────────────────────────────
  final List<ManualBlurBox> _manualBoxes = [];
  int _manualBoxCounter = 0;

  // ── 이미지 바이트 ────────────────────────────────────────────────────
  Uint8List? _blurredImage;
  Uint8List? _originalBytes;

  // ── UI 상태 ──────────────────────────────────────────────────────────
  bool   _isProcessing    = true;
  String _statusMessage   = '분석 중...';
  bool   _blurEnabled     = false;
  bool   _useTextBlur     = false;
  bool   _useCardTextBlur = false;

  // ── 블러 효과 (sticker 제거 / blackBar·frostedGlass 추가) ────────────
  BlurEffect _selectedEffect = BlurEffect.mosaic;
  double     _blurIntensity  = 20.0;

  // ── 유형별 블러 ON/OFF ────────────────────────────────────────────────
  final Map<DetectionType, bool> _typeBlurEnabled = {
    DetectionType.face:         true,
    DetectionType.licensePlate: true,
    DetectionType.document:     true,
    DetectionType.card:         true,
    DetectionType.manual:       true,
  };

  // ── 이미지 크기 ───────────────────────────────────────────────────────
  Size _imageSize = Size.zero;

  // ── 편집 모드 ─────────────────────────────────────────────────────────
  EditorMode _editorMode = EditorMode.view;

  // ── InteractiveViewer ────────────────────────────────────────────────
  final _transformationController = TransformationController();
  bool _isZoomed = false;

  // ════════════════════════════════════════════════════════════════════════
  // 수명주기
  // ════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(() {
      final scale  = _transformationController.value.getMaxScaleOnAxis();
      final zoomed = scale > 1.01;
      if (zoomed != _isZoomed) setState(() => _isZoomed = zoomed);
    });
    _analyze();
  }

  @override
  void dispose() {
    _transformationController.dispose();
    _faceService.close();
    _plateService.close();
    _cardService.close();
    _privacyService.close();
    _shippingLabelService.close();
    super.dispose();
  }

  // ════════════════════════════════════════════════════════════════════════
  // 분석
  // ════════════════════════════════════════════════════════════════════════

  bool _overlaps(Rect a, Rect b) =>
      a.left < b.right  && a.right  > b.left &&
          a.top  < b.bottom && a.bottom > b.top;

  Future<void> _analyze() async {
    try {
      _originalBytes = await widget.imageFile.readAsBytes();
      final decoded  = await decodeImageFromList(_originalBytes!);
      _imageSize     = Size(decoded.width.toDouble(), decoded.height.toDouble());

      setState(() => _statusMessage = '얼굴을 찾고 있어요...');
      final inputImage  = InputImage.fromFile(widget.imageFile);
      final faceResults = await _faceService.detect(inputImage);

      setState(() => _statusMessage = '번호판을 확인하고 있어요...');
      final plateResults = await _plateService.detect(widget.imageFile);

      setState(() => _statusMessage = '카드를 확인하고 있어요...');
      final cardResults = await _cardService.detect(widget.imageFile);

      setState(() => _statusMessage = '문서를 스캔하고 있어요...');
      final documentResults = await _documentService.detect(widget.imageFile);

      setState(() => _statusMessage = '운송장을 확인하고 있어요...');
      final shippingResults = await _shippingLabelService.detect(widget.imageFile);

      // 우선순위: 번호판 > 카드 > 문서
      final filteredCards = cardResults
          .where((c) => plateResults
          .every((p) => !_overlaps(c.boundingBox, p.boundingBox)))
          .toList();

      final filteredDocuments = documentResults
          .where((d) =>
      plateResults.every((p) => !_overlaps(d.boundingBox, p.boundingBox)) &&
          filteredCards.every((c) => !_overlaps(d.boundingBox, c.boundingBox)))
          .toList();

      setState(() => _statusMessage = '블러 처리 중...');
      final allDetections = [
        ...faceResults,
        ...plateResults,
        ...filteredCards,
        ...filteredDocuments,
        ...shippingResults,
      ];

      final blurred = await _blurService.applyBlur(
        widget.imageFile,
        allDetections,
        _imageSize.width,
        _imageSize.height,
        effect: _selectedEffect,
        blurIntensity: _blurIntensity,
      );

      setState(() {
        _detections         = allDetections;
        _documentDetections = filteredDocuments;
        _cardDetections     = filteredCards;
        _blurredImage       = blurred;
        _isProcessing       = false;
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = '오류가 발생했습니다: $e';
      });
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  // 활성 탐지 목록 (블러 적용 대상)
  // ════════════════════════════════════════════════════════════════════════

  List<DetectionResult> get _activeDetections {
    final active = <DetectionResult>[];

    for (int i = 0; i < _detections.length; i++) {
      final d = _detections[i];
      if (!(_typeBlurEnabled[d.type] ?? true)) continue;
      if (_useTextBlur     && d.type == DetectionType.document) continue;
      if (_useCardTextBlur && d.type == DetectionType.card)     continue;
      final effectiveRect = _detectionOverrides[i] ?? d.boundingBox;
      active.add(d.withRect(effectiveRect));
    }

    if (_useTextBlur && (_typeBlurEnabled[DetectionType.document] ?? true)) {
      active.addAll(_privacyDetections);
    }
    if (_useCardTextBlur && (_typeBlurEnabled[DetectionType.card] ?? true)) {
      active.addAll(_cardPrivacyDetections);
    }

    if (_typeBlurEnabled[DetectionType.manual] ?? true) {
      for (final box in _manualBoxes) {
        if (box.enabled) {
          active.add(DetectionResult(
            type:        DetectionType.manual,
            boundingBox: box.rect,
            confidence:  1.0,
          ));
        }
      }
    }

    return active;
  }

  // ════════════════════════════════════════════════════════════════════════
  // 블러 재적용
  // ════════════════════════════════════════════════════════════════════════

  Future<void> _applyBlurWithCurrentSettings() async {
    setState(() => _isProcessing = true);
    final blurred = await _blurService.applyBlur(
      widget.imageFile,
      _activeDetections,
      _imageSize.width,
      _imageSize.height,
      effect: _selectedEffect,
      blurIntensity: _blurIntensity,
    );
    setState(() {
      _blurredImage = blurred;
      _isProcessing = false;
    });
  }

  // ════════════════════════════════════════════════════════════════════════
  // DetectionOverlay 콜백
  // ════════════════════════════════════════════════════════════════════════

  void _onManualBoxAdded(Rect imageRect) {
    final id = 'manual_${++_manualBoxCounter}';
    setState(() => _manualBoxes.add(ManualBlurBox(id: id, rect: imageRect)));
    _applyBlurWithCurrentSettings();
  }

  void _onManualBoxUpdated(String id, Rect imageRect) {
    final idx = _manualBoxes.indexWhere((b) => b.id == id);
    if (idx == -1) return;
    setState(() =>
    _manualBoxes[idx] = _manualBoxes[idx].copyWith(rect: imageRect));
    _applyBlurWithCurrentSettings();
  }

  void _onManualBoxDeleted(String id) {
    setState(() => _manualBoxes.removeWhere((b) => b.id == id));
    _applyBlurWithCurrentSettings();
  }

  void _onDetectionResized(int index, Rect imageRect) {
    setState(() => _detectionOverrides[index] = imageRect);
    _applyBlurWithCurrentSettings();
  }

  // ════════════════════════════════════════════════════════════════════════
  // 텍스트 탐지 화면 이동
  // ════════════════════════════════════════════════════════════════════════

  Future<void> _openDocumentTextScreen() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => DocumentTextScreen(
          imageFile:          widget.imageFile,
          documentDetections: _documentDetections,
          imageSize:          _imageSize,
        ),
      ),
    );
    if (result == null) return;
    _useTextBlur       = result['useTextBlur'] as bool;
    _privacyDetections = result['privacyResults'] as List<DetectionResult>;
    await _applyBlurWithCurrentSettings();
  }

  Future<void> _openCardTextScreen() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => DocumentTextScreen(
          imageFile:          widget.imageFile,
          documentDetections: _cardDetections,
          imageSize:          _imageSize,
          title:              '카드 텍스트 탐지',
        ),
      ),
    );
    if (result == null) return;
    _useCardTextBlur       = result['useTextBlur'] as bool;
    _cardPrivacyDetections = result['privacyResults'] as List<DetectionResult>;
    await _applyBlurWithCurrentSettings();
  }

  // ════════════════════════════════════════════════════════════════════════
  // 저장 / 공유
  // ════════════════════════════════════════════════════════════════════════

  Future<void> _saveImage() async {
    final bytes = _blurEnabled ? _blurredImage : _originalBytes;
    if (bytes == null) return;
    final dir  = await getTemporaryDirectory();
    final file = File('${dir.path}/garim_save.jpg');
    await file.writeAsBytes(bytes);
    await Gal.putImage(file.path);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('갤러리에 저장되었습니다')),
      );
    }
  }

  Future<void> _shareImage() async {
    final bytes = _blurEnabled ? _blurredImage : _originalBytes;
    if (bytes == null) return;
    final dir  = await getTemporaryDirectory();
    final file = File('${dir.path}/garim_share.jpg');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles(
      [XFile(file.path)],
      text: '가림 앱으로 개인정보를 보호했어요',
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // build
  // ════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        foregroundColor: Colors.white,
        title: const Text(
          '분석 결과',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
      ),
      body: _isProcessing ? _buildLoading() : _buildResult(),
    );
  }

  // ── 로딩 화면 ─────────────────────────────────────────────────────────
  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Color(0xFF6C63FF)),
          const SizedBox(height: 24),
          Text(
            _statusMessage,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // 결과 화면
  // ════════════════════════════════════════════════════════════════════════

  Widget _buildResult() {
    final faceCount   = _detections.where((d) => d.type == DetectionType.face).length;
    final plateCount  = _detections.where((d) => d.type == DetectionType.licensePlate).length;
    final docCount    = _detections.where((d) => d.type == DetectionType.document).length;
    final cardCount   = _detections.where((d) => d.type == DetectionType.card).length;
    final manualCount = _manualBoxes.length;
    final detectedTypes = _detections.map((d) => d.type).toSet();

    return SingleChildScrollView(
      physics: (_isZoomed && _editorMode == EditorMode.view)
          ? const NeverScrollableScrollPhysics()
          : const ClampingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── ① 탐지 요약 배지 ──────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: _cardDeco(),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildBadge('얼굴',   faceCount,   const Color(0xFFFF6B6B)),
                _buildBadge('번호판', plateCount,  const Color(0xFF6C63FF)),
                _buildBadge('카드',   cardCount,   Colors.orange),
                _buildBadge('문서',   docCount,    const Color(0xFF43E97B)),
                if (manualCount > 0)
                  _buildBadge('수동', manualCount, const Color(0xFF00BCD4)),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── ② 유형별 블러 스위치 ─────────────────────────────────────
          if (detectedTypes.isNotEmpty || manualCount > 0)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: _cardDeco(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '블러 처리 항목',
                    style: TextStyle(
                      color:      Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize:   13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (detectedTypes.contains(DetectionType.face))
                    _buildTypeSwitch(
                      icon:  Icons.face_outlined,
                      label: '얼굴 ($faceCount개)',
                      color: const Color(0xFFFF6B6B),
                      type:  DetectionType.face,
                    ),
                  if (detectedTypes.contains(DetectionType.licensePlate))
                    _buildTypeSwitch(
                      icon:  Icons.directions_car_outlined,
                      label: '번호판 ($plateCount개)',
                      color: const Color(0xFF6C63FF),
                      type:  DetectionType.licensePlate,
                    ),
                  if (detectedTypes.contains(DetectionType.card))
                    _buildTypeSwitch(
                      icon:  Icons.credit_card_outlined,
                      label: _useCardTextBlur
                          ? '카드 - 텍스트 영역 (${_cardPrivacyDetections.length}개)'
                          : '카드 전체 ($cardCount개)',
                      color: Colors.orange,
                      type:  DetectionType.card,
                    ),
                  if (detectedTypes.contains(DetectionType.document))
                    _buildTypeSwitch(
                      icon:  Icons.document_scanner_outlined,
                      label: _useTextBlur
                          ? '문서 - 텍스트 영역 (${_privacyDetections.length}개)'
                          : '문서 전체 ($docCount개)',
                      color: const Color(0xFF43E97B),
                      type:  DetectionType.document,
                    ),
                  if (manualCount > 0)
                    _buildTypeSwitch(
                      icon:  Icons.draw_outlined,
                      label: '수동 박스 ($manualCount개)',
                      color: const Color(0xFF00BCD4),
                      type:  DetectionType.manual,
                    ),
                ],
              ),
            ),

          const SizedBox(height: 12),

          // ── ③ 블러 효과 선택 ─────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: _cardDeco(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '블러 효과',
                  style: TextStyle(
                    color:      Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize:   13,
                  ),
                ),
                const SizedBox(height: 10),
                GridView.count(
                  shrinkWrap: true,
                  physics:          const NeverScrollableScrollPhysics(),
                  crossAxisCount:   2,
                  childAspectRatio: 3.6,
                  crossAxisSpacing: 8,
                  mainAxisSpacing:  8,
                  children: [
                    _buildEffectButton('흐림',    BlurEffect.gaussian,     Icons.blur_on),
                    _buildEffectButton('모자이크', BlurEffect.mosaic,       Icons.grid_4x4),
                    _buildEffectButton('블랙 바', BlurEffect.blackBar,     Icons.rectangle_outlined),
                    _buildEffectButton('반투명',   BlurEffect.frostedGlass, Icons.opacity),
                  ],
                ),
                if (_showIntensitySlider) ...[
                  const SizedBox(height: 8),
                  Text(
                    '$_intensityLabel: ${_blurIntensity.toInt()}',
                    style: const TextStyle(
                      color:    Color(0xFF888888),
                      fontSize: 12,
                    ),
                  ),
                  Slider(
                    value:       _blurIntensity,
                    min:         1.0,
                    max:         _intensityMax,
                    divisions:   (_intensityMax - 1).toInt(),
                    activeColor: const Color(0xFF6C63FF),
                    onChanged:   (v) => setState(() => _blurIntensity = v),
                    onChangeEnd: (_) => _applyBlurWithCurrentSettings(),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── ④ 카드 텍스트 탐지 버튼 ──────────────────────────────────
          if (_cardDetections.isNotEmpty)
            Container(
              width:  double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              child: ElevatedButton.icon(
                onPressed: _openCardTextScreen,
                icon:  const Icon(Icons.credit_card_outlined),
                label: Text(
                  _useCardTextBlur
                      ? '카드 텍스트 재탐지 (현재: 텍스트 영역 블러)'
                      : '카드 텍스트 탐지 (현재: 전체 블러)',
                  style: const TextStyle(fontSize: 13),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),

          // ── ⑤ 문서 텍스트 탐지 버튼 ──────────────────────────────────
          if (_documentDetections.isNotEmpty)
            Container(
              width:  double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              child: ElevatedButton.icon(
                onPressed: _openDocumentTextScreen,
                icon:  const Icon(Icons.document_scanner_outlined),
                label: Text(
                  _useTextBlur
                      ? '문서 텍스트 재탐지 (현재: 텍스트 영역 블러)'
                      : '문서 텍스트 탐지 (현재: 전체 블러)',
                  style: const TextStyle(fontSize: 13),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF43E97B),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),

          // ── ⑥ 블러 미리보기 토글 ─────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: _cardDeco(),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      _blurEnabled ? Icons.blur_on : Icons.blur_off,
                      color: _blurEnabled
                          ? const Color(0xFF6C63FF)
                          : const Color(0xFF888888),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _blurEnabled ? '블러 미리보기 ON' : '블러 미리보기 OFF',
                      style: TextStyle(
                        color: _blurEnabled
                            ? Colors.white
                            : const Color(0xFF888888),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Switch(
                  value:           _blurEnabled,
                  onChanged:       (val) => setState(() => _blurEnabled = val),
                  activeThumbColor: const Color(0xFF6C63FF),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── ⑦ 뷰 / 편집 모드 전환 ─────────────────────────────────────
          Container(
            padding:    const EdgeInsets.all(4),
            decoration: _cardDeco(),
            child: Row(
              children: [
                Expanded(
                  child: _buildModeButton(
                    icon:     Icons.search_rounded,
                    label:    '뷰 모드',
                    subLabel: '확대 · 이동',
                    mode:     EditorMode.view,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _buildModeButton(
                    icon:     Icons.touch_app_rounded,
                    label:    '편집 모드',
                    subLabel: '박스 추가 · 조절',
                    mode:     EditorMode.edit,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── ⑧ 이미지 + DetectionOverlay ──────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (_imageSize == Size.zero || _originalBytes == null) {
                  return const SizedBox.shrink();
                }

                final displayWidth  = constraints.maxWidth;
                final displayHeight =
                    _imageSize.height * displayWidth / _imageSize.width;
                final displaySize = Size(displayWidth, displayHeight);

                return InteractiveViewer(
                  transformationController: _transformationController,
                  // 핵심 제스처 분리:
                  // 뷰 모드  → pan/scale ON  (InteractiveViewer 가 제스처 처리)
                  // 편집 모드 → pan/scale OFF (DetectionOverlay 가 제스처 처리)
                  panEnabled:   _editorMode == EditorMode.view,
                  scaleEnabled: _editorMode == EditorMode.view,
                  minScale:     1.0,
                  maxScale:     5.0,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width:  displayWidth,
                    height: displayHeight,
                    child: Stack(
                      children: [
                        // 이미지 레이어
                        Positioned.fill(
                          child: (_blurEnabled && _blurredImage != null)
                              ? Image.memory(_blurredImage!, fit: BoxFit.fill)
                              : Image.memory(_originalBytes!, fit: BoxFit.fill),
                        ),
                        // 오버레이 레이어
                        DetectionOverlay(
                          editMode:              _editorMode == EditorMode.edit,
                          imageSize:             _imageSize,
                          displaySize:           displaySize,
                          detections:            _detections,
                          detectionOverrides:    _detectionOverrides,
                          typeBlurEnabled:       _typeBlurEnabled,
                          manualBoxes:           _manualBoxes,
                          privacyDetections:     _privacyDetections,
                          cardPrivacyDetections: _cardPrivacyDetections,
                          useTextBlur:           _useTextBlur,
                          useCardTextBlur:       _useCardTextBlur,
                          onManualBoxAdded:      _onManualBoxAdded,
                          onManualBoxUpdated:    _onManualBoxUpdated,
                          onManualBoxDeleted:    _onManualBoxDeleted,
                          onDetectionResized:    _onDetectionResized,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 6),

          Center(
            child: Text(
              _editorMode == EditorMode.edit
                  ? '👆 편집 모드: 드래그로 박스 추가, 모서리로 크기 조절'
                  : (_blurEnabled ? '블러 처리된 이미지' : '탐지된 영역을 확인하세요'),
              style: TextStyle(
                color: _editorMode == EditorMode.edit
                    ? const Color(0xFF00BCD4)
                    : const Color(0xFF888888),
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ),

          const SizedBox(height: 24),

          // ── ⑨ 저장 / 공유 버튼 ───────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _saveImage,
                  icon:  const Icon(Icons.save_alt_outlined),
                  label: const Text('저장'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E1E1E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _shareImage,
                  icon:  const Icon(Icons.share_outlined),
                  label: const Text('공유'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

        ], // Column children 끝
      ), // Column 끝
    ); // SingleChildScrollView 끝
  }

  // ════════════════════════════════════════════════════════════════════════
  // 슬라이더 조건 헬퍼 (sticker 케이스 없음)
  // ════════════════════════════════════════════════════════════════════════

  bool get _showIntensitySlider =>
      _selectedEffect == BlurEffect.gaussian     ||
          _selectedEffect == BlurEffect.mosaic       ||
          _selectedEffect == BlurEffect.frostedGlass;
  // blackBar 는 강도 조절 불필요 → 슬라이더 숨김

  String get _intensityLabel {
    switch (_selectedEffect) {
      case BlurEffect.gaussian:     return '흐림 강도';
      case BlurEffect.mosaic:       return '픽셀 크기';
      case BlurEffect.frostedGlass: return '흐림 강도';
      default:                      return '';
    }
  }

  double get _intensityMax =>
      _selectedEffect == BlurEffect.mosaic ? 100.0 : 30.0;

  // ════════════════════════════════════════════════════════════════════════
  // 위젯 빌더 헬퍼
  // ════════════════════════════════════════════════════════════════════════

  BoxDecoration _cardDeco() => BoxDecoration(
    color:        const Color(0xFF1E1E1E),
    borderRadius: BorderRadius.circular(12),
  );

  // ── 뷰/편집 모드 버튼 ─────────────────────────────────────────────────
  Widget _buildModeButton({
    required IconData   icon,
    required String     label,
    required String     subLabel,
    required EditorMode mode,
  }) {
    final isActive    = _editorMode == mode;
    final activeColor = mode == EditorMode.edit
        ? const Color(0xFF00BCD4)
        : const Color(0xFF6C63FF);

    return GestureDetector(
      onTap: () => setState(() => _editorMode = mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: isActive
              ? activeColor.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive ? activeColor : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size:  18,
              color: isActive ? activeColor : const Color(0xFF555555),
            ),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color:      isActive ? Colors.white : const Color(0xFF555555),
                    fontSize:   13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  subLabel,
                  style: TextStyle(
                    color: isActive
                        ? activeColor.withValues(alpha: 0.8)
                        : const Color(0xFF444444),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── 블러 효과 버튼 (sticker 없음) ────────────────────────────────────
  Widget _buildEffectButton(
      String     label,
      BlurEffect effect,
      IconData   icon,
      ) {
    final isSelected = _selectedEffect == effect;
    return GestureDetector(
      onTap: () async {
        setState(() {
          _selectedEffect = effect;
          _blurIntensity  = switch (effect) {
            BlurEffect.gaussian     => 12.0,
            BlurEffect.mosaic       => 20.0,
            BlurEffect.blackBar     => 20.0,
            BlurEffect.frostedGlass => 10.0,
          };
        });
        await _applyBlurWithCurrentSettings();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF6C63FF)
              : const Color(0xFF2D2D2D),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size:  15,
              color: isSelected ? Colors.white : const Color(0xFF888888),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color:      isSelected ? Colors.white : const Color(0xFF888888),
                fontSize:   12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 유형별 블러 스위치 행 ─────────────────────────────────────────────
  Widget _buildTypeSwitch({
    required IconData      icon,
    required String        label,
    required Color         color,
    required DetectionType type,
  }) {
    final isEnabled = _typeBlurEnabled[type] ?? true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width:  32,
            height: 32,
            decoration: BoxDecoration(
              color: isEnabled
                  ? color.withValues(alpha: 0.15)
                  : const Color(0xFF2D2D2D),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              size:  18,
              color: isEnabled ? color : const Color(0xFF555555),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color:    isEnabled ? Colors.white : const Color(0xFF555555),
                fontSize: 13,
              ),
            ),
          ),
          Switch(
            value:    isEnabled,
            onChanged: (val) async {
              setState(() => _typeBlurEnabled[type] = val);
              await _applyBlurWithCurrentSettings();
            },
            activeThumbColor: color,
          ),
        ],
      ),
    );
  }

  // ── 탐지 요약 배지 ────────────────────────────────────────────────────
  Widget _buildBadge(String label, int count, Color color) {
    return Column(           children: [
      Text(
        '$count',
        style: TextStyle(
          color:      color,
          fontSize:   26,
          fontWeight: FontWeight.bold,
        ),
      ),
      Text(
        label,
        style: const TextStyle(
          color:    Color(0xFF888888),
          fontSize: 12,
        ),
      ),
    ],
    );
  }

} // _ResultScreenState 끝