// lib/main.dart
// DIDEP SCANNER
// - Splash Screen pakai logo (assets/logo.png)
// - OCR Home: preview gambar ASLI, OCR via preprocess (grayscale + perbaikan orientasi EXIF) + fallback ke original
// - Copy / Share hasil OCR
// - Tanpa overlay kotak hijau (UI clean)
// - Komentar ada di setiap bagian biar gampang diutak-atik

import 'dart:io';
import 'package:flutter/foundation.dart';       // compute() untuk isolate
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';         // Clipboard & Haptic
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;       // preprocessing gambar
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const DiddepScannerApp());

/// Root aplikasi
class DiddepScannerApp extends StatelessWidget {
  const DiddepScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DIDEP Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2F4A86), // nuansa biru sesuai logo
      ),
      // Routing sederhana: Splash -> Home
      routes: {
        '/': (_) => const SplashScreen(),
        '/home': (_) => const OcrHome(),
      },
    );
  }
}

/// Splash screen sederhana menampilkan logo lalu pindah ke Home
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    // Delay 2 detik lalu ke halaman utama
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/home');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface, // lembut sesuai tema
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // LOGO
            Image.asset(
              'assets/logo_didep.png',
              width: 200,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 16),
            // Nama app
            Text(
              'DIDEP SCANNER',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 24),
            // Progress kecil
            const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ],
        ),
      ),
    );
  }
}

/// Halaman utama OCR
class OcrHome extends StatefulWidget {
  const OcrHome({super.key});
  @override
  State<OcrHome> createState() => _OcrHomeState();
}

class _OcrHomeState extends State<OcrHome> {
  // Reuse ML Kit TextRecognizer agar hemat resource
  late final TextRecognizer _recognizer;
  final ImagePicker _picker = ImagePicker();

  bool _isScanning = false;

  // File yang DITAMPILKAN di UI (gambar asli untuk preview)
  File? _previewFile;

  // Ukuran gambar hasil preprocess/oriented (untuk overlay scaling jika suatu saat diaktifkan)
  Size? _imageSize;

  // Hasil OCR
  String _text = '';

  @override
  void initState() {
    super.initState();
    _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  }

  @override
  void dispose() {
    _recognizer.close();
    super.dispose();
  }

  // ====== Aksi umum ======
  Future<void> _copyText() async {
    if (_text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard')),
      );
    }
  }

  Future<void> _shareText() async {
    if (_text.isEmpty) return;
    await Share.share(_text, subject: 'OCR Result');
  }

  // ====== Permission kamera ======
  Future<bool> _ensureCameraPermission() async {
    final status = await Permission.camera.request();
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Camera permission required'),
          content: const Text('Please enable camera permission in Settings.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open Settings')),
          ],
        ),
      );
      if (ok == true) await openAppSettings();
    }
    return false;
  }

  // ====== Ambil gambar ======
  Future<void> _pickFromCamera() async {
    if (!await _ensureCameraPermission()) return;
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 75,   // kompres ringan -> OCR cepat
      maxWidth: 1600,
      requestFullMetadata: false,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (file != null) await _runOcr(File(file.path));
  }

  Future<void> _pickFromGallery() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 2000,
      requestFullMetadata: false,
    );
    if (file != null) await _runOcr(File(file.path));
  }

  // ====== Pipeline OCR ======
  Future<void> _runOcr(File original) async {
    if (_isScanning) return; // debounce
    setState(() {
      _isScanning = true;
      _text = '';
      _previewFile = null;
      _imageSize = null;
    });

    try {
      // 1) Preprocess di isolate: panggang orientasi EXIF + grayscale + kontras ringan
      final prep = await compute<_PPIn, _PPOut>(
        _preprocessIsolate,
        _PPIn(original.path, 1.08, 0.0, 85),
      );

      final processed = File(prep.outputPath);
      final size = Size(prep.width.toDouble(), prep.height.toDouble());

      // 2) OCR pada gambar preprocess
      var recognized = await _recognizer.processImage(
        InputImage.fromFilePath(processed.path),
      );

      // 3) Fallback: jika kosong, coba ke file original
      if (recognized.text.trim().isEmpty) {
        final retry = await _recognizer.processImage(
          InputImage.fromFilePath(original.path),
        );
        if (retry.text.trim().isNotEmpty) {
          recognized = retry;
        }
      }

      // 4) Tampilkan hasil (preview tetap gambar ASLI)
      if (!mounted) return;
      setState(() {
        _previewFile = original;
        _imageSize = size;
        _text = recognized.text;
      });

      if (_text.isNotEmpty) HapticFeedback.mediumImpact();
      if (_text.trim().isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No text detected.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  // ====== UI ======
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // AppBar dengan logo + judul
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            const SizedBox(width: 8),
            Image.asset('assets/logo_didep.png', height: 28),
            const SizedBox(width: 8),
            const Text('DIDEP Scanner'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Copy',
            onPressed: _text.isNotEmpty ? _copyText : null,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Share',
            onPressed: _text.isNotEmpty ? _shareText : null,
            icon: const Icon(Icons.ios_share_outlined),
          ),
        ],
      ),

      // Tombol scan cepat di pojok (opsional)
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? null : _pickFromCamera,
        icon: const Icon(Icons.document_scanner_outlined),
        label: const Text('Pindai'),
      ),

      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // PREVIEW
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceVariant,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            clipBehavior: Clip.antiAlias,
            child: _buildPreview(),
          ),
          const SizedBox(height: 12),

          // GALERI / KAMERA
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isScanning ? null : _pickFromGallery,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Gallery'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isScanning ? null : _pickFromCamera,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Camera'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // JUDUL + COPY/SHARE
          Text('Scanned Text:', style: Theme.of(context).textTheme.titleMedium),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _text.isNotEmpty ? _copyText : null,
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Copy'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _text.isNotEmpty ? _shareText : null,
                    icon: const Icon(Icons.ios_share_outlined),
                    label: const Text('Share'),
                  ),
                ),
              ],
            ),
          ),

          // HASIL TEKS
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            padding: const EdgeInsets.all(12),
            child: _text.isEmpty
                ? const Text('No text scanned yet')
                : SelectableText(_text),
          ),
        ],
      ),
    );
  }

  // Widget preview gambar (tanpa overlay kotak hijau)
  Widget _buildPreview() {
    if (_isScanning) return const Center(child: CircularProgressIndicator());
    if (_previewFile == null) {
      return const Center(child: Text('Image will appear here'));
    }
    return Image.file(
      _previewFile!,
      fit: BoxFit.contain, // jangan crop
    );
  }
}

// ====== Isolate untuk preprocess gambar ======

class _PPIn {
  final String path;
  final double contrast;
  final double brightness;
  final int jpegQuality;
  const _PPIn(this.path, this.contrast, this.brightness, this.jpegQuality);
}

class _PPOut {
  final String outputPath;
  final int width;
  final int height;
  const _PPOut(this.outputPath, this.width, this.height);
}

Future<_PPOut> _preprocessIsolate(_PPIn input) async {
  final bytes = await File(input.path).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return _PPOut(input.path, 1, 1);

  // Penting: panggang orientasi EXIF -> piksel jadi “tegak”
  final oriented = img.bakeOrientation(decoded);

  // Grayscale + sedikit kontras (aman untuk sebagian besar dokumen)
  final gray = img.grayscale(oriented);
  final tuned = img.adjustColor(gray,
      contrast: input.contrast, brightness: input.brightness);

  // Simpan ke file baru
  final outBytes = img.encodeJpg(tuned, quality: input.jpegQuality);
  final outPath = _appendSuffixToPath(input.path, '_pp');
  await File(outPath).writeAsBytes(outBytes);

  return _PPOut(outPath, tuned.width, tuned.height);
}

String _appendSuffixToPath(String path, String suffix) {
  final i = path.lastIndexOf('.');
  if (i < 0) return '$path$suffix';
  return '${path.substring(0, i)}$suffix${path.substring(i)}';
}
