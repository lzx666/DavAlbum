import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'db_helper.dart';
import 'webdav_service.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
void main() => runApp(const MaterialApp(home: SuperBackupPage()));

class SuperBackupPage extends StatefulWidget {
  const SuperBackupPage({super.key});
  @override
  State<SuperBackupPage> createState() => _SuperBackupPageState();
}

class _SuperBackupPageState extends State<SuperBackupPage> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  String log = "等待操作...";
  bool isRunning = false;
  List<AssetEntity> _displayPhotos = []; // 用于在 UI 上显示的列表

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  _loadConfig() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _urlCtrl.text = p.getString('url') ?? "";
      _userCtrl.text = p.getString('user') ?? "";
      _passCtrl.text = p.getString('pass') ?? "";
    });
  }

  _saveConfig() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('url', _urlCtrl.text);
    await p.setString('user', _userCtrl.text);
    await p.setString('pass', _passCtrl.text);
  }

  void addLog(String m) => setState(() => log += "\n$m");

  Future<void> doBackup() async {
    if (isRunning) return;
    setState(() { isRunning = true; log = "🚀 开始任务..."; });
    await _saveConfig();

    try {
      final service = WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text);
      if (!(await Permission.photos.request().isGranted)) return addLog("❌ 无相册权限");

      addLog("检查远程文件夹...");
      await service.ensureFolder("MyPhotos/");

      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(type: RequestType.image);
      if (albums.isNotEmpty) {
        // 这里扫描最近的 100 张照片显示在 UI 上
        final List<AssetEntity> photos = await albums.first.getAssetListPaged(page: 0, size: 100);
        
        setState(() { _displayPhotos = photos; });

        int count = 0;
        for (var asset in photos) {
          if (await DbHelper.isUploaded(asset.id)) continue;

          File? file = await asset.file;
          if (file == null) continue;

          String fileName = path.basename(file.path);
          addLog("正在传: $fileName");
          
          await service.upload(file, "MyPhotos/$fileName");
          await DbHelper.markAsUploaded(asset.id);
          count++;
          setState(() {}); // 每传完一张刷新一次，让小绿勾跳出来
        }
        addLog("✅ 完成！本次新增 $count 张");
      }
    } catch (e) {
      addLog("❌ 失败: $e");
    } finally {
      setState(() => isRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("WebDAV 云相册")),
      body: Column(
        children: [
          // 1. 顶部折叠栏：存放配置和日志，节省空间
          ExpansionTile(
            title: const Text("服务器设置 & 运行日志"),
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    TextField(controller: _urlCtrl, decoration: const InputDecoration(labelText: "WebDAV 地址")),
                    TextField(controller: _userCtrl, decoration: const InputDecoration(labelText: "用户名")),
                    TextField(controller: _passCtrl, decoration: const InputDecoration(labelText: "密码"), obscureText: true),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: isRunning ? null : doBackup, 
                      child: Text(isRunning ? "正在同步..." : "开始一键增量备份")
                    ),
                    const SizedBox(height: 10),
                    Container(
                      height: 100,
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      color: Colors.black12,
                      child: SingleChildScrollView(child: Text(log, style: const TextStyle(fontSize: 10))),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // 2. 照片网格区域
          Expanded(
            child: _displayPhotos.isEmpty
                ? const Center(child: Text("暂无照片，请先点击备份按钮"))
                : GridView.builder(
                    padding: const EdgeInsets.all(4),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3, // 一行三张图
                      crossAxisSpacing: 4,
                      mainAxisSpacing: 4,
                    ),
                    itemCount: _displayPhotos.length,
                    itemBuilder: (context, index) {
                      final asset = _displayPhotos[index];
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          // 显示缩略图
                          AssetEntityImage(
                            asset,
                            isOriginal: false,
                            thumbnailSize: const ThumbnailSize.square(200),
                            fit: BoxFit.cover,
                          ),
                          // 状态图标：去数据库查这张图传过没
                          Positioned(
                            right: 4,
                            top: 4,
                            child: FutureBuilder<bool>(
                              future: DbHelper.isUploaded(asset.id),
                              builder: (context, snapshot) {
                                if (snapshot.data == true) {
                                  return const Icon(Icons.cloud_done, color: Colors.green, size: 24);
                                }
                                return const SizedBox();
                              },
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}