import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';

class WebDavService {
  final String url;
  final String user;
  final String pass;
  late Dio _dio;

  WebDavService({required this.url, required this.user, required this.pass}) {
    String cleanUrl = url.endsWith('/') ? url : '$url/';
    _dio = Dio(BaseOptions(
      baseUrl: cleanUrl,
      headers: {
        "Authorization": "Basic ${base64Encode(utf8.encode("$user:$pass"))}",
      },
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(minutes: 10),
    ));
  }

  Future<void> ensureFolder(String folderName) async {
    String path = folderName.endsWith('/') ? folderName.substring(0, folderName.length - 1) : folderName;
    try {
      await _dio.request(path, options: Options(method: "MKCOL"));
    } on DioException catch (e) {
      if (e.response?.statusCode != 405 && e.response?.statusCode != 301) {
        // 忽略文件夹已存在的错误
      }
    }
  }

  // --- 核心修复：添加获取云端文件列表的方法 ---
  Future<List<String>> listRemoteFiles(String folderPath) async {
    try {
      String path = folderPath.endsWith('/') ? folderPath : '$folderPath/';
      final response = await _dio.request(
        path,
        options: Options(
          method: "PROPFIND",
          headers: {"Depth": "1"},
        ),
      );

      if (response.statusCode == 207) {
        final String xml = response.data.toString();
        // 使用正则提取文件名
        final RegExp hrefReg = RegExp(r'<d:href[^>]*>([^<]+)<\/d:href>', caseSensitive: false);
        final matches = hrefReg.allMatches(xml);
        
        List<String> files = [];
        for (var m in matches) {
          String rawPath = m.group(1) ?? "";
          String decodedPath = Uri.decodeFull(rawPath);
          String name = decodedPath.split('/').last;
          
          // 过滤逻辑：排除当前目录、隐藏文件，只保留图片
          if (name.isNotEmpty && 
              name != path.split('/').last && 
              !name.startsWith('.') &&
              (name.toLowerCase().endsWith('.jpg') || name.toLowerCase().endsWith('.png') || name.toLowerCase().endsWith('.jpeg') || name.toLowerCase().endsWith('.heic'))) {
             files.add(name);
          }
        }
        return files;
      }
      return [];
    } catch (e) {
      print("List files error: $e");
      return [];
    }
  }

  Future<void> upload(File file, String remotePath) async {
    int len = await file.length();
    await _dio.put(remotePath, data: file.openRead(), options: Options(headers: {Headers.contentLengthHeader: len}));
  }

  Future<void> uploadBytes(Uint8List bytes, String remotePath) async {
    // 优化：直接传输 bytes 提高效率
    await _dio.put(remotePath, data: Stream.value(bytes), options: Options(headers: {Headers.contentLengthHeader: bytes.length}));
  }

  Future<void> downloadFile(String remotePath, String localPath) async {
    await _dio.download(remotePath, localPath);
  }
}