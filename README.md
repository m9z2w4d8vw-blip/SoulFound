# SoulFound

A download-only Soulseek client for iPhone. Search and download files from the Soulseek network directly to your phone — no computer needed.

## Status

🚧 Work in progress

- [x] Project structure + CI
- [ ] Login
- [ ] Search
- [ ] Download

## Install

### TrollStore (iOS 17.0 only)
1. Download `SoulFound.ipa` from [Releases](../../releases)
2. Open it on your iPhone and select TrollStore
3. Tap Install

### AltStore (iOS 17.0+)
1. Add this source to AltStore: `https://m9z2w4d8vw-blip.github.io/SoulFound/altstore-source.json`
2. Find SoulFound in the Browse tab and install

## Build from source

Push a tag to trigger a GitHub Actions build:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The IPA will appear under Releases automatically.

## Protocol reference

- [Nicotine+ Soulseek Protocol Docs](https://nicotine-plus.org/doc/SLSKPROTOCOL.html)
- [aioslsk flow documentation](https://aioslsk.readthedocs.io/en/latest/SOULSEEK.html)
