import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart'; // 解析音檔長度
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart'; // 讀取進度
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
      // 💡 升級 1：全域深色模式！
      theme: ThemeData.dark(
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
  final TextEditingController _textController = TextEditingController(text: '測試測試');
  double _fontSize = 50.0;
  String _resolution = '1080p';
  String? _audioPath;
  String? _audioName;
  
  // 狀態管理
  bool _isProcessing = false;
  String _status = '準備就緒';
  double _progress = 0.0;
  String _progressTime = '';
  
  final ScreenshotController _screenshotController = ScreenshotController();

  Future<void> _pickAudio() async {
    try {
      setState(() => _status = '正在請求系統開啟檔案瀏覽器...');
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.any);

      if (result != null) {
        setState(() {
          _audioPath = result.files.single.path;
          _audioName = result.files.single.name;
          _status = '已選擇音檔: $_audioName';
        });
      } else {
        setState(() => _status = '已取消選擇檔案');
      }
    } catch (e) {
      setState(() => _status = '開啟檔案失敗: $e');
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
      _progress = 0.0;
      _progressTime = '';
      _status = '正在分析音檔與生成圖片...';
    });

    try {
      double videoWidth = _resolution == '1080p' ? 1920 : 1280;
      double videoHeight = _resolution == '1080p' ? 1080 : 720;

      // 生成圖片
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

      // 💡 升級 2：獲取音檔總長度 (FFprobe)
      double durationInSeconds = 0.0;
      try {
        final mediaInfo = await FFprobeKit.getMediaInformation(_audioPath!);
        final info = mediaInfo.getMediaInformation();
        if (info != null && info.getDuration() != null) {
          durationInSeconds = double.parse(info.getDuration()!);
        }
      } catch (e) {
        debugPrint('讀取音檔長度失敗: $e');
      }
      int totalMs = (durationInSeconds * 1000).toInt();

      final appDocDir = await getApplicationDocumentsDirectory();
      final outputVideoPath = '${appDocDir.path}/output_video.mp4';
      if (await File(outputVideoPath).exists()) await File(outputVideoPath).delete();

      // 💡 升級 3：使用專業 filter 防止變形 (等比縮放並補黑邊)
      String filter = 'scale=${videoWidth.toInt()}:${videoHeight.toInt()}:force_original_aspect_ratio=decrease,pad=${videoWidth.toInt()}:${videoHeight.toInt()}:(ow-iw)/2:(oh-ih)/2:color=black';
      final ffmpegCommand = '-loop 1 -i ${imageFile.path} -i "$_audioPath" -vf "$filter" -c:v mpeg4 -q:v 2 -c:a aac -b:a 192k -pix_fmt yuv420p -shortest "$outputVideoPath"';

      // 💡 升級 4：非同步執行並即時監聽進度
      FFmpegKit.executeAsync(
        ffmpegCommand,
        (session) async {
          // 完成時的回呼
          final returnCode = await session.getReturnCode();
          if (ReturnCode.isSuccess(returnCode)) {
            bool hasPermission = await Gal.hasAccess();
            if (!hasPermission) hasPermission = await Gal.requestAccess();
            
            if (hasPermission) {
              await Gal.putVideo(outputVideoPath);
              if (mounted) setState(() => _status = '🎉 轉換成功！影片已保存到相簿。\n畫質: $_resolution');
            } else {
              if (mounted) setState(() => _status = '轉換成功，但無相簿權限。\n影片存於: $outputVideoPath');
            }
          } else {
            final failStackTrace = await session.getFailStackTrace();
            if (mounted) setState(() => _status = '❌ 轉換失敗。\nERROR: $failStackTrace');
          }
          if (mounted) setState(() => _isProcessing = false);
        },
        (log) {}, // 忽略詳細日誌以節省效能
        (Statistics statistics) {
          // 📊 進度回報回呼
          if (totalMs > 0) {
            int timeInMilliseconds = statistics.getTime();
            if (timeInMilliseconds > 0) {
              double percentage = timeInMilliseconds / totalMs;
              if (percentage > 1.0) percentage = 1.0;

              int currentSec = timeInMilliseconds ~/ 1000;
              int totalSec = totalMs ~/ 1000;

              String formatTime(int seconds) {
                int m = seconds ~/ 60;
                int s = seconds % 60;
                return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
              }

              if (mounted) {
                setState(() {
                  _progress = percentage;
                  _progressTime = '${formatTime(currentSec)} / ${formatTime(totalSec)}';
                  _status = '正在合併影音... ${(percentage * 100).toStringAsFixed(1)}%';
                });
              }
            }
          }
        },
      );
    } catch (e) {
      setState(() {
        _status = '發生錯誤: $e';
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
                padding: const EdgeInsets.all(30.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 💡 升級 5：超精美進度條 UI
                    if (_progress > 0) ...[
                      LinearProgressIndicator(
                        value: _progress,
                        minHeight: 15,
                        borderRadius: BorderRadius.circular(10),
                        backgroundColor: Colors.grey[800],
                        color: Colors.greenAccent,
                      ),
                      const SizedBox(height: 15),
                      Text(
                        _progressTime,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 2),
                      ),
                      const SizedBox(height: 20),
                    ] else ...[
                      const CircularProgressIndicator(),
                      const SizedBox(height: 20),
                    ],
                    Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.grey)),
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
                    decoration: const InputDecoration(labelText: '輸入影片文字', border: OutlineInputBorder()),
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
                          if (newValue != null) setState(() => _resolution = newValue);
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
                    onChanged: (value) => setState(() => _fontSize = value),
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
                        style: TextStyle(color: Colors.white, fontSize: _fontSize / 4, fontWeight: FontWeight.bold),
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
                      child: Text('已選音檔: $_audioName', textAlign: TextAlign.center, style: const TextStyle(color: Colors.greenAccent)),
                    ),
                  const SizedBox(height: 30),
                  ElevatedButton(
                    onPressed: _generateVideo, // 已經被 _isProcessing 保護，不怕連按
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: const Text('開始生成影片', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 20),
                  Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
                ],
              ),
            ),
    );
  }
}
