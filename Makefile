ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless
ADDITIONAL_CFLAGS += -Wno-error -Wno-unused-parameter

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = YTKACE

YTKACE_FILES = \
	Tweak/Entry.mm \
	Tweak/Runtime/Hooking.mm \
	Tweak/Runtime/Preferences.mm \
	Tweak/Runtime/Localization.mm \
	Tweak/UI/Assets.mm \
	Tweak/UI/Notice.mm \
	Tweak/UI/OverlayButtonHost.mm \
	Tweak/Features/Ads/AdsHooks.mm \
	Tweak/Features/Ads/PromoHooks.mm \
	Tweak/Features/SponsorBlock/SponsorClient.mm \
	Tweak/Features/SponsorBlock/SponsorPreferences.mm \
	Tweak/Features/SponsorBlock/SponsorHooks.mm \
	Tweak/Features/SponsorBlock/DeArrow.mm \
	Tweak/Features/Downloads/StreamResolver.mm \
	Tweak/Features/Downloads/SABRDownloader.mm \
	Tweak/Features/Downloads/DirectDownloader.mm \
	Tweak/Features/Downloads/FFmpegMuxer.mm \
	Tweak/Features/Downloads/YTKACEBackupManager.mm \
	Tweak/Features/Downloads/YTKACEMediaImporter.mm \
	Tweak/Features/Downloads/MediaArtwork.mm \
	Tweak/Features/Downloads/DownloadLog.mm \
	Tweak/Features/Downloads/DownloadProgressView.mm \
	Tweak/Features/Downloads/DownloadCoordinator.mm \
	Tweak/Features/Downloads/DownloadSponsor.mm \
	Tweak/Features/Downloads/DownloadHooks.mm \
	Tweak/Features/Downloads/PlaylistDownloader.mm \
	Tweak/Features/Downloads/YTKACEDownloadPlayerController.mm \
	Tweak/Features/Downloads/YTKACEAudioPlayerController.mm \
	Tweak/Features/Downloads/GlobalDownloadMiniPlayer.mm \
	Tweak/Features/Appearance/OLEDHooks.mm \
	Tweak/Features/Appearance/StartupHooks.mm \
	Tweak/Features/Appearance/PremiumLogoHooks.mm \
	Tweak/Features/Queue/QueueHooks.mm \
	Tweak/Features/Playback/BackgroundPlaybackHooks.mm \
	Tweak/Features/Playback/PiPControls.mm \
	Tweak/Features/Playback/PlaybackFixHooks.mm \
	Tweak/Features/Playback/ChallengeSolver.mm \
	Tweak/Features/Playback/SpeedControls.mm \
	Tweak/Features/Playback/LoopControls.mm \
	Tweak/Features/Playback/AutoplayControls.mm \
	Tweak/Features/Playback/CaptionControls.mm \
	Tweak/Features/Playback/TranscriptExport.mm \
	Tweak/Features/Playback/SleepTimerControls.mm \
	Tweak/Features/Playback/DoubleTapHooks.mm \
	Tweak/Features/Playback/VideoZoom.mm \
	Tweak/Features/Playback/ProgressBarStyle.mm \
	Tweak/Features/Translation/YTKACEVOTLog.mm \
	Tweak/Features/Translation/YTKACEVOTClient.mm \
	Tweak/Features/Translation/YTKACEVOTAudioPlayer.mm \
	Tweak/Features/Translation/YTKACEVOTCoordinator.mm \
	Tweak/Features/Translation/YTKACEVOTHooks.mm \
	Tweak/Features/Translation/YTKACEYandexAuthViewController.mm \
	Tweak/Features/Streaming/StreamingHooks.mm \
	Tweak/Features/Streaming/TVClient.mm \
	Tweak/Features/Streaming/HLSPlayback.mm \
	Tweak/Features/Interface/HomeTabs.mm \
	Tweak/UI/ExtraDim.mm \
	Tweak/Features/Playback/RemoteSkip.mm \
	Tweak/Features/Shorts/ShortsHooks.mm \
	Tweak/Features/Shorts/ShortsSessionLimit.mm \
	Tweak/Features/Shorts/ShortsStartup.mm \
	Tweak/Features/Shorts/ShortsPinch.mm \
	Tweak/Features/Shorts/ShortsPiP.mm \
	Tweak/Features/Compatibility/SideloadCompatibility.mm \
	Tweak/Features/Compatibility/CastCompatibility.mm \
	Tweak/Features/Onboarding/FirstLaunch.mm \
	Tweak/Features/Navigation/TabBarHooks.mm \
	Tweak/Features/Navigation/GlassChrome.mm \
	Tweak/Features/Navigation/GlassSheets.mm \
	Tweak/Features/Playback/PlayerGlass.mm \
	Tweak/Features/Navigation/NavigationBehaviorHooks.mm \
	Tweak/Features/Gestures/PlayerGestures.mm \
	Tweak/Features/Interface/OverlayVisibilityHooks.mm \
	Tweak/Features/Interface/ContentVisibilityHooks.mm \
	Tweak/Features/Interface/AiSList.mm \
	Tweak/Features/Interface/MiscellaneousHooks.mm \
	Tweak/Features/Interface/CopyCommentHooks.mm \
	Tweak/Features/Interface/ProfilePictureViewer.mm \
	Tweak/Features/Interface/PostImageSaver.mm \
	Tweak/Features/Interface/NativeShareHooks.mm \
	Tweak/Features/Interface/NavigationVisibility.mm \
	Tweak/Settings/SettingsEntry.mm \
	Tweak/Settings/NativeSettingsEntry.mm \
	Tweak/Settings/YTKACERootOptionsController.mm \
	Tweak/Settings/YTKACESettingsPages.mm \
	Tweak/Settings/YTKACESettingsSearch.mm \
	Tweak/Settings/YTKACETabEditorController.mm \
	Tweak/Settings/YTKACEDownloadsController.mm

YTKACE_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type
YTKACE_CFLAGS += -DYTKACE_COMBINED_SABR=1
YTKACE_CFLAGS += -DYTKACE_VERSION_STRING=\"$(shell awk '/^Version:/ {print $$2}' $(THEOS_PROJECT_DIR)/control)\"
YTKACE_CFLAGS += -Wno-module-import-in-extern-c
YTKACE_CFLAGS += -I$(THEOS_PROJECT_DIR)/Vendor/FFmpeg/include
YTKACE_CCFLAGS = -std=c++17
YTKACE_FRAMEWORKS = Foundation UIKit JavaScriptCore AVFoundation AVKit AudioToolbox MediaToolbox Photos QuartzCore MediaPlayer Security SystemConfiguration UniformTypeIdentifiers VideoToolbox CoreMedia WebKit
YTKACE_LIBRARIES = z
YTKACE_LDFLAGS = -Wl,-install_name,@rpath/YTKACE.dylib
YTKACE_LDFLAGS += $(THEOS_PROJECT_DIR)/Vendor/FFmpeg/lib/libavformat.a
YTKACE_LDFLAGS += $(THEOS_PROJECT_DIR)/Vendor/FFmpeg/lib/libavcodec.a
YTKACE_LDFLAGS += $(THEOS_PROJECT_DIR)/Vendor/FFmpeg/lib/libavutil.a
YTKACE_LDFLAGS += $(THEOS_PROJECT_DIR)/Vendor/FFmpeg/lib/libswscale.a
YTKACE_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk

after-all::
	@mkdir -p "$(THEOS_PROJECT_DIR)/dist"
	@cp "$(THEOS_OBJ_DIR)/YTKACE.dylib" "$(THEOS_PROJECT_DIR)/dist/YTKACE.dylib"

after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries" "$(THEOS_STAGING_DIR)/Library/Application Support"
	@cp -R "$(THEOS_PROJECT_DIR)/Resources/YTKACE.bundle" "$(THEOS_STAGING_DIR)/Library/Application Support/YTKACE.bundle"
	@cp "$(THEOS_PROJECT_DIR)/YTKACE.plist" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/YTKACE.plist"
