import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
// 👇 這裡換成了全新的救星套件！
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:gal/gal.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '文字音檔轉影片',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _textController = TextEditingController(text: '在此輸入文字');
  double _fontSize = 50.0;
  String _resolution = '1080p';
  String? _audioPath;
  String? _audioName;
  bool _isProcessing = false;
  String _status = '準備就緒';
  
  final ScreenshotController _screenshotController = ScreenshotController();

  Future<void> _pickAudio() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
    );

    if (result != null) {
      setState(() {
        _audioPath = result.files.single.path;
        _audioName = result.files.single.name;
        _status = '已選擇音檔: $_audioName';
      });
    }
  }

  Future<void> _generateVideo() async {
    if (_textController.text.isEmpty || _audioPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請輸入文字並選擇音檔')),
      );
      return;
    }

    setState(() {
      _isProcessing = true;
      _status = '正在生成文字圖片...';
    });

    try {
      double videoWidth = _resolution == '1080p' ? 1920 : 1280;
      double videoHeight = _resolution == '1080p' ? 1080 : 720;

      final Uint8List? imageBytes = await _screenshotController.captureFromWidget(
        Container(
          width: videoWidth,
          height: videoHeight,
          color: Colors.black,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(50),
          child: Text(
            _textController.text,
            style: TextStyle(
              color: Colors.white,
              fontSize: _fontSize,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        delay: const Duration(milliseconds: 100),
      );

      if (imageBytes == null) throw Exception('圖片生成失敗');

      final tempDir = await getTemporaryDirectory();
      final imageFile = File('${tempDir.path}/text_image.png');
      await imageFile.writeAsBytes(imageBytes);

      final appDocDir = await getApplicationDocumentsDirectory();
      final outputVideoPath = '${appDocDir.path}/output_video.mp4';

      if (await File(outputVideoPath).exists()) {
        await File(outputVideoPath).delete();
      }

      setState(() {
        _status = '正在合併影音 (FFmpeg)...這可能需要一些時間';
      });

      final ffmpegCommand = '-loop 1 -i ${imageFile.path} -i "$_audioPath" -s ${videoWidth.toInt()}x${videoHeight.toInt()} -c:v mpeg4 -q:v 2 -c:a aac -b:a 192k -pix_fmt yuv420p -shortest "$outputVideoPath"';

      await FFmpegKit.execute(ffmpegCommand).then((session) async {
        final returnCode = await session.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          bool hasPermission = await Gal.hasAccess();
          if (!hasPermission) {
            hasPermission = await Gal.requestAccess();
          }
          
          if (hasPermission) {
             await Gal.putVideo(outputVideoPath);
             setState(() {
               _status = '轉換成功！影片已保存到相簿。\n畫質: $_resolution';
             });
          } else {
             setState(() {
               _status = '轉換成功，但無相簿權限。\n影片存於: $outputVideoPath';
             });
          }
        } else {
          final failStackTrace = await session.getFailStackTrace();
          setState(() {
            _status = '轉換失敗。\nERROR: $failStackTrace';
          });
        }
      });
    } catch (e) {
      setState(() {
        _status = '發生錯誤: $e';
      });
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('文字音檔轉影片')),
      body: _isProcessing
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                  ],
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      labelText: '輸入影片文字',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('影片畫質:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      DropdownButton<String>(
                        value: _resolution,
                        items: const [
                          DropdownMenuItem(value: '1080p', child: Text('1080p (1920x1080)')),
                          DropdownMenuItem(value: '720p', child: Text('720p (1280x720)')),
                        ],
                        onChanged: (String? newValue) {
                          if (newValue != null) {
                            setState(() {
                              _resolution = newValue;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text('字體大小: ${_fontSize.toInt()}'),
                  Slider(
                    value: _fontSize,
                    min: 20,
                    max: 200,
                    divisions: 18,
                    label: _fontSize.toInt().toString(),
                    onChanged: (value) {
                      setState(() {
                        _fontSize = value;
                      });
                    },
                  ),
                  const Text('圖片預覽 (16:9 比例):'),
                  const SizedBox(height: 8),
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Container(
                      color: Colors.black,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        _textController.text,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: _fontSize / 4,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: _pickAudio,
                    icon: const Icon(Icons.audiotrack),
                    label: Text(_audioName == null ? '選擇音檔' : '重選音檔'),
                  ),
                  if (_audioName != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text('已選音檔: $_audioName', textAlign: TextAlign.center),
                    ),
                  const SizedBox(height: 30),
                  const Divider(),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    onPressed: _generateVideo,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: const Text('開始生成影片', style: TextStyle(fontSize: 18)),
                  ),
                  const SizedBox(height: 20),
                  Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
                ],
              ),
            ),
    );
  }
}
