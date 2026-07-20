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
import 'package:shared_preferences/shared_preferences.dart';


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
// 🌟 主畫面
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
          BottomNavigationBarItem(icon: Icon(Icons.video_library), label: '文字轉影片'),
          BottomNavigationBarItem(icon: Icon(Icons.content_cut), label: '音影裁減 (MP3)'),
        ],
        selectedItemColor: Colors.greenAccent,
      ),
    );
  }
}

// ==========================================
// 🌟 分頁一：文字轉影片
// ==========================================
class VideoGenScreen extends StatefulWidget {
  const VideoGenScreen({super.key});

  @override
  State<VideoGenScreen> createState() => _VideoGenScreenState();
}

class _VideoGenScreenState extends State<VideoGenScreen> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _fpsController = TextEditingController(text: '2'); 
  final TextEditingController _fileNameController = TextEditingController();
  
  double _fontSize = 25.0; 
  String _resolution = '1080p';

  String? _audioPath;
  String? _audioName;
  
  bool _isProcessing = false;
  String _status = '準備就緒';
  double _progress = 0.0;
  String _progressTime = '';
  
  String _outputDir = '/storage/emulated/0/Download'; 
  final ScreenshotController _screenshotController = ScreenshotController();

  @override
  void initState() {
    super.initState();
    _loadSavedData(); 
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _outputDir = prefs.getString('video_output_dir') ?? '/storage/emulated/0/Download';
      _textController.text = prefs.getString('video_text') ?? '測試';
      _fileNameController.text = prefs.getString('video_filename') ?? '輸出影片';
    });
  }

  Future<void> _pickOutputDir() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('video_output_dir', selectedDirectory);
      setState(() {
        _outputDir = selectedDirectory;
      });
    }
  }

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

    int fps = int.tryParse(_fpsController.text) ?? 2;
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

      String baseName = _fileNameController.text.trim();
      if (baseName.isEmpty) baseName = '輸出影片';
      final outputVideoPath = '$_outputDir/$baseName.mp4';
      if (await File(outputVideoPath).exists()) await File(outputVideoPath).delete();

      String filter = 'scale=${videoWidth.toInt()}:${videoHeight.toInt()}:force_original_aspect_ratio=decrease,pad=${videoWidth.toInt()}:${videoHeight.toInt()}:(ow-iw)/2:(oh-ih)/2:color=black';
      int gopValue = (fps == 1) ? 300 : fps * 2;
      
      final ffmpegCommand = '-loop 1 -framerate $fps -i ${imageFile.path} -i "$_audioPath" -vf "$filter" -c:v mpeg4 -q:v 31 -g $gopValue -c:a copy -pix_fmt yuv420p -shortest "$outputVideoPath"';

      FFmpegKit.executeAsync(
        ffmpegCommand,
        (session) async {
          final returnCode = await session.getReturnCode();
          if (ReturnCode.isSuccess(returnCode)) {
            bool hasPermission = await Gal.hasAccess();
            if (!hasPermission) hasPermission = await Gal.requestAccess();
            if (hasPermission) await Gal.putVideo(outputVideoPath);
            
            if (mounted) setState(() => _status = '🎉 轉換成功！\n檔名: $baseName.mp4\n已存入:\n$_outputDir');
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
      appBar: AppBar(title: const Text('文字轉靜態影片 (Designed by Thomas)')),
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
                    onChanged: (val) async {
                      setState(() {}); 
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('video_text', val);
                    }
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('影片畫質:', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      DropdownButton<String>(
                        value: _resolution,
                        items: const [DropdownMenuItem(value: '1080p', child: Text('1080p')), DropdownMenuItem(value: '720p', child: Text('720p'))],
                        onChanged: (v) { if (v != null) setState(() => _resolution = v); },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('影片幀率 (輸入 1~30):', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      SizedBox(
                        width: 80,
                        child: TextField(
                          controller: _fpsController,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 8), border: OutlineInputBorder()),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text('字體大小: ${_fontSize.toInt()}'),
                  Slider(value: _fontSize, min: 10, max: 100, divisions: 90, onChanged: (value) => setState(() => _fontSize = value)),
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
                            child: Text(_textController.text, style: TextStyle(color: Colors.white, fontSize: _fontSize, fontWeight: FontWeight.bold, height: 1.2), textAlign: TextAlign.center),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(onPressed: _pickAudio, icon: const Icon(Icons.audiotrack), label: Text(_audioName == null ? '選擇音檔' : '重選音檔')),
                  if (_audioName != null) Padding(padding: const EdgeInsets.only(top: 8.0), child: Text('已選音檔: $_audioName', textAlign: TextAlign.center, style: const TextStyle(color: Colors.greenAccent))),
                  
                  const SizedBox(height: 20),
                  const Divider(),
                  
                  const Text('輸出檔名:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 5),
                  TextField(
                    controller: _fileNameController,
                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 12, horizontal: 10), border: OutlineInputBorder(), hintText: '請輸入檔案名稱'),
                    onChanged: (val) async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('video_filename', val);
                    },
                  ),
                  const SizedBox(height: 15),

                  const Text('輸出資料夾設定:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Expanded(child: Text(_outputDir, style: const TextStyle(color: Colors.grey, fontSize: 12), overflow: TextOverflow.ellipsis)),
                      ElevatedButton.icon(onPressed: _pickOutputDir, icon: const Icon(Icons.folder, size: 16), label: const Text('更改')),
                    ],
                  ),
                  const SizedBox(height: 20),

                  ElevatedButton(onPressed: _generateVideo, style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)), child: const Text('開始閃電生成', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  const SizedBox(height: 20),
                  Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
                ],
              ),
            ),
    );
  }
}

// ==========================================
// 🌟 分頁二：智慧無聲偵測 & 裁減 (含音質設定)
// ==========================================
class AudioTrimScreen extends StatefulWidget {
  const AudioTrimScreen({super.key});

  @override
  State<AudioTrimScreen> createState() => _AudioTrimScreenState();
}

class _AudioTrimScreenState extends State<AudioTrimScreen> {
  final TextEditingController _startController = TextEditingController(text: '00:00:00');
  final TextEditingController _endController = TextEditingController(text: '00:00:00'); 
  final TextEditingController _fileNameController = TextEditingController(); 
  
  String? _inputPath;
  String? _inputName;
  bool _isProcessing = false;
  String _status = '請選擇要處理的檔案';

  String _outputDir = '/storage/emulated/0/Download';
  
  // 💡 新增：音質變數
  String _audioBitrate = '64k'; 

  @override
  void initState() {
    super.initState();
    _loadSavedData();
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _outputDir = prefs.getString('audio_output_dir') ?? '/storage/emulated/0/Download';
      _fileNameController.text = prefs.getString('audio_filename') ?? '剪輯音檔';
      _audioBitrate = prefs.getString('audio_bitrate') ?? '64k'; // 讀取音質記憶
    });
  }

  Future<void> _pickOutputDir() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('audio_output_dir', selectedDirectory);
      setState(() {
        _outputDir = selectedDirectory;
      });
    }
  }

  String _formatDuration(double totalSeconds) {
    int hours = totalSeconds ~/ 3600;
    int minutes = (totalSeconds % 3600) ~/ 60;
    int seconds = (totalSeconds % 60).toInt();
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _pickFile() async {
    try {
      setState(() => _status = '正在請求系統開啟檔案總管...');
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.any);
      
      if (result != null) {
        setState(() {
          _inputPath = result.files.single.path;
          _inputName = result.files.single.name;
          _status = '正在讀取檔案總長度...'; 
        });

        try {
          final mediaInfo = await FFprobeKit.getMediaInformation(_inputPath!);
          final info = mediaInfo.getMediaInformation();
          if (info != null && info.getDuration() != null) {
            double duration = double.parse(info.getDuration()!);
            setState(() {
              _startController.text = '00:00:00';
              _endController.text = _formatDuration(duration);
              _status = '已選擇: $_inputName\n✅ 檔案總長度已自動填寫！';
            });
          } else {
            setState(() => _status = '已選擇: $_inputName\n(無法自動讀取長度，請手動輸入)');
          }
        } catch (e) {
          setState(() => _status = '已選擇: $_inputName\n(讀取長度失敗，請手動輸入)');
        }
      } else {
        setState(() => _status = '已取消選擇');
      }
    } catch (e) {
      setState(() => _status = '選擇檔案失敗: $e');
    }
  }

  int _timeToSeconds(String timeStr) {
    try {
      var parts = timeStr.split(':');
      if (parts.length == 3) {
        return int.parse(parts[0]) * 3600 + int.parse(parts[1]) * 60 + int.parse(parts[2]);
      }
    } catch (e) {}
    return 0;
  }

  Future<void> _smartSplitTrim() async {
    if (_inputPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('請先選擇檔案')));
      return;
    }

    int startSec = _timeToSeconds(_startController.text);
    int endSec = _timeToSeconds(_endController.text);
    int totalDuration = endSec - startSec;
    if (totalDuration <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('時間範圍錯誤')));
      return;
    }

    setState(() {
      _isProcessing = true;
      _status = '🔍 階段一：正在雷達掃描無聲區段...\n(90分鐘音檔大約需 1~2 分鐘，請耐心等候)';
    });

    try {
      String detectCmd = '-ss ${_startController.text} -t $totalDuration -i "$_inputPath" -af silencedetect=noise=-35dB:d=1.5 -f null -';
      final detectSession = await FFmpegKit.execute(detectCmd);
      final logs = await detectSession.getLogs();
      
      List<double> silencePoints = [];
      for (var log in logs) {
        final text = log.getMessage() ?? '';
        if (text.contains('silence_start:')) {
          try {
            final parts = text.split('silence_start:');
            final timeStr = parts[1].trim().split(' ')[0];
            silencePoints.add(double.parse(timeStr)); 
          } catch (e) {}
        }
      }

      setState(() {
        _status = '⚙️ 階段二：掃描完成，找到 ${silencePoints.length} 個無聲點！\n正在計算最佳 20 分鐘切割位置...';
      });

      List<double> splitTimes = [0.0];
      double currentTarget = 1200.0;
      
      while (currentTarget < totalDuration) {
        double bestPoint = currentTarget;
        double minDiff = 999999.0;
        
        for (double p in silencePoints) {
          if ((p - currentTarget).abs() < minDiff) {
            minDiff = (p - currentTarget).abs();
            bestPoint = p;
          }
        }
        
        if (minDiff > 300.0) {
          bestPoint = currentTarget;
        }
        
        splitTimes.add(bestPoint);
        currentTarget += 1200.0;
      }
      splitTimes.add(totalDuration.toDouble());

      String baseName = _fileNameController.text.trim();
      if (baseName.isEmpty) baseName = '剪輯音檔';

      for (int i = 0; i < splitTimes.length - 1; i++) {
        setState(() {
          _status = '🚀 階段三：正在輸出 Part ${i + 1} / ${splitTimes.length - 1} ...\n這會需要幾分鐘的時間';
        });

        double chunkRelativeStart = splitTimes[i];
        double chunkDuration = splitTimes[i + 1] - chunkRelativeStart;
        double absoluteStart = startSec + chunkRelativeStart; 
        
        String partName = (i + 1).toString();
        final outputPath = '$_outputDir/${baseName}part$partName.mp3';
        if (await File(outputPath).exists()) await File(outputPath).delete();

        // 💡 套用使用者選擇的碼率 (如 64k, 32k)
        String sliceCmd = '-ss $absoluteStart -t $chunkDuration -i "$_inputPath" -vn -ac 1 -c:a libmp3lame -b:a $_audioBitrate "$outputPath"';
        final sliceSession = await FFmpegKit.execute(sliceCmd);
        
        if (!ReturnCode.isSuccess(await sliceSession.getReturnCode())) {
          throw Exception('Part ${i + 1} 切割失敗');
        }
      }

      setState(() {
        _status = '🎉 智慧切割大成功！\n共切成 ${splitTimes.length - 1} 個檔案\n已全部存入:\n$_outputDir';
      });

    } catch (e) {
      setState(() => _status = '發生錯誤: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _normalTrim() async {
    if (_inputPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('請先選擇檔案')));
      return;
    }

    setState(() {
      _isProcessing = true;
      _status = '正在裁減並轉成單軌 MP3...';
    });

    try {
      String baseName = _fileNameController.text.trim();
      if (baseName.isEmpty) baseName = '剪輯音檔';
      
      final outputPath = '$_outputDir/$baseName.mp3';
      if (await File(outputPath).exists()) await File(outputPath).delete();

      // 💡 套用使用者選擇的碼率
      final command = '-ss ${_startController.text} -to ${_endController.text} -i "$_inputPath" -vn -ac 1 -c:a libmp3lame -b:a $_audioBitrate "$outputPath"';

      await FFmpegKit.execute(command).then((session) async {
        if (ReturnCode.isSuccess(await session.getReturnCode())) {
          setState(() => _status = '🎉 裁減成功！\n檔名: $baseName.mp3\n已存入:\n$_outputDir');
        } else {
          final failStackTrace = await session.getFailStackTrace();
          setState(() => _status = '❌ 處理失敗。\n$failStackTrace');
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
      appBar: AppBar(title: const Text('音影裁減輸出 MP3 (Designed by Thomas)')),
      body: _isProcessing
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, height: 1.5)),
                  ],
                ),
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
                      Expanded(child: TextField(controller: _startController, decoration: const InputDecoration(labelText: '開始時間', border: OutlineInputBorder()), keyboardType: TextInputType.datetime)),
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('至', style: TextStyle(fontSize: 16))),
                      Expanded(child: TextField(controller: _endController, decoration: const InputDecoration(labelText: '結束時間', border: OutlineInputBorder()), keyboardType: TextInputType.datetime)),
                    ],
                  ),

                  const SizedBox(height: 30),
                  const Divider(),
                  
                  const Text('3. 輸出設定', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  
                  // 💡 新增：音質下拉選單
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('輸出音質 (碼率):', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      DropdownButton<String>(
                        value: _audioBitrate,
                        items: const [
                          DropdownMenuItem(value: '128k', child: Text('128k (高品質/大檔)')),
                          DropdownMenuItem(value: '64k', child: Text('64k (清晰人聲/推薦)')),
                          DropdownMenuItem(value: '32k', child: Text('32k (極限壓縮/小檔)')),
                        ],
                        onChanged: (v) async {
                          if (v != null) {
                            setState(() => _audioBitrate = v);
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.setString('audio_bitrate', v);
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  TextField(
                    controller: _fileNameController,
                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 12, horizontal: 10), border: OutlineInputBorder(), hintText: '請輸入檔案名稱 (免打 .mp3)'),
                    onChanged: (val) async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('audio_filename', val);
                    },
                  ),
                  const SizedBox(height: 15),

                  const Text('輸出資料夾設定:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Expanded(child: Text(_outputDir, style: const TextStyle(color: Colors.grey, fontSize: 12), overflow: TextOverflow.ellipsis)),
                      ElevatedButton.icon(onPressed: _pickOutputDir, icon: const Icon(Icons.folder, size: 16), label: const Text('更改')),
                    ],
                  ),

                  const SizedBox(height: 30),
                  
                  ElevatedButton(
                    onPressed: _normalTrim,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 15)),
                    child: const Text('單純裁減一刀 (單軌瘦身)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 15),
                  
                  ElevatedButton(
                    onPressed: _smartSplitTrim,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)),
                    child: const Text('智慧無聲分割 (每20分/單軌瘦身)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  
                  const SizedBox(height: 20),
                  Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, height: 1.5)),
                ],
              ),
            ),
    );
  }
}
