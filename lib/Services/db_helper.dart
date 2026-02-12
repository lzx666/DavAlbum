import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DbHelper {
  static Database? _db;

  static Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    String path = join(await getDatabasesPath(), 'backup_records.db');
    return await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) {
        return db.execute(
          'CREATE TABLE uploaded_assets(asset_id TEXT PRIMARY KEY, thumbnail_path TEXT, create_time INTEGER, filename TEXT)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) {
        if (oldVersion < 2) {
          db.execute('ALTER TABLE uploaded_assets ADD COLUMN thumbnail_path TEXT');
        }
        if (oldVersion < 3) {
          try { db.execute('ALTER TABLE uploaded_assets ADD COLUMN create_time INTEGER'); } catch (_) {}
          try { db.execute('ALTER TABLE uploaded_assets ADD COLUMN filename TEXT'); } catch (_) {}
        }
      },
    );
  }

  static Future<String> getDbPath() async => join(await getDatabasesPath(), 'backup_records.db');

  static Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }

  static Future<void> markAsUploaded(String id, {String? thumbPath, int? time, String? filename}) async {
    final database = await db;
    await database.insert(
      'uploaded_assets',
      {'asset_id': id, 'thumbnail_path': thumbPath, 'create_time': time, 'filename': filename},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<Map<String, dynamic>>> getAllRecords() async {
    final database = await db;
    return await database.query('uploaded_assets', orderBy: 'create_time DESC');
  }

  static Future<bool> isUploaded(String id) async {
    final database = await db;
    final List<Map<String, dynamic>> maps = await database.query('uploaded_assets', where: 'asset_id = ?', whereArgs: [id]);
    return maps.isNotEmpty;
  }
}