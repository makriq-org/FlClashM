import 'dart:convert';

import 'package:flclashx/common/exception.dart';
import 'package:flutter/foundation.dart';
import '../product/backend/backend.dart';

typedef ScriptEvaluator =
    Future<String> Function({required String script, required String config});

@visibleForTesting
ScriptEvaluator scriptEvaluator = evaluateScript;

Future<Map<String, dynamic>> handleEvaluate(
  String scriptContent,
  Map<String, dynamic> config,
) async {
  if (config['proxy-providers'] == null) {
    config['proxy-providers'] = {};
  }
  final String result;
  try {
    result = await scriptEvaluator(
      script: scriptContent,
      config: json.encode(config),
    );
  } catch (e) {
    throw MessageException(e.toString());
  }
  final decoded = json.decode(result);
  if (decoded is! Map<String, dynamic>) {
    throw const MessageException(
      'script did not return a configuration object',
    );
  }
  return decoded;
}

Future<String> evaluateScript({required String script,required String config}) async {
 final result=await backendClient.request('authoring.evaluate', {'script':script,'config':jsonDecode(config)});
 return jsonEncode((result as Map)['config']);
}
