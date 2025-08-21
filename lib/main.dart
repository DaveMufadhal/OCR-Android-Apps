import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OCR App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: OCRHomePage(),
    );
  }
}

class OCRHomePage extends StatefulWidget {
  @override
  _OCRHomePageState createState() => _OCRHomePageState();
}

class _OCRHomePageState extends State<OCRHomePage> {
  String scannedText = 'No text scanned yet';
  File? _image;
  final ImagePicker _picker = ImagePicker();
  final TextRecognizer _textRecognizer = TextRecognizer();
  bool _isProcessing = false;

  @override
  void dispose() {
    _textRecognizer.close();
    super.dispose();
  }

  Future<void> _requestPermission(Permission permission) async {
    final status = await permission.request();
    if (status.isDenied) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Permission is required for this feature')),
      );
    } else if (status.isPermanentlyDenied) {
      // Show a dialog to guide the user to app settings
      showDialog(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text('Permission Required'),
          content: Text('This feature needs permission to work. Please enable it in app settings.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () => openAppSettings(),
              child: Text('Open Settings'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _getImage(ImageSource source) async {
    if (source == ImageSource.camera) {
      await _requestPermission(Permission.camera);
    } else {
      // Fix the Android version check
      if (Platform.isAndroid) {
        try {
          // Get the Android SDK version properly
          final sdkInt = int.parse(Platform.operatingSystem.split(' ').last);
          if (sdkInt >= 13) {
            await _requestPermission(Permission.photos);
          } else {
            await _requestPermission(Permission.storage);
          }
        } catch (e) {
          // Fallback to storage permission if version detection fails
          await _requestPermission(Permission.storage);
        }
      } else {
        await _requestPermission(Permission.photos);
      }
    }

    try {
      final XFile? pickedFile = await _picker.pickImage(source: source);

      if (pickedFile != null) {
        setState(() {
          _image = File(pickedFile.path);
          _isProcessing = true;
          scannedText = 'Processing image...';
        });

        await _processImage();
      }
    } catch (e) {
      setState(() {
        scannedText = 'Error picking image: $e';
      });
    }
  }

  Future<void> _processImage() async {
    if (_image == null) return;

    try {
      final inputImage = InputImage.fromFilePath(_image!.path);
      final recognizedText = await _textRecognizer.processImage(inputImage);

      setState(() {
        _isProcessing = false;
        scannedText = recognizedText.text;
        if (scannedText.isEmpty) {
          scannedText = 'No text found in the image';
        }
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        scannedText = 'Error recognizing text: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('OCR Scanner'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Image preview container
            Container(
              margin: EdgeInsets.all(20),
              height: 300,
              decoration: BoxDecoration(
                color: Colors.grey[200],
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _image == null
                  ? Center(child: Text('Image will appear here'))
                  : ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  _image!,
                  fit: BoxFit.contain,
                ),
              ),
            ),

            // Buttons row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isProcessing ? null : () => _getImage(ImageSource.gallery),
                      icon: Icon(Icons.image),
                      label: Text('Gallery'),
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  SizedBox(width: 20),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isProcessing ? null : () => _getImage(ImageSource.camera),
                      icon: Icon(Icons.camera_alt),
                      label: Text('Camera'),
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Processing indicator
            if (_isProcessing)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: CircularProgressIndicator(),
                ),
              ),

            // Scanned text header
            Padding(
              padding: EdgeInsets.only(left: 20, right: 20, top: 20),
              child: Text(
                'Scanned Text:',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),

            // Scanned text container
            Container(
              margin: EdgeInsets.all(20),
              padding: EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Text(
                scannedText,
                style: TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}