class SpotifyCredentials {
  final String accessToken;
  final int expirationTimestamp;
  final String spDcCookie;
  final String? spTCookie;
  final String? sapisid;
  final String? cookieString;

  SpotifyCredentials({
    required this.accessToken,
    required this.expirationTimestamp,
    required this.spDcCookie,
    this.spTCookie,
    this.sapisid,
    this.cookieString,
  });

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch > expirationTimestamp;

  factory SpotifyCredentials.fromJson(Map<String, dynamic> json) {
    return SpotifyCredentials(
      accessToken: json['accessToken'] ?? '',
      expirationTimestamp: json['expirationTimestamp'] ?? 0,
      spDcCookie: json['spDcCookie'] ?? '',
      spTCookie: json['spTCookie'],
      sapisid: json['sapisid'],
      cookieString: json['cookieString'],
    );
  }

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'expirationTimestamp': expirationTimestamp,
        'spDcCookie': spDcCookie,
        'spTCookie': spTCookie,
        'sapisid': sapisid,
        'cookieString': cookieString,
      };
}
