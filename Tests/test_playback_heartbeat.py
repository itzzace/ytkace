import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"),
                     "Requires Apple's Foundation framework and compiler")
class PlaybackHeartbeatTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = pathlib.Path(cls.temporary.name)
        harness = directory / "heartbeat.mm"
        cls.executable = directory / "heartbeat"
        harness.write_text('''
#import "YTKACE.h"
#import "Runtime/Preferences.h"

static BOOL masterEnabled;
static BOOL featureEnabled;

BOOL YTKACEFeatureEnabled(NSString *key) {
    NSCAssert([key isEqualToString:@"YTKACE.Preference.Playback.BlockHeartbeat"],
              @"Unexpected preference key");
    return masterEnabled && featureEnabled;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) return 2;
        masterEnabled = argv[1][0] == '1';
        featureEnabled = argv[2][0] == '1';
        NSString *value = [NSString stringWithUTF8String:argv[3]];
        NSURL *URL = [value isEqualToString:@"nil"] ? nil : [NSURL URLWithString:value];
        return YTKACEShouldBlockPlaybackHeartbeat(URL) ? 0 : 1;
    }
}
''')
        subprocess.run([
            "xcrun", "clang++", "-fobjc-arc", "-std=c++17",
            "-Wall", "-Wextra", "-Werror", "-framework", "Foundation",
            "-I", str(ROOT / "Tweak"),
            str(ROOT / "Tweak/Features/Playback/PlaybackHeartbeat.mm"),
            str(harness), "-o", str(cls.executable),
        ], check=True, capture_output=True, text=True)

    def assert_blocked(self, url, expected, master=True, enabled=True):
        result = subprocess.run([
            str(self.executable), str(int(master)), str(int(enabled)), url,
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if expected else 1, result.stderr)

    def test_blocks_only_youtube_heartbeat_endpoints(self):
        for host in ("youtube.com", "www.youtube.com", "m.youtube.com",
                     "music.youtube.com", "youtubei.googleapis.com",
                     "WWW.YouTube.COM"):
            with self.subTest(host=host):
                self.assert_blocked(
                    f"https://{host}/youtubei/v1/player/heartbeat?key=example", True)

    def test_rejects_unrelated_and_lookalike_hosts(self):
        for host in ("example.com", "notyoutube.com", "youtube.com.example.com",
                     "youtubei.googleapis.com.example.com", "googleapis.com",
                     "other.googleapis.com", "youtube.com@evil.example"):
            with self.subTest(host=host):
                self.assert_blocked(f"https://{host}/youtubei/v1/player/heartbeat", False)

    def test_preserves_other_player_and_media_requests(self):
        for path in ("/youtubei/v1/player", "/youtubei/v1/player/heartbeat/extra",
                     "/youtubei/v1/player/heartbeats", "/youtubei/v1/next",
                     "/videoplayback", "/api/stats/watchtime", "/watch",
                     "/YOUTUBEI/v1/player/heartbeat", "/"):
            with self.subTest(path=path):
                self.assert_blocked(f"https://www.youtube.com{path}", False)
        self.assert_blocked(
            "https://example.googlevideo.com/videoplayback"
            "?url=https://youtube.com/youtubei/v1/player/heartbeat", False)

    def test_requires_https_and_an_absolute_url(self):
        for url in ("nil", "", "/youtubei/v1/player/heartbeat",
                    "http://youtube.com/youtubei/v1/player/heartbeat",
                    "ftp://youtube.com/youtubei/v1/player/heartbeat"):
            with self.subTest(url=url):
                self.assert_blocked(url, False)

    def test_respects_feature_and_master_gating(self):
        url = "https://youtube.com/youtubei/v1/player/heartbeat"
        for master, enabled in ((False, False), (False, True), (True, False)):
            with self.subTest(master=master, enabled=enabled):
                self.assert_blocked(url, False, master=master, enabled=enabled)
        self.assert_blocked(url, True)


if __name__ == "__main__":
    unittest.main()
