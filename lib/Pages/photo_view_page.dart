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
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, iconTheme: const IconThemeData(color: Colors.white)),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.galleryItems.length,
        itemBuilder: (context, index) => _buildSinglePage(widget.galleryItems[index]),
      ),
    );
  }

  Widget _buildSinglePage(PhotoItem item) {
    return Center(
      child: FutureBuilder<File>(
        future: _getBestImage(item),
        builder: (context, snap) {
          if (snap.hasData) return InteractiveViewer(child: Image.file(snap.data!, fit: BoxFit.contain));
          if (snap.hasError) return const Icon(Icons.broken_image, color: Colors.white54, size: 50);
          return const CircularProgressIndicator(color: Colors.white);
        },
      ),
    );
  }

  Future<File> _getBestImage(PhotoItem item) async {
    if (item.asset != null) {
      final file = await item.asset!.file;
      if (file != null && file.existsSync()) return file;
    }
    final appDir = await getTemporaryDirectory();
    final localPath = '${appDir.path}/temp_${item.id}.jpg';
    final file = File(localPath);
    if (!file.existsSync() || file.lengthSync() == 0) {
      String fileName = item.remoteFileName ?? "${item.id}.jpg";
      if (!fileName.contains('.')) fileName += ".jpg";
      await widget.service.downloadFile("MyPhotos/$fileName", localPath);
    }
    return file;
  }
}