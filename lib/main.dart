import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
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
      title: '召會信息編輯',
      theme: ThemeData.dark(useMaterial3: true),
      home: const MainTabScreen(), 
    );
  }
}

// ==========================================
// 🌟 主畫面：負責管理底部的兩個分頁切換
// ==========================================
class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  int _currentIndex = 0;

  final List<Widget> _pages = [
    const VideoGenScreen(),  
    const AudioTrimScreen(), 
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.video_library),
            label: '文字轉影片',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.content_cut),
            label: '音影裁減 (MP3)',
          ),
        ],
        selectedItemColor: Colors.greenAccent,
      ),
    );
  }
}

// ==========================================
// 🌟 分頁一：文字轉影片 (任意輸入 FPS 版)
// ==========================================
class VideoGenScreen extends StatefulWidget {
  const VideoGenScreen({super.key});

  @override
  State<VideoGenScreen> createState() => _VideoGenScreenState();
}

class _VideoGenScreenState extends State<VideoGenScreen> {
  final TextEditingController _textController = TextEditingController(text: '測試測試');
  
  // 💡 新增：用來讓使用者自由輸入 FPS 的控制器
  final TextEditingController _fpsController = TextEditingController(text: '30'); 
  
  double _fontSize = 25.0; 
  String _resolution = '1080p';

  String? _audioPath;
  String? _audioName;
  
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('請輸入文字並選擇音檔')));
      return;
    }

    // 💡 驗證 FPS 欄位輸入的數字是否正確 (1 ~ 30)
    int fps = int.tryParse(_fpsController.text) ?? 30;
    if (fps < 1 || fps > 30) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ FPS 請輸入 1 到 30 之間的數字')));
      return;
    }

    final Uint8List? imageBytes = await _screenshotController.capture(
      delay: const Duration(milliseconds: 50),
      pixelRatio: 3.0, 
    );

    if (imageBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('圖片截取失敗，請再試一次')));
      return;
    }

    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _progressTime = '';
      _status = '圖片已擷取，正在分析音檔...';
    });

    try {
      double videoWidth = _resolution == '1080p' ? 1920 : 1280;
      double videoHeight = _resolution == '1080p' ? 1080 : 720;

      final tempDir = await getTemporaryDirectory();
      final imageFile = File('${tempDir.path}/text_image.png');
      await imageFile.writeAsBytes(imageBytes);

      double durationInSeconds = 0.0;
      try {
        final mediaInfo = await FFprobeKit.getMediaInformation(_audioPath!);
        final info = mediaInfo.getMediaInformation();
        if (info != null && info.getDuration() != null) {
          durationInSeconds = double.parse(info.getDuration()!);
        }
      } catch (e) {}
      int totalMs = (durationInSeconds * 1000).toInt();

      final appDocDir = await getApplicationDocumentsDirectory();
      final outputVideoPath = '${appDocDir.path}/output_video.mp4';
      if (await File(outputVideoPath).exists()) await File(outputVideoPath).delete();

      String filter = 'scale=${videoWidth.toInt()}:${videoHeight.toInt()}:force_original_aspect_ratio=decrease,pad=${videoWidth.toInt()}:${videoHeight.toInt()}:(ow-iw)/2:(oh-ih)/2:color=black';
      
      // 💡 動態調整關鍵影格 (GOP) 來達到最佳壓縮：FPS 若為 1 則用 300，其他則設定為 FPS 的兩倍
      int gopValue = (fps == 1) ? 300 : fps * 2;
      
      // 💡 終極極速版指令：保留 MPEG4 + Copy，並套用你自由輸入的 FPS
      final ffmpegCommand = '-loop 1 -framerate $fps -i ${imageFile.path} -i "$_audioPath" -vf "$filter" -c:v mpeg4 -q:v 31 -g $gopValue -c:a copy -pix_fmt yuv420p -shortest "$outputVideoPath"';

      FFmpegKit.executeAsync(
        ffmpegCommand,
        (session) async {
          final returnCode = await session.getReturnCode();
          if (ReturnCode.isSuccess(returnCode)) {
            bool hasPermission = await Gal.hasAccess();
            if (!hasPermission) hasPermission = await Gal.requestAccess();
            
            if (hasPermission) {
              await Gal.putVideo(outputVideoPath);
              if (mounted) setState(() => _status = '🎉 轉換成功！\n$fps FPS | MPEG4 極速版\n影片已保存');
            } else {
              if (mounted) setState(() => _status = '無相簿權限。\n影片存於: $outputVideoPath');
            }
          } else {
            final failStackTrace = await session.getFailStackTrace();
            if (mounted) setState(() => _status = '❌ 轉換失敗。\n$failStackTrace');
          }
          if (mounted) setState(() => _isProcessing = false);
        },
        (log) {}, 
        (Statistics statistics) {
          if (totalMs > 0) {
            int timeInMilliseconds = statistics.getTime();
            if (timeInMilliseconds > 0) {
              double percentage = timeInMilliseconds / totalMs;
              if (percentage > 1.0) percentage = 1.0;

              int currentSec = timeInMilliseconds ~/ 1000;
              int totalSec = totalMs ~/ 1000;
              String format(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

              if (mounted) {
                setState(() {
                  _progress = percentage;
                  _progressTime = '${format(currentSec)} / ${format(totalSec)}';
                  _status = '合併中... ${(percentage * 100).toStringAsFixed(1)}%';
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
      appBar: AppBar(title: const Text('文字轉靜態影片')),
      body: _isProcessing
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(30.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_progress > 0) ...[
                      LinearProgressIndicator(value: _progress, minHeight: 15, color: Colors.greenAccent),
                      const SizedBox(height: 15),
                      Text(_progressTime, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    ] else const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
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
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  
                  // 畫質選單
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('影片畫質:', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      DropdownButton<String>(
                        value: _resolution,
                        items: const [
                          DropdownMenuItem(value: '1080p', child: Text('1080p')),
                          DropdownMenuItem(value: '720p', child: Text('720p')),
                        ],
                        onChanged: (v) { if (v != null) setState(() => _resolution = v); },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  
                  // 💡 移除原本的編碼選單，把 FPS 變成自由輸入的文字框
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('影片幀率 (輸入 1~30):', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      SizedBox(
                        width: 80,
                        child: TextField(
                          controller: _fpsController,
                          keyboardType: TextInputType.number, // 彈出數字鍵盤
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),
                  Text('字體大小: ${_fontSize.toInt()}'),
                  Slider(
                    value: _fontSize,
                    min: 10,
                    max: 100,
                    divisions: 90,
                    onChanged: (value) => setState(() => _fontSize = value),
                  ),
                  const Text('所見即所得預覽:'),
                  const SizedBox(height: 8),
                  
                  Screenshot(
                    controller: _screenshotController,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Container(
                        color: Colors.black,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Text(
                              _textController.text,
                              style: TextStyle(
                                color: Colors.white, 
                                fontSize: _fontSize, 
                                fontWeight: FontWeight.bold,
                                height: 1.2, 
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
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
                    onPressed: _generateVideo,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)),
                    child: const Text('開始閃電生成', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 20),
                  Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
                ],
              ),
            ),
    );
  }
}

// ==========================================
// 🌟 分頁二：全新的「影音裁減 MP3」功能
// ==========================================
class AudioTrimScreen extends StatefulWidget {
  const AudioTrimScreen({super.key});

  @override
  State<AudioTrimScreen> createState() => _AudioTrimScreenState();
}

class _AudioTrimScreenState extends State<AudioTrimScreen> {
  final TextEditingController _startController = TextEditingController(text: '00:00:00');
  final TextEditingController _endController = TextEditingController(text: '00:01:30');
  
  String? _inputPath;
  String? _inputName;
  bool _isProcessing = false;
  String _status = '請選擇要裁減的檔案 (MP3 或 MP4 皆可)';

  Future<void> _pickFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result != null) {
        setState(() {
          _inputPath = result.files.single.path;
          _inputName = result.files.single.name;
          _status = '已選擇: $_inputName\n請設定裁減時間';
        });
      }
    } catch (e) {
      setState(() => _status = '選擇檔案失敗: $e');
    }
  }

  Future<void> _trimAudio() async {
    if (_inputPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('請先選擇檔案')));
      return;
    }

    setState(() {
      _isProcessing = true;
      _status = '正在光速裁減並轉成 MP3...';
    });

    try {
      final downloadsDir = Directory('/storage/emulated/0/Download');
      final outputFileName = '剪輯音檔_${DateTime.now().millisecondsSinceEpoch}.mp3';
      final outputPath = '${downloadsDir.path}/$outputFileName';

      if (await File(outputPath).exists()) {
        await File(outputPath).delete();
      }

      final command = '-ss ${_startController.text} -to ${_endController.text} -i "$_inputPath" -vn -c:a libmp3lame -b:a 192k "$outputPath"';

      await FFmpegKit.execute(command).then((session) async {
        final returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          setState(() {
            _status = '🎉 裁減成功！\n檔案已存入手機的「Download (下載)」資料夾\n檔名: $outputFileName';
          });
        } else {
          final failStackTrace = await session.getFailStackTrace();
          setState(() => _status = '❌ 裁減失敗。\n$failStackTrace');
        }
      });
    } catch (e) {
      setState(() => _status = '發生錯誤: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('音影裁減輸出 MP3')),
      body: _isProcessing
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('1. 選擇來源檔案', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    onPressed: _pickFile,
                    icon: const Icon(Icons.folder_open),
                    label: Text(_inputName == null ? '選擇 MP3 或 MP4' : '重新選擇'),
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
                  ),
                  if (_inputName != null) ...[
                    const SizedBox(height: 8),
                    Text('目前檔案: $_inputName', style: const TextStyle(color: Colors.greenAccent)),
                  ],
                  
                  const SizedBox(height: 30),
                  const Text('2. 設定擷取範圍 (時:分:秒)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _startController,
                          decoration: const InputDecoration(labelText: '開始時間', border: OutlineInputBorder()),
                          keyboardType: TextInputType.datetime,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text('至', style: TextStyle(fontSize: 16)),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _endController,
                          decoration: const InputDecoration(labelText: '結束時間', border: OutlineInputBorder()),
                          keyboardType: TextInputType.datetime,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 40),
                  ElevatedButton(
                    onPressed: _trimAudio,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orangeAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 15)
                    ),
                    child: const Text('開始裁減並輸出 MP3', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 20),
                  Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, height: 1.5)),
                ],
              ),
            ),
    );
  }
}
