"""Compile and execute the production Objective-C++ cleaner and copy hooks."""
import pathlib
import platform
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin", "Requires Apple's Foundation framework")
class YouTubeLinkCleaningTests(unittest.TestCase):
    def test_production_cleaner_and_copy_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = pathlib.Path(directory) / "youtube-link-tests"
            subprocess.run([
                "xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-fobjc-arc",
                "-fblocks", "-Wall", "-Wextra", "-Werror", "-framework", "Foundation",
                "-I", str(ROOT / "Tests/Support"),
                str(ROOT / "Tests/YouTubeLinkCleaningTests.mm"),
                str(ROOT / "Tweak/Features/Interface/YouTubeLinkCleaner.mm"),
                str(ROOT / "Tweak/Features/Interface/CopyLinkHooks.mm"),
                str(ROOT / "Tweak/Runtime/Hooking.mm"), "-o", str(executable),
            ], check=True, cwd=ROOT)
            subprocess.run([str(executable), str(ROOT / "Tests/youtube_link_cases.json")], check=True)


if __name__ == "__main__":
    unittest.main()
