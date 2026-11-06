/// The headers OnePlus's OTA CDN expects, as `remote_zip.HEADERS` sends them.
///
/// The edge worker's `/api/ota` route adds these itself; a direct range read
/// (the CLI) must send them too.
library;

const Map<String, String> otaRequestHeaders = {
  'User-Agent':
      'Dalvik/2.1.0 (Linux; U; Android 16; CPH2653 Build/AP3A.240617.008)',
  'userId': 'oplus-ota|15002017',
  'language': 'en-US',
  'brand': 'oneplus-exp',
};
