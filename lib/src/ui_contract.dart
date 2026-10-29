import 'package:flutter/foundation.dart';

/// Presentation boundary. The network engine owns facts; the UI only renders
/// these stable codes and invokes explicit user actions.
abstract class LanPairController extends ChangeNotifier {
  bool get busy;
  bool get running;
  bool get hasSession;
  bool get canScan;
  String? get sessionId;
  String? get runId;
  String get localRole;
  String? get invitation;
  String? get errorCode;
  String? get errorDetail;
  double get progress;
  List<InterfaceView> get interfaces;
  String? get selectedInterface;
  List<ReadinessView> get readiness;
  List<ResultView> get results;
  List<HistoryView> get history;
  List<String> get exportAddresses;
  bool get peerJournalPresent;

  Future<void> createSession();
  Future<void> joinSession(String invitation);
  Future<void> importInvitation();
  Future<void> saveInvitation();
  Future<void> setManualPeer(String host, int port);
  Future<void> selectInterface(String name);
  Future<void> refreshReadiness();
  Future<void> openSettings();
  Future<void> startRun();
  Future<void> cancelRun();
  Future<void> importReport();
  Future<void> exportReport({
    required bool redact,
    required bool humanReadable,
    String Function(ReportExportView report)? formatReadableReport,
  });
  Future<void> openHistory(String id);
  void clearError();
}

/// Export content derived from the original or redacted journal before formatting.
class ReportExportView {
  const ReportExportView({
    required this.fields,
    required this.addresses,
    required this.results,
    required this.redacted,
  });
  final List<ReportFieldView> fields;
  final List<String> addresses;
  final List<ResultView> results;
  final bool redacted;
}

class InterfaceView {
  const InterfaceView({required this.name, required this.addresses});
  final String name;
  final List<String> addresses;
}

class ReadinessView {
  const ReadinessView({required this.code, required this.status, this.detail});
  final String code;
  final String status;
  final String? detail;
}

class ResultView {
  const ResultView({
    required this.id,
    required this.kind,
    required this.family,
    required this.direction,
    required this.status,
    required this.reason,
    this.observations = const [],
  });
  final String id;
  final String kind;
  final String family;
  final String direction;
  final String status;
  final String reason;
  final List<ObservationView> observations;
}

class ObservationView {
  const ObservationView({
    required this.code,
    required this.device,
    required this.elapsedMs,
    this.sequence,
    this.detail,
    this.wallTime,
    this.interfaceName,
    this.id,
  });
  final String code;
  final String device;
  final int elapsedMs;
  final int? sequence;
  final String? detail;
  final String? wallTime;
  final String? interfaceName;
  final String? id;
}

class ReportFieldView {
  const ReportFieldView({required this.label, required this.value});
  final String label;
  final String value;
}

class HistoryView {
  const HistoryView({
    required this.id,
    required this.sessionId,
    required this.runId,
    required this.savedAt,
    required this.observationCount,
    required this.merged,
  });
  final String id;
  final String sessionId;
  final String runId;
  final DateTime savedAt;
  final int observationCount;
  final bool merged;
}
