#!/usr/bin/env python3
"""Unit tests for regshot2msi. Run: python3 -m unittest test_regshot2msi -v"""

import unittest
import xml.dom.minidom as minidom

import regshot2msi as R


class ParseRegDataTests(unittest.TestCase):
    def test_string(self):
        self.assertEqual(R._parse_reg_data('"hello"'), ("string", "hello"))

    def test_string_escaped(self):
        self.assertEqual(R._parse_reg_data(r'"a\\b\"c"'), ("string", 'a\\b"c'))

    def test_empty_string(self):
        self.assertEqual(R._parse_reg_data(""), ("string", ""))

    def test_dword(self):
        self.assertEqual(R._parse_reg_data("dword:0000000a"), ("integer", 10))

    def test_binary(self):
        t, v = R._parse_reg_data("hex:01,02,ff")
        self.assertEqual((t, v), ("binary", b"\x01\x02\xff"))

    def test_expand_sz(self):
        # UTF-16LE for "C:\" plus a trailing NUL.
        t, v = R._parse_reg_data("hex(2):43,00,3a,00,5c,00,00,00")
        self.assertEqual((t, v), ("expandable", "C:\\"))

    def test_multi_sz(self):
        t, v = R._parse_reg_data("hex(7):61,00,00,00,62,00,00,00,00,00")
        self.assertEqual((t, v), ("multiString", ["a", "b"]))

    def test_qword_falls_back_to_binary(self):
        t, v = R._parse_reg_data("hex(b):0a,00,00,00,00,00,00,00")
        self.assertEqual(t, "binary")


class SplitRootTests(unittest.TestCase):
    def test_long_and_short(self):
        self.assertEqual(R._split_root("HKEY_LOCAL_MACHINE\\Software\\X"), ("HKLM", "Software\\X"))
        self.assertEqual(R._split_root("HKCU\\Software\\X"), ("HKCU", "Software\\X"))

    def test_unknown_root(self):
        with self.assertRaises(R.ConversionError):
            R._split_root("HKEY_BOGUS\\X")


class ParseUnlTests(unittest.TestCase):
    UNL = (
        '; Registry=+"HKLM\\Software\\App"\n'
        '; Registry=+"HKLM\\Software\\App","N"="v"\n'
        '; File=+"C:\\App\\a.exe"\n'
        '; Directory=+"C:\\App"\n'
        'Registry="HKLM\\Software\\Old","Gone"="x"\n'   # deletion, install-ignored
        'File="C:\\tmp\\junk.tmp"\n'
    )

    def test_install_direction(self):
        changes = R.parse_unl(self.UNL, direction="install")
        kinds = [c.kind for c in changes]
        self.assertEqual(kinds, ["regkey", "regval", "file", "dir"])
        self.assertEqual(changes[1].name, "N")
        self.assertEqual(changes[2].path, "C:\\App\\a.exe")

    def test_uninstall_direction(self):
        changes = R.parse_unl(self.UNL, direction="uninstall")
        self.assertEqual([c.kind for c in changes], ["regval", "file"])
        self.assertEqual(changes[0].key, "Software\\Old")


class RelativePartsTests(unittest.TestCase):
    def test_strip_drive(self):
        self.assertEqual(R._relative_parts("C:\\Program Files\\App\\a.dll", None),
                         ["Program Files", "App", "a.dll"])

    def test_strip_prefix(self):
        self.assertEqual(
            R._relative_parts("C:\\Program Files\\App\\bin\\a.dll", "C:\\Program Files\\App"),
            ["bin", "a.dll"])


class BuildWxsTests(unittest.TestCase):
    def _build(self, unl):
        changes = R.parse_unl(unl, direction="install")
        return R.build_wxs(changes, title="T", manufacturer="M", version="1.0.0.0",
                           install_root="ProgramFiles64Folder", strip_prefix=None)

    def test_well_formed_and_dedup(self):
        unl = (
            '; Registry=+"HKLM\\Software\\App"\n'
            '; Registry=+"HKLM\\Software\\App","N"=dword:00000001\n'
            '; File=+"C:\\App\\a.exe"\n'
        )
        wxs = self._build(unl)
        # Must be well-formed XML.
        minidom.parseString(wxs)
        # The key that receives a value must not also get a standalone key component.
        self.assertNotIn('Value="" KeyPath="yes" />\n      </Component>', wxs)
        self.assertIn('Type="integer" Value="1"', wxs)
        self.assertIn('Source="C:\\App\\a.exe"', wxs)

    def test_empty_key_uses_default_value(self):
        unl = '; Registry=+"HKLM\\Software\\EmptyKey"\n'
        wxs = self._build(unl)
        minidom.parseString(wxs)
        self.assertIn('Key="Software\\EmptyKey" Type="string" Value="" KeyPath="yes"', wxs)

    def test_xml_escaping(self):
        unl = '; Registry=+"HKLM\\Software\\App","N"="a & b <c>"\n'
        wxs = self._build(unl)
        doc = minidom.parseString(wxs)  # would raise on bad escaping
        self.assertIn("a &amp; b &lt;c&gt;", wxs)
        self.assertTrue(doc)


if __name__ == "__main__":
    unittest.main()
