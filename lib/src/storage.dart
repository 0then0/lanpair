import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'model.dart';
import 'report.dart';

class ReportStore {
  ReportStore(this.directory);
  final Directory directory;
  static Future<ReportStore> open() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/reports');
    await directory.create(recursive: true);
    return ReportStore(directory);
  }

  String id(RunReport report) => reportStorageKey(report);

  /// Synchronous atomic checkpoint is small and also usable during suspension.
  void save(RunReport report) {
    final name = id(report);
    final temporary = File('${directory.path}/$name.tmp');
    temporary.writeAsStringSync(ReportCodec.encode(report), flush: true);
    temporary.renameSync('${directory.path}/$name.json');
  }

  List<RunReport> list() {
    final reports = <RunReport>[];
    for (final entry in directory.listSync(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        if (entry.lengthSync() <= maxImportBytes) {
          reports.add(ReportCodec.decode(entry.readAsStringSync()));
        }
      } on FormatException {
        /* Preserve damaged file without loading it. */
      } on FileSystemException {
        /* File may be removed by the user. */
      }
    }
    reports.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return reports;
  }
}

String reportStorageKey(RunReport report) => sha256
    .convert(utf8.encode(jsonEncode([report.sessionId, report.runId])))
    .toString();
