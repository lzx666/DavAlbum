import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import '../models/photo_item.dart';
import '../services/webdav_service.dart';
import '../services/db_helper.dart';

class SmartThumbnail extends StatefulWidget {
  final PhotoItem item;
  final WebDavService service;
  const SmartThumbnail({super.key, required this.item, required this.service});

  @override
  State<SmartThumbnail> createState() => _SmartThumbnailState();
}

class _SmartThumbnailState extends State<SmartThumbnail> {
  File? _imageFile;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _checkAndLoad();
  }

  Future<void> _checkAndLoad() async {
    if (widget.item.asset != null) return;
    final appDir = await getApplicationDocumentsDirectory();
    final targetPath = '${appDir.path}/thumb_${widget.item.id}.jpg';
    final file = File(targetPath);
    if (file.existsSync()) {
      if (mounted) setState(() => _imageFile = file);
      return;
    }
    if (mounted) setState(() => _isLoading = true);
    try {
      String remoteName = widget.item.remoteFileName ?? "${widget.item.id}.jpg";
      if (!remoteName.contains('.')) remoteName += ".jpg";
      await widget.service.downloadFile("MyPhotos/.thumbs/$remoteName", targetPath);
      await DbHelper.markAsUploaded(widget.item.id, thumbPath: targetPath, time: widget.item.createTime, filename: widget.item.remoteFileName);
      if (mounted) setState(() { _imageFile = File(targetPath); _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.item.asset != null) {
      return FutureBuilder<Uint8List?>(
        future: widget.item.asset!.thumbnailDataWithSize(const ThumbnailSize(200, 200)),
        builder: (_, s) => s.hasData ? Image.memory(s.data!, fit: BoxFit.cover) : Container(color: Colors.grey[200]),
      );
    }
    if (_imageFile != null) return Image.file(_imageFile!, fit: BoxFit.cover);
    return Container(
      color: Colors.grey[200],
      child: _isLoading 
        ? const Center(child: SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))) 
        : const Icon(Icons.cloud_download, color: Colors.white),
    );
  }
}