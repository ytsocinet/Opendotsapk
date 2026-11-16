/// Build #104: the Base URL guard accepts Tailscale addresses.
///
/// `isLocalHost` is the app-level half of the cleartext policy: plaintext
/// `http://` is allowed only to hosts it recognises as this device or the
/// local network. It covered loopback, the RFC1918 ranges, link-local and
/// mDNS — but not the CGNAT shared-address range `100.64.0.0/10` (RFC 6598)
/// that Tailscale assigns, so saving `http://100.71.192.20:11434/v1` was
/// refused on the phone with "Plaintext http:// is allowed only for a local
/// endpoint." A Tailscale address is private — only the user's own devices
/// can reach it — so it belongs in the list.
///
/// These are pure-function tests: no widget is pumped and no provider is
/// read, so the screen file's sqflite/connectivity dependencies are never
/// touched.
library;

import 'package:clawzilla/presentation/screens/cloud_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isLocalHost', () {
    test('accepts a Tailscale address', () {
      expect(isLocalHost('100.71.192.20'), isTrue);
    });

    test('accepts the 100.64.0.0/10 boundaries', () {
      expect(isLocalHost('100.64.0.1'), isTrue);
      expect(isLocalHost('100.127.255.255'), isTrue);
    });

    test('rejects just outside the 100.64.0.0/10 range', () {
      expect(isLocalHost('100.63.255.255'), isFalse);
      expect(isLocalHost('100.128.0.0'), isFalse);
    });

    test('still accepts the existing local ranges', () {
      expect(isLocalHost('localhost'), isTrue);
      expect(isLocalHost('127.0.0.1'), isTrue);
      expect(isLocalHost('::1'), isTrue);
      expect(isLocalHost('10.0.0.5'), isTrue);
      expect(isLocalHost('10.0.2.2'), isTrue);
      expect(isLocalHost('172.16.0.1'), isTrue);
      expect(isLocalHost('172.31.255.255'), isTrue);
      expect(isLocalHost('192.168.1.10'), isTrue);
      expect(isLocalHost('169.254.1.1'), isTrue);
      expect(isLocalHost('mybox.local'), isTrue);
    });

    test('still rejects public and just-outside addresses', () {
      expect(isLocalHost('8.8.8.8'), isFalse);
      expect(isLocalHost('172.32.0.1'), isFalse);
      expect(isLocalHost('example.com'), isFalse);
    });
  });

  group('baseUrlValidationError', () {
    test('allows the Tailscale Ollama URL', () {
      expect(
        baseUrlValidationError('http://100.71.192.20:11434/v1'),
        isNull,
      );
    });

    test('still rejects plaintext http to a public host', () {
      expect(
        baseUrlValidationError('http://8.8.8.8:11434/v1'),
        isNotNull,
      );
    });

    test('still allows https anywhere and an empty URL', () {
      expect(baseUrlValidationError('https://example.com/v1'), isNull);
      expect(baseUrlValidationError(''), isNull);
    });
  });
}
