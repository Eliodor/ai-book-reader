import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';

class AnxHttpProxyOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      final host = uri.host.toLowerCase();
      if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
        return 'DIRECT';
      }

      if (!Prefs().httpProxyEnabled) {
        return 'DIRECT';
      }

      final proxyHost = Prefs().httpProxyHost.trim();
      final proxyPort = Prefs().httpProxyPort;
      if (proxyHost.isEmpty || proxyPort <= 0) {
        return 'DIRECT';
      }

      return 'PROXY $proxyHost:$proxyPort; DIRECT';
    };
    return client;
  }
}
