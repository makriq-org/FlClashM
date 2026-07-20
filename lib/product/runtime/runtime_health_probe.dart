abstract interface class RuntimeHealthProbe {
  Future<bool> hasDeviceNetwork();

  Future<bool> testDelay({required String proxyName, required List<Uri> urls});

  Future<List<List<String>>> activeConnectionChains();

  Future<Map<String, String>> selectedProxies(List<String> groupNames);
}
