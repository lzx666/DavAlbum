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
      headers: {"Authorization": "Basic ${base64Encode(utf8.encode("$user:$pass"))}"},
    ));
  }

  Future<void> ensureFolder(String folderName) async {
    try {
      await _dio.request(folderName, options: Options(method: "MKCOL"));
    } on DioException catch (e) {
      if (e.response?.statusCode != 405) rethrow; 
    }
  }

  Future<void> upload(File file, String remotePath) async {
    await _dio.put(remotePath, data: file.openRead(), options: Options(headers: {Headers.contentLengthHeader: await file.length()}));
  }

  Future<void> uploadBytes(Uint8List bytes, String remotePath) async {
    await _dio.put(remotePath, data: Stream.fromIterable(bytes.map((e) => [e])), options: Options(headers: {Headers.contentLengthHeader: bytes.length}));
  }

  Future<void> downloadFile(String remotePath, String localPath) async {
    await _dio.download(remotePath, localPath);
  }
}