/// Where the user is and what the temperature is, for the system prompt.
///
/// Free, no API key: Open-Meteo for the current temperature (Fahrenheit)
/// and Nominatim (OpenStreetMap) for the city/state name. Both calls are
/// cached for 10 minutes, and every failure returns null — the prompt then
/// says the location is unknown instead of breaking the send, and a denied
/// location permission means the line never appears at all.
///
/// The line is labeled, not prose — `LOCATION: ...` / `WEATHER: ...` —
///
/// because a small model asked "where am I?" used to answer with the time
/// from the date line when this line was missing or worded like a sentence.
/// Labels keep the two apart, and a line built from only half the lookups
/// (place without weather, or the reverse) still says something true
/// instead of dropping everything.
library;

import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

class LocationWeatherService {
  static const _cacheTtl = Duration(minutes: 10);

  String? _cachedLine;
  DateTime? _cachedAt;

  /// A labeled summary for the system prompt, e.g.
  /// "LOCATION: Indianapolis, Indiana\nWEATHER: 45°F and cloudy."
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

  /// The same line for coordinates the caller already has (the
  /// `get_location` tool): city and temperature, without another GPS fix.
  /// No caching here — the caller asked for this moment's answer.
  Future<String?> getLineAt(double lat, double lon) async {
    try {
      return await _lineFor(lat, lon);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _fetchLine() async {
    try {
      final granted = await Permission.location.request().isGranted;
      if (!granted) return null;
      final position = await _freshPosition();
      if (position == null) return null;
      return await _lineFor(position.latitude, position.longitude);
    } catch (_) {
      return null;
    }
  }

  /// A fresh GPS fix, or null. Medium accuracy used to be enough, but a
  /// coarse fix near a town boundary flips between two cities (Speedway
  /// vs Indianapolis), and the platform hands back its last-known position
  /// when it cannot get a fresh one — which is how the temperature ends up
  /// "way off": it is the temperature of wherever that old fix was. So the
  /// fix must be high-accuracy, bounded by a timeout, and no older than
  /// two minutes.
  Future<Position?> _freshPosition() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      if (DateTime.now().difference(position.timestamp) >
          const Duration(minutes: 2)) {
        return null;
      }
      return position;
    } catch (_) {
      return null;
    }
  }

  /// City + temperature for coordinates, from whichever lookup succeeds.
  /// Null only when both fail.
  Future<String?> _lineFor(double lat, double lon) async {
    final place = await _reverseGeocode(lat, lon);
    final weather = await _currentWeather(lat, lon);
    if (place == null && weather == null) return null;
    final parts = <String>[
      'LOCATION: ${place ?? 'your current location'}',
      if (weather != null) 'WEATHER: $weather',
    ];
    return parts.join('\n');
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
