/// Firmware family and package paths that cannot be inferred from the region.
///
/// Port of `flasher_builder/device_layout.py`.
library;

/// Whether this device/region uses a ColorOS template.
bool coloros(String dev, String region) => dev == 'X9U' || region == 'CN';

/// Template subtree name used by upstream's `flasher_scripts/<dev>/` tree.
String templateSubtree(String dev, String region) =>
    coloros(dev, region) ? 'cos' : 'oos';

/// Folder the flasher expects the extracted images in.
String imageFolder(String dev, String region) {
  if (dev == 'X9U') return 'OTA_FILES_HERE';
  return region == 'CN' ? 'COS_FILES_HERE' : 'OOS_FILES_HERE';
}
