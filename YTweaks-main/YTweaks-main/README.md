# <p align="left"><img src="./.resources/repoHeader.png" width="1000"></p>

Working features:
- **Force Fullscreen Direction (Button)**: Choose Off, Left, Right, or Portrait for the fullscreen button.
- **Force Fullscreen Direction (Gesture)**: Choose Off, Left, Right, or Portrait for the swipe-up gesture. Independent of the button setting.
- **Disable floating miniplayer**: Restores the old miniplayer by disabling the floating miniplayer.
- **Virtual fullscreen bezels**: Adds invisible touch-safe zones on black bars to prevent accidental taps and skips.
- **Fix Casting** - Attempts to fix casting by changing some A/B flags. Only works on v20.10.4 or lower.
- **Hide AI Summaries**: Attempts to block/hide AI summaries below videos in the home feed.
- **Fake Brightness**: Lowers apparent brightness below the system minimum. Works best on OLED devices.
- **Schedule Fake Brightness (Night Mode)**: Automatically applies fake brightness during a set time range.

More settings will most likely be added in the future. Designed to work with a [fork of YTLite](https://github.com/fosterbarnes/YTPlusYTweaks/) (also known as [YouTube Plus](https://github.com/dayanch96/YTLite)).

<table>
   <tr>
      <td><img src="https://raw.githubusercontent.com/fosterbarnes/YTPlusYTweaks/main/Resources/scr13.jpg" alt="Screenshot 1" width="250" /></td>
   </tr>
</table>

## Building 

Refer to [YTPlusYTweaks](https://github.com/fosterbarnes/YTPlusYTweaks#how-to-build-a-ytplusytweaks-app) for build info

## Supported YouTube versions

20.10.4 is recommended. 'Fix Casting' and 'Disable floating miniplayer' settings do not yet work on newer versions.

**Latest confirmed:** 21.26.4

**Date tested:** 7/3/26

## Special Thanks

Thanks to PoomSmart for making the various tweaks that made this possible. This tweak is essentially a stripped down fork of https://github.com/PoomSmart/YTABConfig

Shoutout https://github.com/pwnless/AutoFLEX. This tool has been crucial for debugging and testing.
