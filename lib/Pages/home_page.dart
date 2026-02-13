import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/photo_item.dart';
import '../services/db_helper.dart';
import '../services/webdav_service.dart';
import '../widgets/smart_thumbnail.dart';
import 'photo_view_page.dart';

class SuperBackupPage extends StatefulWidget {
  const SuperBackupPage({super.key});
  @override
  State<SuperBackupPage> createState() => _SuperBackupPageState();
}

class _SuperBackupPageState extends State<SuperBackupPage> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  
  final List<String> _logs = [];
  bool isRunning = false;
  Map<String, List<PhotoItem>> _groupedItems = {}; 
  final Set<String> _sessionUploadedIds = {};

  int _crossAxisCount = 4;
  double _scale = 1.0;
  int _pointerCount = 0;

  @override
  void initState() {
    super.initState();
    _startAutoTasks();
  }

  void addLog(String m) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, "${DateTime.now().hour}:${DateTime.now().minute} $m"); 
      if (_logs.length > 50) _logs.removeLast();
    });
  }

  Future<void> _startAutoTasks() async {
    await _loadConfig();
    if (_urlCtrl.text.isEmpty) return;
    _manageCache();
    await _syncCloudToLocal(); 
    doBackup(silent: true);
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlCtrl.text = prefs.getString('url') ?? "";
      _userCtrl.text = prefs.getString('user') ?? "";
      _passCtrl.text = prefs.getString('pass') ?? "";
    });
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('url', _urlCtrl.text);
    await prefs.setString('user', _userCtrl.text);
    await prefs.setString('pass', _passCtrl.text);
  }

  Future<void> _manageCache() async {
    try {
      final appDir = await getTemporaryDirectory();
      final files = appDir.listSync().whereType<File>().where((f) => p.basename(f.path).startsWith('temp_full_')).toList();
      int totalSize = 0;
      for (var f in files) {
        totalSize += await f.length();
      }
      if (totalSize > 200 * 1024 * 1024) {
        files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
        for (var f in files) f.deleteSync();
      }
    } catch (_) {}
  }

  Future<void> _refreshGallery() async {
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
    List<AssetEntity> localAssets = albums.isNotEmpty ? await albums.first.getAssetListPaged(page: 0, size: 5000) : [];
    Map<String, AssetEntity> localAssetMap = {for (var e in localAssets) e.id: e};
    
    final dbRecords = await DbHelper.getAllRecords();
    Map<String, PhotoItem> mergedMap = {};

    for (var row in dbRecords) {
      String id = row['asset_id'];
      mergedMap[id] = PhotoItem(
        id: id,
        asset: localAssetMap[id],
        localThumbPath: row['thumbnail_path'], 
        remoteFileName: row['filename'], 
        createTime: row['create_time'] ?? 0, 
        isBackedUp: true
      );
    }
    for (var asset in localAssets) {
      if (!mergedMap.containsKey(asset.id)) {
        mergedMap[asset.id] = PhotoItem(id: asset.id, asset: asset, createTime: asset.createDateTime.millisecondsSinceEpoch);
      }
    }

    var list = mergedMap.values.toList()..sort((a, b) => b.createTime.compareTo(a.createTime));
    Map<String, List<PhotoItem>> groups = {};
    DateTime now = DateTime.now();
    DateTime today = DateTime(now.year, now.month, now.day);
    DateTime yesterday = today.subtract(const Duration(days: 1));

    for (var item in list) {
      DateTime date = DateTime.fromMillisecondsSinceEpoch(item.createTime);
      DateTime itemDay = DateTime(date.year, date.month, date.day);
      String key;
      if (itemDay == today) key = "今天";
      else if (itemDay == yesterday) key = "昨天";
      else key = "${date.year}年${date.month}月${date.day}日";
      groups.putIfAbsent(key, () => []).add(item);
    }
    if (mounted) setState(() => _groupedItems = groups);
  }

  // --- 💡 核心修复：从文件名解析时间戳 ---
  Future<void> _syncCloudToLocal() async {
    if (isRunning) return;
    try {
      final service = WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text);
      List<String> cloudFiles = await service.listRemoteFiles("MyPhotos/");
      if (cloudFiles.isEmpty) return;
      
      final dbRecords = await DbHelper.getAllRecords();
      final localKnownFiles = dbRecords.map((e) => e['filename'] as String?).toSet();
      final appDir = await getApplicationDocumentsDirectory();
      bool hasNewData = false;

      for (String fileName in cloudFiles) {
        if (!localKnownFiles.contains(fileName)) {
          hasNewData = true;
          
          // 解析文件名中的毫秒时间戳
          int photoTime;
          try {
            String timestampPart = fileName.split('_')[0];
            photoTime = int.parse(timestampPart);
          } catch (_) {
            photoTime = DateTime.now().millisecondsSinceEpoch; // 降级处理
          }

          String vId = "cloud_${fileName.hashCode}";
          String tPath = '${appDir.path}/thumb_$vId.jpg';
          if (!File(tPath).existsSync()) {
            try { 
              await service.downloadFile("MyPhotos/.thumbs/$fileName", tPath); 
            } catch (_) { 
              continue; 
            }
          }
          // 存入数据库，使用解析出的原始时间
          await DbHelper.markAsUploaded(vId, thumbPath: tPath, time: photoTime, filename: fileName);
        }
      }
      if (hasNewData && mounted) _refreshGallery();
    } catch (_) {}
  }

  // --- 💡 核心修复：上传时在文件名中嵌入时间戳 ---
  Future<void> doBackup({bool silent = false}) async {
    if (isRunning) return;
    setState(() => isRunning = true);
    await _saveConfig();
    try {
      if (Platform.isAndroid) {
        final ps = await PhotoManager.requestPermissionExtend();
        if (!ps.isAuth) return;
      } else {
        if (!(await Permission.photos.request().isGranted)) return;
      }

      final service = WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text);
      await service.ensureFolder("MyPhotos/");
      await service.ensureFolder("MyPhotos/.thumbs/");
      final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
      
      if (albums.isNotEmpty) {
        final photos = await albums.first.getAssetListPaged(page: 0, size: 200);
        final appDir = await getApplicationDocumentsDirectory();
        for (var asset in photos) {
          if (await DbHelper.isUploaded(asset.id)) continue;
          File? file = await asset.file;
          if (file == null) continue;

          // 使用毫秒时间戳作为文件名前缀
          int timestamp = asset.createDateTime.millisecondsSinceEpoch;
          String originalName = p.basename(file.path);
          String cloudFileName = "${timestamp}_$originalName";

          if (!silent) addLog("正在备份: $originalName");
          
          await service.upload(file, "MyPhotos/$cloudFileName");
          
          final thumbData = await asset.thumbnailDataWithSize(const ThumbnailSize(300, 300));
          String? tPath;
          if (thumbData != null) {
            await service.uploadBytes(thumbData, "MyPhotos/.thumbs/$cloudFileName");
            final tFile = File('${appDir.path}/thumb_${asset.id}.jpg')..writeAsBytesSync(thumbData);
            tPath = tFile.path;
          }
          await DbHelper.markAsUploaded(asset.id, thumbPath: tPath, time: timestamp, filename: cloudFileName);
          if (mounted) setState(() => _sessionUploadedIds.add(asset.id));
        }
      }
    } catch (e) {
      addLog("备份失败: $e");
    } finally { 
      if (mounted) { 
        setState(() => isRunning = false); 
        _refreshGallery(); 
      } 
    }
  }

  // --- 手势与UI渲染 ---
  void _handleScaleEnd() {
    int newCount = _crossAxisCount;
    if (_scale > 1.2) newCount--; 
    else if (_scale < 0.8) newCount++; 
    newCount = newCount.clamp(2, 6);
    if (newCount != _crossAxisCount) HapticFeedback.selectionClick();
    setState(() { _crossAxisCount = newCount; _scale = 1.0; });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      floatingActionButton: isRunning 
          ? null 
          : FloatingActionButton.extended(
              onPressed: () => doBackup(silent: false),
              icon: const Icon(Icons.backup_outlined),
              label: const Text("立即备份"),
            ),
      body: Listener(
        onPointerDown: (_) => setState(() => _pointerCount++),
        onPointerUp: (_) => setState(() => _pointerCount--),
        onPointerCancel: (_) => setState(() => _pointerCount = 0),
        child: GestureDetector(
          onScaleUpdate: (d) { if (_pointerCount >= 2) setState(() => _scale = d.scale.clamp(0.5, 2.0)); },
          onScaleEnd: (_) => _handleScaleEnd(),
          child: Transform.scale(
            scale: _scale,
            child: CustomScrollView(
              physics: (_pointerCount >= 2 || _scale != 1.0) ? const NeverScrollableScrollPhysics() : const BouncingScrollPhysics(),
              slivers: [
                SliverAppBar(
                  pinned: true,
                  floating: true,
                  snap: true,
                  backgroundColor: theme.colorScheme.surface,
                  surfaceTintColor: theme.colorScheme.surfaceTint,
                  title: const Text("相册", style: TextStyle(fontWeight: FontWeight.bold)),
                  actions: [
                    IconButton(onPressed: _syncCloudToLocal, icon: const Icon(Icons.sync)),
                    IconButton(onPressed: _showSettingsPanel, icon: const Icon(Icons.account_circle_outlined)),
                    const SizedBox(width: 8),
                  ],
                ),
                if (isRunning) const SliverToBoxAdapter(child: LinearProgressIndicator()),
                if (_logs.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                      child: Text(_logs.first, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                    ),
                  ),
                ..._buildMD3Content(theme),
                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildMD3Content(ThemeData theme) {
    List<Widget> slivers = [];
    _groupedItems.forEach((date, items) {
      slivers.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Text(date, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
        ),
      ));
      slivers.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _crossAxisCount, 
            crossAxisSpacing: 8, 
            mainAxisSpacing: 8
          ),
          delegate: SliverChildBuilderDelegate(
            (_, i) => _buildMD3PhotoTile(items[i], items, i, theme), 
            childCount: items.length
          ),
        ),
      ));
    });
    return slivers;
  }

  Widget _buildMD3PhotoTile(PhotoItem item, List<PhotoItem> group, int index, ThemeData theme) {
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoViewer(
        galleryItems: group, 
        initialIndex: index, 
        service: WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text)))),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            SmartThumbnail(item: item, service: WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text)),
            if (item.isBackedUp)
              Positioned(
                top: 8, right: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: theme.colorScheme.primaryContainer.withOpacity(0.8), shape: BoxShape.circle),
                  child: Icon(item.asset == null ? Icons.cloud_outlined : Icons.done, size: 14, color: theme.colorScheme.onPrimaryContainer),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showSettingsPanel() {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => Container(
        padding: EdgeInsets.fromLTRB(24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("连接设置", style: theme.textTheme.headlineSmall),
            const SizedBox(height: 24),
            TextField(controller: _urlCtrl, decoration: const InputDecoration(labelText: "WebDAV URL", border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _userCtrl, decoration: const InputDecoration(labelText: "用户名", border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _passCtrl, decoration: const InputDecoration(labelText: "密码", border: OutlineInputBorder()), obscureText: true),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () { Navigator.pop(context); doBackup(silent: false); },
                child: const Text("保存并备份"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}