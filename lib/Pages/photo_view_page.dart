import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../models/photo_item.dart';
import '../services/webdav_service.dart';

class PhotoViewer extends StatefulWidget {
  final List<PhotoItem> galleryItems;
  final int initialIndex;
  final WebDavService service;

  const PhotoViewer({super.key, required this.galleryItems, required this.initialIndex, required this.service});

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent, 
        elevation: 0, 
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.galleryItems.length,
        itemBuilder: (context, index) => _buildSinglePage(widget.galleryItems[index]),
      ),
    );
  }

  Widget _buildSinglePage(PhotoItem item) {
    return Center(
      child: FutureBuilder<File?>(
        future: _getBestImage(item),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
             return Column(
               mainAxisAlignment: MainAxisAlignment.center,
               children: const [
                 CircularProgressIndicator(color: Colors.white),
                 SizedBox(height: 10),
                 Text("正在下载原图...", style: TextStyle(color: Colors.white70))
               ],
             );
          }
          if (snap.hasData && snap.data != null) {
            return InteractiveViewer(child: Image.file(snap.data!, fit: BoxFit.contain));
          }
          return const Column(
             mainAxisAlignment: MainAxisAlignment.center,
             children: [
                Icon(Icons.broken_image, color: Colors.white54, size: 50),
                Text("加载失败", style: TextStyle(color: Colors.white54))
             ],
          );
        },
      ),
    );
  }

  Future<File?> _getBestImage(PhotoItem item) async {
    // 1. 如果本地相册里有，直接返回 (Asset)
    if (item.asset != null) {
      final file = await item.asset!.file;
      if (file != null && file.existsSync()) return file;
    }

    // 2. 如果是本地已删（只有数据库记录），或者 asset.file 拿不到
    // 检查本地缓存
    final appDir = await getTemporaryDirectory();
    // 使用 remoteFileName 或者 id 来做缓存文件名
    String fileName = item.remoteFileName ?? "${item.id}.jpg";
    if (!fileName.contains('.')) fileName += ".jpg";
    
    final localPath = '${appDir.path}/temp_full_$fileName';
    final file = File(localPath);

    // 3. 如果本地缓存有，直接用
    if (file.existsSync() && file.lengthSync() > 0) {
      return file;
    }

    // 4. 本地完全没有，开始下载
    try {
      await widget.service.downloadFile("MyPhotos/$fileName", localPath);
      return file;
    } catch (e) {
      print("Download error: $e");
      return null;
    }
  }
}