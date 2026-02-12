import 'dart:io';
import 'package:flutter/material.dart';
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
  
  List<String> _logs = [];
  bool isRunning = false;
  Map<String, List<PhotoItem>> _groupedItems = {}; 
  int _crossAxisCount = 3; 
  int _startColCount = 3; 
  final Set<String> _sessionUploadedIds = {};

  @override
  void initState() {
    super.initState();
    _startAutoTasks();
  }

  // --- 逻辑函数 (管理配置、备份等) ---
  Future<void> _startAutoTasks() async {
    await _loadConfig();
    if (_urlCtrl.text.isEmpty) return;
    _manageCache();
    await _syncDatabase(isRestore: true, silent: true);
    doBackup(silent: true);
  }

  _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlCtrl.text = prefs.getString('url') ?? "";
      _userCtrl.text = prefs.getString('user') ?? "";
      _passCtrl.text = prefs.getString('pass') ?? "";
    });
  }

  _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('url', _urlCtrl.text);
    await prefs.setString('user', _userCtrl.text);
    await prefs.setString('pass', _passCtrl.text);
  }

  void addLog(String m) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, "${DateTime.now().hour}:${DateTime.now().minute} $m"); 
      if (_logs.length > 50) _logs.removeLast();
    });
  }

  Future<void> _manageCache() async {
    try {
      final appDir = await getTemporaryDirectory();
      final files = appDir.listSync().whereType<File>().where((f) => p.basename(f.path).startsWith('temp_')).toList();
      int totalSize = 0;
      for (var f in files) totalSize += await f.length();
      if (totalSize > 100 * 1024 * 1024) {
        files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
        for (var f in files) f.deleteSync();
      }
    } catch (_) {}
  }

  Future<void> _refreshGallery() async {
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
    List<AssetEntity> localAssets = albums.isNotEmpty ? await albums.first.getAssetListPaged(page: 0, size: 500) : [];
    final dbRecords = await DbHelper.getAllRecords();
    
    Map<String, PhotoItem> mergedMap = {};
    for (var row in dbRecords) {
      mergedMap[row['asset_id']] = PhotoItem(id: row['asset_id'], localThumbPath: row['thumbnail_path'], remoteFileName: row['filename'], createTime: row['create_time'] ?? 0, isBackedUp: true);
    }
    for (var asset in localAssets) {
      bool backed = mergedMap.containsKey(asset.id);
      mergedMap[asset.id] = PhotoItem(id: asset.id, asset: asset, localThumbPath: backed ? mergedMap[asset.id]?.localThumbPath : null, remoteFileName: backed ? mergedMap[asset.id]?.remoteFileName : null, createTime: asset.createDateTime.millisecondsSinceEpoch, isBackedUp: backed);
    }

    var list = mergedMap.values.toList()..sort((a, b) => b.createTime.compareTo(a.createTime));
    Map<String, List<PhotoItem>> groups = {};
    for (var item in list) {
      String key = "${DateTime.fromMillisecondsSinceEpoch(item.createTime).year}年${DateTime.fromMillisecondsSinceEpoch(item.createTime).month}月"; 
      groups.putIfAbsent(key, () => []).add(item);
    }
    if (mounted) setState(() => _groupedItems = groups);
  }

  Future<void> _syncDatabase({bool isRestore = false, bool silent = false}) async {
    if (isRunning) return;
    setState(() => isRunning = true);
    try {
      final service = WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text);
      final dbPath = await DbHelper.getDbPath();
      if (isRestore) {
        await DbHelper.close();
        await service.downloadFile("MyPhotos/backup_records.db", dbPath);
        await _refreshGallery();
      } else {
        await service.upload(File(dbPath), "MyPhotos/backup_records.db");
      }
    } catch (_) {} finally { setState(() => isRunning = false); }
  }

  Future<void> doBackup({bool silent = false}) async {
    if (isRunning) return;
    setState(() => isRunning = true);
    await _saveConfig();
    try {
      if (!(await Permission.photos.request().isGranted)) return;
      final service = WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text);
      await service.ensureFolder("MyPhotos/");
      await service.ensureFolder("MyPhotos/.thumbs/");
      final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
      if (albums.isNotEmpty) {
        final photos = await albums.first.getAssetListPaged(page: 0, size: 50);
        final appDir = await getApplicationDocumentsDirectory();
        for (var asset in photos) {
          if (await DbHelper.isUploaded(asset.id)) continue;
          File? file = await asset.file;
          if (file == null) continue;
          String fileName = p.basename(file.path);
          await service.upload(file, "MyPhotos/$fileName");
          final thumbData = await asset.thumbnailDataWithSize(const ThumbnailSize(200, 200));
          String? localPath;
          if (thumbData != null) {
            await service.uploadBytes(thumbData, "MyPhotos/.thumbs/$fileName");
            final thumbFile = File('${appDir.path}/thumb_${asset.id}.jpg')..writeAsBytesSync(thumbData);
            localPath = thumbFile.path;
          }
          await DbHelper.markAsUploaded(asset.id, thumbPath: localPath, time: asset.createDateTime.millisecondsSinceEpoch, filename: fileName);
          setState(() => _sessionUploadedIds.add(asset.id));
        }
        await _syncDatabase(isRestore: false, silent: true);
      }
    } finally { setState(() => isRunning = false); _refreshGallery(); }
  }

  // --- UI 构建 ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      floatingActionButton: FloatingActionButton(
        onPressed: isRunning ? null : () => doBackup(),
        backgroundColor: isRunning ? Colors.grey : Colors.blueAccent,
        child: isRunning ? const CircularProgressIndicator(color: Colors.white) : const Icon(Icons.cloud_upload),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (_) => _startColCount = _crossAxisCount,
        onScaleUpdate: (d) {
          if (d.pointerCount >= 2) {
            final newCount = (_startColCount / d.scale).round().clamp(2, 6);
            if (newCount != _crossAxisCount) setState(() => _crossAxisCount = newCount);
          }
        },
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true, floating: true, expandedHeight: 100,
              backgroundColor: Colors.white,
              flexibleSpace: const FlexibleSpaceBar(title: Text("TimeAlbum", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold))),
              actions: [IconButton(icon: const Icon(Icons.settings, color: Colors.black87), onPressed: _showSettingsPanel)],
            ),
            ..._buildSliverContent(),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSliverContent() {
    List<Widget> slivers = [];
    _groupedItems.forEach((date, items) {
      slivers.add(SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 10), child: Text(date, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))));
      slivers.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: _crossAxisCount, crossAxisSpacing: 4, mainAxisSpacing: 4),
          delegate: SliverChildBuilderDelegate((_, i) => _buildPhotoTile(items[i], items, i), childCount: items.length),
        ),
      ));
    });
    return slivers;
  }

  Widget _buildPhotoTile(PhotoItem item, List<PhotoItem> group, int index) {
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoViewer(galleryItems: group, initialIndex: index, service: WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text)))),
      child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Stack(fit: StackFit.expand, children: [
        SmartThumbnail(item: item, service: WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text)),
        if (_sessionUploadedIds.contains(item.id)) Positioned(right: 5, top: 5, child: Icon(Icons.cloud_done, color: Colors.blue[300], size: 18)),
      ])),
    );
  }

  void _showSettingsPanel() {
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: _urlCtrl, decoration: const InputDecoration(labelText: "WebDAV URL")),
      TextField(controller: _userCtrl, decoration: const InputDecoration(labelText: "User")),
      TextField(controller: _passCtrl, decoration: const InputDecoration(labelText: "Pass"), obscureText: true),
      const SizedBox(height: 20),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        ElevatedButton(onPressed: () { Navigator.pop(context); doBackup(); }, child: const Text("立即备份")),
        ElevatedButton(onPressed: () { Navigator.pop(context); _syncDatabase(isRestore: true); }, child: const Text("恢复数据库")),
      ]),
    ])));
  }
}