import 'hosted.dart';
import 'model.dart';

/// Native builds have no same-origin hosted service.
HostedTransport createHostedTransport() {
  throw const FlashException(
    'Hosted flash builds are available in the browser only; this build has no '
    'same-origin hosted service.',
  );
}
