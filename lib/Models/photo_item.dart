import 'package:photo_manager/photo_manager.dart';

class PhotoItem {
  final String id;
  final AssetEntity? asset;        
  final String? localThumbPath;    
  final String? remoteFileName;    
  final int createTime;            
  final bool isBackedUp;

  PhotoItem({
    required this.id, 
    this.asset, 
    this.localThumbPath, 
    this.remoteFileName,           
    required this.createTime, 
    this.isBackedUp = false
  });
}