/// The fastboot `product` value each selectable device should report.
///
/// The upstream launchers never check the product: they flash whatever is
/// connected. `flasher_web` checks it against the device the user selected,
/// so a package cannot be applied to a different phone. A value is only
/// recorded when a public observation of the bootloader's `getvar product`
/// exists; codenames from LineageOS or model numbers are not bootloader
/// products. Unknown entries make the plan take an explicit user override
/// instead of guessing.
library;

import 'model.dart';

/// How the recorded product was established.
enum ProductEvidence {
  /// A public `fastboot getvar all` log from the device.
  observedGetvar,

  /// No trustworthy observation; the plan requires the user's own value.
  unknown,
}

final class DeviceIdentity {
  const DeviceIdentity({
    required this.dev,
    required this.product,
    required this.evidence,
    required this.source,
  });

  final String dev;

  /// The expected `getvar product`, or null when unknown.
  final String? product;

  final ProductEvidence evidence;

  /// Where the value comes from, or what was checked when it is unknown.
  final String source;
}

/// `DEV_MAP` keys from upstream `build_tools.yml`, in workflow order.
///
/// Sources checked on 2026-11-06:
/// - OnePlus 13 (CPH2653/PJZ110): a public getvar log from a CPH2653 reports
///   `(bootloader) product:sun`
///   (https://xdaforums.com/t/solved-question-help-oneplus-13-cph2653-bootloop-on-oos-16-0-5-701-flashed-incompatible-kernel.4791171/).
///   LineageOS calls the device `dodge`
///   (https://wiki.lineageos.org/devices/dodge/), which is a build device
///   name, not the bootloader's product; do not use it here.
/// - OnePlus 13R: a OnePlus Community post snippet shows
///   `Product (Fastboot): ossi`
///   (https://community.oneplus.com/thread/2152579821438238721), but the page
///   is client-rendered and the claim could not be independently confirmed, so
///   the entry stays unknown.
/// - The remaining entries have no public getvar observation; searching XDA,
///   LineageOS and OnePlus/OPPO/realme sources on 2026-11-06 produced no
///   direct `product:` log. They stay unknown on purpose.
const Map<String, DeviceIdentity> deviceIdentities = {
  '13': DeviceIdentity(
    dev: '13',
    product: 'sun',
    evidence: ProductEvidence.observedGetvar,
    source: 'https://xdaforums.com/t/solved-question-help-oneplus-13-cph2653-bootloop-on-oos-16-0-5-701-flashed-incompatible-kernel.4791171/',
  ),
  '13R': DeviceIdentity(
    dev: '13R',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'OnePlus Community report says ossi; not independently confirmed.',
  ),
  '13S': DeviceIdentity(
    dev: '13S',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  '13T': DeviceIdentity(
    dev: '13T',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  '15': DeviceIdentity(
    dev: '15',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  '15R': DeviceIdentity(
    dev: '15R',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  '15T': DeviceIdentity(
    dev: '15T',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  'Ace5': DeviceIdentity(
    dev: 'Ace5',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  'Ace5Pro': DeviceIdentity(
    dev: 'Ace5Pro',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  'Ace6': DeviceIdentity(
    dev: 'Ace6',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  'Ace6T': DeviceIdentity(
    dev: 'Ace6T',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  'Pad2Pro': DeviceIdentity(
    dev: 'Pad2Pro',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  'Pad3': DeviceIdentity(
    dev: 'Pad3',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  'Pad3Pro': DeviceIdentity(
    dev: 'Pad3Pro',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  'GT7Pro': DeviceIdentity(
    dev: 'GT7Pro',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  'NEO8': DeviceIdentity(
    dev: 'NEO8',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
  'X9U': DeviceIdentity(
    dev: 'X9U',
    product: null,
    evidence: ProductEvidence.unknown,
    source: 'No public getvar product observation found.',
  ),
};

/// The product to require for [dev].
///
/// A known value wins; an override may repeat it but not replace it. When the
/// table is unknown, `answers['product']` must carry the value the phone
/// showed, and the expectation is marked as unverified so the confirmation says
/// so. Without that answer planning stops before any write.
DeviceExpectation resolveDeviceExpectation(
  String dev,
  Map<String, String> answers,
) {
  final identity = deviceIdentities[dev];
  if (identity == null) {
    throw FlashPlanException('Unknown device in the flasher tables: $dev');
  }
  final supplied = answers['product']?.trim() ?? '';
  final product = identity.product;
  if (product == null) {
    if (supplied.isEmpty) {
      throw FlashPlanException(
        'The fastboot product for $dev is not confirmed. Read it with '
        '`fastboot getvar product` and pass it in answers["product"].',
      );
    }
    return DeviceExpectation(
      dev: dev,
      product: supplied,
      confidence: 'unknown; user override',
      overrideText:
          'Product "$supplied" comes from the user, not a verified device '
          'table. Confirm the phone reports it before flashing.',
    );
  }
  if (supplied.isNotEmpty && supplied != product) {
    throw FlashPlanException(
      'The product override "$supplied" conflicts with the recorded product '
      '"$product" for $dev. Refusing to flash a mismatched device.',
    );
  }
  return DeviceExpectation(
    dev: dev,
    product: product,
    confidence: 'observed in a public getvar log',
  );
}
