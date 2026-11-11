/// Where the user is and what the temperature is, for the system prompt.
///
/// Free, no API key: Open-Meteo for the current temperature (Fahrenheit)
/// and Nominatim (OpenStreetMap) for the city/state name. Both calls are
/// cached for 30 minutes, and every failure returns null — the prompt just
/// omits the location line instead of breaking the send, and a denied
/// location permission means the line never appears at all.
library;

import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

class LocationWeatherService {
  static const _cacheTtl = Duration(minutes: 30);

  String? _cachedLine;
  DateTime? _cachedAt;

  /// A one-line summary for the system prompt, e.g.
  /// "You are in Indianapolis, Indiana. It is 45°F and cloudy."
  /// Returns the cached line when fresh, null when unavailable.
  Future<String?> getLine() async {
    if (_cachedLine != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return _cachedLine;
    }
    final line = await _fetchLine();
    if (line != null) {
      _cachedLine = line;
      _cachedAt = DateTime.now();
    }
    return line;
  }

  Future<String?> _fetchLine() async {
    try {
      final granted = await Permission.location.request().isGranted;
      if (!granted) return null;
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );
      final lat = position.latitude;
      final lon = position.longitude;
      final place = await _reverseGeocode(lat, lon);
      final weather = await _currentWeather(lat, lon);
      if (weather == null) return null;
      final placeText = place ?? 'your current location';
      return 'You are in $placeText. It is $weather.';
    } catch (_) {
      return null;
    }
  }

  /// City + state, e.g. "Indianapolis, Indiana". Null when the lookup fails.
  Future<String?> _reverseGeocode(double lat, double lon) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'lat': lat.toString(),
      'lon': lon.toString(),
      'format': 'json',
      'zoom': '10',
    });
    final res = await http
        .get(uri, headers: {'User-Agent': 'Clawzilla/1.0 (local agent)'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final address = json['address'] as Map<String, dynamic>?;
    if (address == null) return null;
    final city = address['city'] ??
        address['town'] ??
        address['village'] ??
        address['county'];
    final state = address['state'];
    if (city == null) return null;
    return state == null ? city.toString() : '$city, $state';
  }

  /// "45°F and cloudy", or null when the lookup fails.
  Future<String?> _currentWeather(double lat, double lon) async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': lat.toString(),
      'longitude': lon.toString(),
      'current': 'temperature_2m,weather_code',
      'temperature_unit': 'fahrenheit',
    });
    final res =
        await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final current = json['current'] as Map<String, dynamic>?;
    if (current == null) return null;
    final temp = (current['temperature_2m'] as num?)?.round();
    final code = current['weather_code'] as int?;
    if (temp == null || code == null) return null;
    return '$temp°F and ${_conditionFor(code)}';
  }

  /// WMO weather code to a plain word. Codes 0–99; anything unlisted is
  /// "cloudy" rather than a wrong guess.
  String _conditionFor(int code) {
    if (code == 0) return 'clear';
    if (code <= 2) return 'partly cloudy';
    if (code == 3) return 'overcast';
    if (code == 45 || code == 48) return 'foggy';
    if (code >= 51 && code <= 57) return 'drizzly';
    if (code >= 61 && code <= 67) return 'rainy';
    if (code >= 71 && code <= 77) return 'snowy';
    if (code >= 80 && code <= 82) return 'rainy';
    if (code >= 85 && code <= 86) return 'snowy';
    if (code == 95) return 'stormy';
    return 'cloudy';
  }
}
