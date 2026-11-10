# Carried third-party patches

A fix this repo needs that is not in a released package yet lives here as a
patch series, never as a git dependency on a fork: the app resolves the package
from pub.dev and bootstrap overrides it with the pinned commit plus the series.
It is the mechanism `squadron_process` uses for Squadron, generalized.

## Layout

```
third_party/<name>/PIN                     upstream repo, commit and package
third_party/<name>/patches/0001-*.patch    git format-patch series, applied in
                                           name order
```

`PIN` is `key=value` lines:

- `repo` — the upstream repository the commit lives in.
- `commit` — the full SHA of the release the series applies to.
- `package` — the package directory inside that repository; the
  `dependency_overrides` entry points at it.

`dart run tool/third_party.dart` (bootstrap runs it before the second
`flutter pub get`) fetches the commit into
`.dart_tool/third_party/<name>-<commit12>`, applies the series and writes
`<package name>: path: …` into the gitignored `pubspec_overrides.yaml`. A tree
whose stamp still matches the PIN and the patch bytes is reused; anything else
is rebuilt from the commit, so re-running it is safe. A directory without a
`PIN` is ignored, so the next carried patch is just a directory.

## file_picker

`file_picker_web` needs the file system access dialog on the web: `pickFile()`
hands back a handle a reload can reopen, and that handle is what an unfinished
save resumes into. Upstream only picks through `<input type="file">` and its
permission helpers only ask for `read`, so the series adds the dialog, the
handle store and `FilePermissionMode`.

The series is byte-identical to branch `web-file-system-access-handles` of
<https://github.com/p0g-stack/flutter_file_picker>, two commits on top of
`bf434d2`, so upstreaming it stays one pull request.

To refresh it after changing that branch:

```sh
git -C ~/Projects/tools/flutter_file_picker format-patch --no-signature \
  -o ~/Projects/p0g-stack/flasher_web/third_party/file_picker/patches \
  bf434d234fc2686843cca7eae74db943a31fa6a2..web-file-system-access-handles
dart run tool/third_party.dart
```

Delete the old `000N-*.patch` files the new series does not replace (a renamed
patch keeps both names), and set `commit=` in `PIN` to the new base commit when
the series moves to a newer release.
