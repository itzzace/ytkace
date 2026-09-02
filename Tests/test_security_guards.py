import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class SecurityGuardTests(unittest.TestCase):
    def test_sensitive_sabr_payloads_are_not_dumped(self):
        source = (ROOT / "Tweak/Features/Downloads/SABRDownloader.mm").read_text()
        self.assertNotIn("ytkace-native.pb", source)
        self.assertNotIn("ytkace-outgoing.pb", source)
        self.assertNotIn('directive type=%u data=%@', source)
        self.assertNotIn('@"headers %@"', source)
        self.assertIn("YTKACESABRRequestCacheLimit", source)

    def test_sabr_destinations_are_validated_at_each_assignment(self):
        source = (ROOT / "Tweak/Features/Downloads/SABRDownloader.mm").read_text()
        self.assertIn("YTKACESABRIsAllowedServerURL", source)
        self.assertIn('isEqualToString:@"https"', source)
        self.assertIn('hasSuffix:@".googlevideo.com"', source)
        self.assertGreaterEqual(source.count("YTKACESABRIsAllowedServerURL("), 4)

    def test_backup_restore_has_preference_and_size_guards(self):
        source = (ROOT / "Tweak/Features/Downloads/YTKACEBackupManager.mm").read_text()
        self.assertIn("YTKACEIsRestorablePreference", source)
        self.assertIn('hasPrefix:@"YTKACE.Preference."', source)
        self.assertIn("YTKACEMaxBackupEntries", source)
        self.assertIn("YTKACEMaxBackupEntrySize", source)
        self.assertIn("YTKACEMaxBackupTotalSize", source)
        self.assertIn("NSURLVolumeAvailableCapacityForImportantUsageKey", source)

    def test_applying_settings_does_not_terminate_youtube(self):
        source = (ROOT / "Tweak/Settings/YTKACERootOptionsController.mm").read_text()
        self.assertNotIn("exit(0)", source)
        self.assertIn("postNotificationName:YTKACEPreferencesDidChangeNotification", source)
        self.assertIn("dismissViewControllerAnimated:YES", source)


if __name__ == "__main__":
    unittest.main()
