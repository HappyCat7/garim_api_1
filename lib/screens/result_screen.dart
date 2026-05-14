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
import '../models/detection_result.dart';
import 'document_text_screen.dart';
import '../services/shipping_label_detector_service.dart';

bool _pointerInImage = false;

class ResultScreen extends StatefulWidget {
  final File imageFile;
  const ResultScreen({super.key, required this.imageFile});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  final _faceService = FaceDetectorService();
  final _plateService = PlateDetectorService();
  final _documentService = DocumentDetectorService();
  final _cardService = CardDetectorService();
  final _shippingLabelService = ShippingLabelDetectorService();
  final _privacyService = PrivacyDetectorService();
  final _blurService = BlurService();
  final Set<int> _disabledDetections = {};

  List<DetectionResult> _detections = [];
  List<DetectionResult> _documentDetections = [];
  List<DetectionResult> _cardDetections = [];
  List<DetectionResult> _privacyDetections = [];
  List<DetectionResult> _cardPrivacyDetections = [];
  Uint8List? _blurredImage;
  Uint8List? _originalBytes;
  bool _isProcessing = true;
  String _statusMessage = '분석 중...';
  bool _blurEnabled = false;
  bool _useTextBlur = false;
  bool _useCardTextBlur = false;

  // 블러 효과 설정
  BlurEffect _selectedEffect = BlurEffect.mosaic;
  double _blurIntensity = 20.0;

  final Map<DetectionType, bool> _typeBlurEnabled = {
    DetectionType.face: true,
    DetectionType.licensePlate: true,
    DetectionType.document: true,
    DetectionType.card: true,
  };

  Size _imageSize = Size.zero;

  final _transformationController = TransformationController();
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(() {
      final scale = _transformationController.value.getMaxScaleOnAxis();
      final zoomed = scale > 1.01;
      if (zoomed != _isZoomed) {
        setState(() => _isZoomed = zoomed);
      }
    });
    _analyze();
  }

  bool _overlaps(Rect a, Rect b) {
    return a.left < b.right &&
        a.right > b.left &&
        a.top < b.bottom &&
        a.bottom > b.top;
  }

  List<DetectionResult> get _activeDetections {
    final active = <DetectionResult>[];
    for (final d in _detections) {
      if (!(_typeBlurEnabled[d.type] ?? true)) continue;
      if (_useTextBlur && d.type == DetectionType.document) continue;
      if (_useCardTextBlur && d.type == DetectionType.card) continue;
      active.add(d);
    }
    if (_useTextBlur && (_typeBlurEnabled[DetectionType.document] ?? true)) {
      active.addAll(_privacyDetections);
    }
    if (_useCardTextBlur && (_typeBlurEnabled[DetectionType.card] ?? true)) {
      active.addAll(_cardPrivacyDetections);
    }
    return active;
  }

  Future<void> _analyze() async {
    try {
      _originalBytes = await widget.imageFile.readAsBytes();
      final decoded = await decodeImageFromList(_originalBytes!);
      _imageSize = Size(decoded.width.toDouble(), decoded.height.toDouble());

      setState(() => _statusMessage = '얼굴을 찾고 있어요...');
      final inputImage = InputImage.fromFile(widget.imageFile);
      final faceResults = await _faceService.detect(inputImage);

      setState(() => _statusMessage = '번호판을 확인하고 있어요...');
      final plateResults = await _plateService.detect(widget.imageFile);
      //final plateResults = <DetectionResult>[];

      setState(() => _statusMessage = '카드를 확인하고 있어요...');
      final cardResults = await _cardService.detect(widget.imageFile);

      setState(() => _statusMessage = '문서를 스캔하고 있어요...');
      final documentResults = await _documentService.detect(widget.imageFile);

      setState(() => _statusMessage = '운송장을 확인하고 있어요...');
      final shippingResults = await _shippingLabelService.detect(widget.imageFile);

      // 우선순위: 번호판 > 카드 > 문서
      final filteredCards = cardResults.where((card) {
        for (final plate in plateResults) {
          if (_overlaps(card.boundingBox, plate.boundingBox)) return false;
        }
        return true;
      }).toList();

      final filteredDocuments = documentResults.where((doc) {
        for (final plate in plateResults) {
          if (_overlaps(doc.boundingBox, plate.boundingBox)) return false;
        }
        for (final card in filteredCards) {
          if (_overlaps(doc.boundingBox, card.boundingBox)) return false;
        }
        return true;
      }).toList();

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
        _detections = allDetections;
        _documentDetections = filteredDocuments;
        _cardDetections = filteredCards;
        _blurredImage = blurred;
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = '오류가 발생했습니다: $e';
      });
    }
  }

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

  Future<void> _openDocumentTextScreen() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => DocumentTextScreen(
          imageFile: widget.imageFile,
          documentDetections: _documentDetections,
          imageSize: _imageSize,
        ),
      ),
    );
    if (result == null) return;
    _useTextBlur = result['useTextBlur'] as bool;
    _privacyDetections = result['privacyResults'] as List<DetectionResult>;
    await _applyBlurWithCurrentSettings();
  }

  Future<void> _openCardTextScreen() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => DocumentTextScreen(
          imageFile: widget.imageFile,
          documentDetections: _cardDetections,
          imageSize: _imageSize,
          title: '카드 텍스트 탐지',
        ),
      ),
    );
    if (result == null) return;
    _useCardTextBlur = result['useTextBlur'] as bool;
    _cardPrivacyDetections = result['privacyResults'] as List<DetectionResult>;
    await _applyBlurWithCurrentSettings();
  }

  Future<void> _saveImage() async {
    final bytes = _blurEnabled ? _blurredImage : _originalBytes;
    if (bytes == null) return;
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/garim_save.jpg');
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
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/garim_share.jpg');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(file.path)], text: '가림 앱으로 개인정보를 보호했어요');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        foregroundColor: Colors.white,
        title: const Text('분석 결과',
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: _isProcessing ? _buildLoading() : _buildResult(),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Color(0xFF6C63FF)),
          const SizedBox(height: 24),
          Text(_statusMessage,
              style: const TextStyle(color: Colors.white, fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildResult() {
    final faceCount =
        _detections.where((d) => d.type == DetectionType.face).length;
    final plateCount =
        _detections.where((d) => d.type == DetectionType.licensePlate).length;
    final docCount =
        _detections.where((d) => d.type == DetectionType.document).length;
    final cardCount =
        _detections.where((d) => d.type == DetectionType.card).length;

    final detectedTypes = <DetectionType>{};
    for (final d in _detections) {
      detectedTypes.add(d.type);
    }

    return SingleChildScrollView(
      physics: (_isZoomed && _pointerInImage)
          ? const NeverScrollableScrollPhysics()  // 확대 중엔 스크롤 차단
          : const ClampingScrollPhysics(),

      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 탐지 요약
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildBadge('얼굴', faceCount, const Color(0xFFFF6B6B)),
                _buildBadge('번호판', plateCount, const Color(0xFF6C63FF)),
                _buildBadge('카드', cardCount, Colors.orange),
                _buildBadge('문서', docCount, const Color(0xFF43E97B)),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // 유형별 블러 스위치
          if (detectedTypes.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '블러 처리 항목',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (detectedTypes.contains(DetectionType.face))
                    _buildTypeSwitch(
                      icon: Icons.face_outlined,
                      label: '얼굴 ($faceCount개)',
                      color: const Color(0xFFFF6B6B),
                      type: DetectionType.face,
                    ),
                  if (detectedTypes.contains(DetectionType.licensePlate))
                    _buildTypeSwitch(
                      icon: Icons.directions_car_outlined,
                      label: '번호판 ($plateCount개)',
                      color: const Color(0xFF6C63FF),
                      type: DetectionType.licensePlate,
                    ),
                  if (detectedTypes.contains(DetectionType.card))
                    _buildTypeSwitch(
                      icon: Icons.credit_card_outlined,
                      label: _useCardTextBlur
                          ? '카드 - 텍스트 영역 (${_cardPrivacyDetections.length}개)'
                          : '카드 전체 ($cardCount개)',
                      color: Colors.orange,
                      type: DetectionType.card,
                    ),
                  if (detectedTypes.contains(DetectionType.document))
                    _buildTypeSwitch(
                      icon: Icons.document_scanner_outlined,
                      label: _useTextBlur
                          ? '문서 - 텍스트 영역 (${_privacyDetections.length}개)'
                          : '문서 전체 ($docCount개)',
                      color: const Color(0xFF43E97B),
                      type: DetectionType.document,
                    ),
                ],
              ),
            ),

          const SizedBox(height: 12),

          // 블러 효과 선택
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '블러 효과',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildEffectButton('흐림', BlurEffect.gaussian),
                    _buildEffectButton('모자이크', BlurEffect.mosaic),
                    _buildEffectButton('스티커', BlurEffect.sticker),
                  ],
                ),
                if (_selectedEffect != BlurEffect.sticker) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${_selectedEffect == BlurEffect.gaussian ? '흐림 강도' : '픽셀 크기'}: ${_blurIntensity.toInt()}',
                    style: const TextStyle(
                        color: Color(0xFF888888), fontSize: 12),
                  ),
                  Slider(
                    value: _blurIntensity,
                    min: 1.0,
                    max: _selectedEffect == BlurEffect.gaussian ? 30.0 : 100.0,
                    divisions:
                    _selectedEffect == BlurEffect.gaussian ? 29 : 99,
                    activeColor: const Color(0xFF6C63FF),
                    onChanged: (val) =>
                        setState(() => _blurIntensity = val),
                    onChangeEnd: (_) => _applyBlurWithCurrentSettings(),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 12),

          // 카드 텍스트 탐지 버튼
          if (_cardDetections.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              child: ElevatedButton.icon(
                onPressed: _openCardTextScreen,
                icon: const Icon(Icons.credit_card_outlined),
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

          // 문서 텍스트 탐지 버튼
          if (_documentDetections.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              child: ElevatedButton.icon(
                onPressed: _openDocumentTextScreen,
                icon: const Icon(Icons.document_scanner_outlined),
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

          // 블러 미리보기 ON/OFF
          Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(12),
            ),
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
                  value: _blurEnabled,
                  onChanged: (val) => setState(() => _blurEnabled = val),
                  activeThumbColor: const Color(0xFF6C63FF),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 이미지 + 탐지 박스
          Listener(
            onPointerDown: (_) => setState(() => _pointerInImage = true),
            onPointerUp: (_) => setState(() => _pointerInImage = false),
            onPointerCancel: (_) => setState(() => _pointerInImage = false),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final displayWidth = constraints.maxWidth;
                  final displayHeight =
                      _imageSize.height * displayWidth / _imageSize.width;

                  return InteractiveViewer(
                    transformationController: _transformationController,
                    minScale: 1.0,
                    maxScale: 5.0,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: displayWidth,
                      height: displayHeight,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: _blurEnabled && _blurredImage != null
                                ? Image.memory(_blurredImage!, fit: BoxFit.fill)
                                : Image.memory(_originalBytes!, fit: BoxFit.fill),
                          ),

                          // 탐지 박스
                          ..._detections.asMap().entries.map((entry) {
                            final index = entry.key;
                            final d = entry.value;
                            final scaleX = displayWidth / _imageSize.width;
                            final scaleY = displayHeight / _imageSize.height;
                            final left = d.boundingBox.left * scaleX;
                            final top = d.boundingBox.top * scaleY;
                            final width = d.boundingBox.width * scaleX;
                            final height = d.boundingBox.height * scaleY;
                            final isActive = (_typeBlurEnabled[d.type] ?? true) && !_disabledDetections.contains(index);

                            return Positioned(
                              left: left,
                              top: top,
                              width: width,
                              height: height,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Container(
                                    width: width,
                                    height: height,
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: isActive
                                            ? d.typeColor
                                            : d.typeColor.withValues(alpha: 0.3),
                                        width: 2.5,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                  Positioned(
                                    top: -20,
                                    left: 0,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isActive
                                            ? d.typeColor
                                            : d.typeColor.withValues(alpha: 0.3),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        isActive
                                            ? d.typeLabel
                                            : '${d.typeLabel} (OFF)',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),

                          // 문서 개인정보 영역
                          if (_useTextBlur)
                            ..._privacyDetections.map((d) {
                              final scaleX = displayWidth / _imageSize.width;
                              final scaleY = displayHeight / _imageSize.height;
                              return Positioned(
                                left: d.boundingBox.left * scaleX,
                                top: d.boundingBox.top * scaleY,
                                width: d.boundingBox.width * scaleX,
                                height: d.boundingBox.height * scaleY,
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: const Color(0xFF43E97B),
                                      width: 2,
                                    ),
                                    color: const Color(0xFF43E97B)
                                        .withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              );
                            }),

                          // 카드 개인정보 영역
                          if (_useCardTextBlur)
                            ..._cardPrivacyDetections.map((d) {
                              final scaleX = displayWidth / _imageSize.width;
                              final scaleY = displayHeight / _imageSize.height;
                              return Positioned(
                                left: d.boundingBox.left * scaleX,
                                top: d.boundingBox.top * scaleY,
                                width: d.boundingBox.width * scaleX,
                                height: d.boundingBox.height * scaleY,
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: Colors.orange,
                                      width: 2,
                                    ),
                                    color: Colors.orange.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              );
                            }),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          const SizedBox(height: 8),
          Center(
            child: Text(
              _blurEnabled ? '블러 처리된 이미지' : '탐지된 영역을 확인하세요',
              style: const TextStyle(
                  color: Color(0xFF888888), fontSize: 12),
            ),
          ),

          const SizedBox(height: 24),

          // 저장 / 공유
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _saveImage,
                  icon: const Icon(Icons.save_alt_outlined),
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
                  icon: const Icon(Icons.share_outlined),
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
        ],
      ),
    );
  }

  Widget _buildEffectButton(String label, BlurEffect effect) {
    final isSelected = _selectedEffect == effect;
    return GestureDetector(
      onTap: () async {
        setState(() {
          _selectedEffect = effect;
          _blurIntensity =
          effect == BlurEffect.gaussian ? 12.0 : 20.0;
        });
        await _applyBlurWithCurrentSettings();
      },
      child: Container(
        padding:
        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF6C63FF)
              : const Color(0xFF2D2D2D),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : const Color(0xFF888888),
            fontSize: 13,
            fontWeight:
            isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildTypeSwitch({
    required IconData icon,
    required String label,
    required Color color,
    required DetectionType type,
  }) {
    final isEnabled = _typeBlurEnabled[type] ?? true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isEnabled
                  ? color.withValues(alpha: 0.15)
                  : const Color(0xFF2D2D2D),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              color: isEnabled ? color : const Color(0xFF555555),
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color:
                isEnabled ? Colors.white : const Color(0xFF555555),
                fontSize: 13,
              ),
            ),
          ),
          Switch(
            value: isEnabled,
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

  Widget _buildBadge(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(
            color: color,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(label,
            style: const TextStyle(
                color: Color(0xFF888888), fontSize: 12)),
      ],
    );
  }
}