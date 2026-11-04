import io
import tarfile
import unittest
from unittest.mock import patch

from inspect_distribution import check_url, validated_members


class InspectionTests(unittest.TestCase):
    def archive(self, entries):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w") as archive:
            for name, kind in entries:
                item = tarfile.TarInfo(name)
                item.type = kind
                item.size = 0
                archive.addfile(item, io.BytesIO())
        data.seek(0)
        return tarfile.open(fileobj=data, mode="r:")

    def test_regular_distribution(self):
        with self.archive([("soloist", tarfile.REGTYPE), ("NOTICE", tarfile.REGTYPE)]) as archive:
            members, binary = validated_members(archive)
        self.assertEqual(len(members), 2)
        self.assertEqual(binary.name, "soloist")

    def test_unsafe_entries(self):
        for name, kind in [("../soloist", tarfile.REGTYPE), ("/soloist", tarfile.REGTYPE),
                           ("dir/../../soloist", tarfile.REGTYPE), ("soloist", tarfile.SYMTYPE),
                           ("soloist", tarfile.LNKTYPE), ("soloist", tarfile.FIFOTYPE)]:
            with self.subTest(name=name, kind=kind), self.archive([(name, kind)]) as archive:
                with self.assertRaises(ValueError):
                    validated_members(archive)

    def test_duplicate_and_missing_binary(self):
        for entries in [[("soloist", tarfile.REGTYPE)] * 2, [("NOTICE", tarfile.REGTYPE)]]:
            with self.subTest(entries=entries), self.archive(entries) as archive:
                with self.assertRaises(ValueError):
                    validated_members(archive)

    def test_entry_count_is_bounded_before_loading_all_headers(self):
        with self.archive([("soloist", tarfile.REGTYPE), ("NOTICE", tarfile.REGTYPE)]) as archive:
            with patch("inspect_distribution.MAX_ENTRIES", 1), self.assertRaises(ValueError):
                validated_members(archive)

    def test_unreviewed_downloads(self):
        check_url("https://soloist-builds.spotifycdn.com/soloist_release_osx_arm64.tar.gz")
        for url in ["http://soloist-builds.spotifycdn.com/file", "https://example.com/file",
                    "https://soloist-builds.spotifycdn.com.evil.invalid/file",
                    "https://user@soloist-builds.spotifycdn.com/file",
                    "https://soloist-builds.spotifycdn.com:444/file"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                check_url(url)


if __name__ == "__main__":
    unittest.main()
