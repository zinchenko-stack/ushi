# macOS release flow

## What this gives you

- `scripts/build-release-dmg.sh` builds `ushi.app`
- creates `ushi.dmg` for friends
- creates `ushi.zip`
- creates `latest-mac.json` for future in-app update checks

## Build a release

```bash
chmod +x scripts/build-release-dmg.sh
scripts/build-release-dmg.sh
```

Artifacts will appear in:

```bash
release/build/
```

## Generate public URLs in the update manifest

If you already know where the files will be hosted, pass `RELEASE_BASE_URL`:

```bash
RELEASE_BASE_URL="https://example.com/downloads" scripts/build-release-dmg.sh
```

This fills `release/build/latest-mac.json` with direct URLs to:

- `ushi.dmg`
- `ushi.zip`

## Suggested publishing flow

1. Run `scripts/build-release-dmg.sh`
2. Upload `release/build/ushi.dmg` to GitHub Releases or your landing-page storage
3. Upload `release/build/latest-mac.json` to the same public location
4. Link the landing page button to the DMG

## Notes

- This does not yet wire auto-updates into the app UI.
- `latest-mac.json` is only a release metadata file for the next step.
- For wider public distribution later, you will likely want signing/notarization.
