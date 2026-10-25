import 'dart:convert';
import 'lib.dart';
class ProductCoreQueries {
 Future<Map<String,dynamic>> tunnelHTTPRequest(Map<String,dynamic> params) async => Map<String,dynamic>.from(await clashLib!.invokeAction('tunnelHTTPRequest',jsonEncode(params)) as Map);
 Future<bool> cancelTunnelHTTPRequest(String requestId) async => await clashLib!.invokeAction('cancelTunnelHTTPRequest',requestId) == true;
 Future<String> getAppliedAndroidVpnOptions() async => await clashLib!.readAppliedVpnOptions();
 Future<Map<String,dynamic>> getRuntimeSnapshot() async => Map<String,dynamic>.from(await clashLib!.invokeAction('getRuntimeSnapshot',null) as Map);
}
final clashCore=ProductCoreQueries();
