import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

part 'src/billing.dart';
part 'src/purchases.dart';

class AplynaAssignment {
  final String flowId;
  final String? experimentId;
  final String variant;
  const AplynaAssignment(
      {required this.flowId,
      required this.experimentId,
      required this.variant});
  factory AplynaAssignment.fromJson(Map<String, dynamic> json) =>
      AplynaAssignment(
          flowId: json['flowId'] as String,
          experimentId: json['experimentId'] as String?,
          variant: json['variant'] as String);
  Map<String, dynamic> toJson() =>
      {'flowId': flowId, 'experimentId': experimentId, 'variant': variant};
}

/// One native client per host application. Tracking requires explicit consent.
class Aplyna {
  Aplyna._();

  /// Separate native store billing; does not configure analytics.
  static const billing = AplynaBilling._();
  static const _channel = MethodChannel('com.aplyna/sdk');
  static Future<dynamic> _invoke(String method,
      [Map<String, dynamic> args = const {}]) async {
    final response = await _channel.invokeMethod<String>(
        'invoke', {'method': method, 'argumentsJSON': jsonEncode(args)});
    if (response == null)
      throw const FormatException('Aplyna returned an empty native response.');
    return jsonDecode(response);
  }

  /// Returns a persisted anonymous installation ID. Consent starts false.
  static Future<String> configure(
      {required String apiKey,
      String baseUrl = 'https://aplyna.com',
      String? installationId}) async {
    final result = await _invoke('configure', {
      'baseUrl': baseUrl,
      'apiKey': apiKey,
      if (installationId != null) 'installationId': installationId
    });
    return (result as Map<String, dynamic>)['installationId'] as String;
  }

  static Future<void> setConsent(bool granted) async {
    await _invoke('setConsent', {'granted': granted});
  }

  /// Set the actual Flutter runtime language; null restores the native default.
  static Future<void> setAppLanguage(String? language) async {
    await _invoke('setAppLanguage', {'language': language});
  }

  /// iOS only: collect Apple Ads attribution after analytics consent.
  static Future<void> collectAppleAdsAttribution() async {
    await _invoke('collectAppleAdsAttribution');
  }

  /// iOS only: refresh after your ATT permission callback, then call flush.
  /// Does not request permission; Android does nothing.
  static Future<void> refreshTrackingAuthorizationStatus() async {
    await _invoke('refreshTrackingAuthorizationStatus');
  }

  static Future<void> track(String name,
      {String? flowId,
      String? stepId,
      AplynaAssignment? assignment,
      Map<String, String> properties = const {}}) async {
    await _invoke('track', {
      'name': name,
      if (flowId != null) 'flowId': flowId,
      if (stepId != null) 'stepId': stepId,
      if (assignment != null) 'assignment': assignment.toJson(),
      'properties': properties
    });
  }

  static Future<void> expose(AplynaAssignment assignment) async {
    await _invoke('expose', {'assignment': assignment.toJson()});
  }

  static Future<void> flush() async {
    await _invoke('flush');
  }

  static Future<int> pendingEventCount() async =>
      await _invoke('pendingEventCount') as int;
  static Future<AplynaAssignment> assignment(String flowId) async =>
      AplynaAssignment.fromJson(await _invoke('assignment', {'flowId': flowId})
          as Map<String, dynamic>);
  static Future<Map<String, dynamic>> configuration(String flowId) async =>
      await _invoke('configuration', {'flowId': flowId})
          as Map<String, dynamic>;
}
