# YTKACE

An open-source YouTube enhancement for iOS.

## Features

| Area | Included |
|---|---|
| Downloads | Video, audio, Shorts and whole-playlist downloads; save to the library, Photos or the share sheet; sorting; backup and restore |
| Queue | Play next or play last without Premium, with reorder, swipe to remove, shuffle, loop and clear |
| Playback | Background playback, PiP, loop, speed controls, default speed, gestures, tap to seek and an HLS playback mode |
| SponsorBlock | Category controls, progress markers, skip modes and configurable alerts |
| Interface | OLED mode, overlay controls, navigation cleanup and native share sheets |
| Liquid Glass | Glass tab bar, top bar buttons, menus, sheets, player buttons and YTKACE popups on iOS 26, with shrink on scroll and a selected tab color |
| Tabs | Hide, reorder and add YouTube destinations |
| Library | Downloaded video, Shorts and audio players with resume support |
| Translation | Voice-over translation (VOT) powered by [r3tok](https://t.me/r3tok) |
| Settings | Searchable settings, 15 languages and a native YouTube settings section |

## Compatibility

- **iOS:** 15.0 and newer (tweak packages); the prebuilt IPAs follow their YouTube base
- **Architecture:** arm64
- **YTKACE:** 1.1.3

YouTube 21.41.5 requires iOS 17, so two IPAs are published:

| IPA | YouTube base | iOS |
| --- | --- | --- |
| `YTKACE_1.1.3_YouTube_iOS16_21.33.6.ipa` | 21.33.6 | 16.0 and newer |
| `YTKACE_1.1.3_YouTube_21.41.5.ipa` | 21.41.5 | 17.0 and newer |

Pick the 21.41.5 build unless you are on iOS 16. Either one installs with TrollStore or a developer-certificate sideloader.

## Install

**Jailbroken.** Add the repository in Sileo, Zebra or Cydia:

```
https://itzzace.github.io/ytkace/
```

Rootless and roothide packages are both published. The repository page also has an
[Add to Sileo](https://itzzace.github.io/ytkace/) button.

**Sideloaded.** Download the IPA for your iOS version from the [latest release](https://github.com/itzzace/ytkace/releases/latest) and install it with TrollStore, AltStore, SideStore or LiveContainer.

## Build

Fork the repository, enable Actions, open the **IPA** workflow and provide a direct link to a decrypted YouTube IPA you are legally allowed to use. The completed workflow provides the injected IPA as an artifact. The **Deb** workflow builds the tweak package.

To build both IPAs in one run, fill in the second URL field as well: the workflow takes an iOS 16 base (21.33.6) and an optional iOS 17+ base (21.41.5), and uploads them as separate artifacts. Leaving the second field empty builds a single IPA.

## Settings

Open the YTKACE tab and tap the gear, or open YouTube Settings and choose YTKACE.
Both pages carry the same options, and the YouTube Settings section has a search bar.

## Screenshots

<p align="center">
  <img src="screenshots/framed/settings.png" width="220" alt="YTKACE settings">
  <img src="screenshots/framed/video-download-menu.png" width="220" alt="Video download menu">
  <img src="screenshots/framed/audio-player.png" width="220" alt="Audio player">
</p>

<p align="center">
  <sub>Settings · Downloads · Audio Player</sub>
</p>

<p align="center">
  <img src="screenshots/framed/glass-menu.png" width="220" alt="Liquid Glass menu">
  <img src="screenshots/framed/glass-quality-sheet.png" width="220" alt="Liquid Glass quality sheet">
  <img src="screenshots/framed/glass-download.png" width="220" alt="Liquid Glass download progress">
</p>

<p align="center">
  <sub>Liquid Glass · Menus · Sheets · Tab Bar</sub>
</p>

<details>
  <summary>More screenshots</summary>
  <br>
  <p align="center">
    <img src="screenshots/framed/shorts-download-menu.png" width="190" alt="Shorts download menu">
    <img src="screenshots/framed/tab-editor.png" width="190" alt="Tab editor">
    <img src="screenshots/framed/download-progress.png" width="190" alt="Download progress">
  </p>
  <p align="center">
    <img src="screenshots/framed/download-library.png" width="190" alt="Download library">
    <img src="screenshots/framed/video-player.png" width="190" alt="Downloaded video player">
    <img src="screenshots/framed/player-settings.png" width="190" alt="Player settings">
  </p>
  <p align="center">
    <img src="screenshots/framed/sponsorblock-settings.png" width="190" alt="SponsorBlock settings">
    <img src="screenshots/framed/audio-queue.png" width="190" alt="Audio queue">
  </p>
  <p align="center">
    <img src="screenshots/framed/glass-settings.png" width="190" alt="Liquid Glass settings">
    <img src="screenshots/framed/glass-share-sheet.png" width="190" alt="Liquid Glass share sheet">
    <img src="screenshots/framed/glass-home.png" width="190" alt="Liquid Glass tab bar">
  </p>
</details>

## Privacy

YTKACE has no activation service, analytics, telemetry or updater.

## Notes

The playback fix that shipped after 0.8.0 was taken from another project without credit and has been removed. The current Playback Fix is adapted from Mark02's YTPlaybackFix under the MIT license and is credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). If you find anything else that isn't credited, open an issue and it will be credited or removed.

## Contributing

Contributions are welcome — issues and pull requests both help.

For bug reports, include your device, iOS version and YouTube version.

For pull requests, keep each one focused on a single change and match the
surrounding style. Two things worth knowing:

- Hooks are installed by name through the helpers in `Tweak/Runtime/Hooking.h`,
  not a hooking framework, so a missing class or selector fails quietly instead
  of crashing on older YouTube versions.
- New user-facing strings go through `YTKACELocalized` and belong in
  `Resources/YTKACE.bundle/en.lproj/Localizable.strings`. Translations for the
  other 14 languages can follow separately.

Build instructions are above.

## Donate

If YTKACE is useful to you, you can support it on [Ko-fi](https://ko-fi.com/itzzace) or with crypto:

- **BTC:** `bc1q6ahl2mghgq34r3w26yhwevsza0vl8436gugxke`
- **LTC:** `LYQ2ivZ52d2zAsm896MwWEkPEi15WwprS4`

## License

YTKACE source is available under the [MIT License](LICENSE). See [Third-Party Notices](THIRD_PARTY_NOTICES.md) for components and services with separate terms.
