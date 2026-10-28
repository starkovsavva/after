"""Translation assets must preserve arguments and cover explicit interface keys."""
import json
from pathlib import Path
import re
import unittest

PROJECT = Path(__file__).resolve().parents[1]
CATALOG = PROJECT / 'Sources/PosleApp/Resources/Localization/en.json'


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate translation key: ' + key)
        result[key] = value
    return result


class LocalizationTests(unittest.TestCase):
    def test_catalog_is_complete_english_and_keeps_placeholders(self):
        catalog = json.loads(CATALOG.read_text(), object_pairs_hook=unique_object)
        for key, value in catalog.items():
            with self.subTest(key=key):
                self.assertIsInstance(value, str)
                self.assertTrue(value.strip())
                self.assertFalse(re.search('[А-Яа-яЁё]', value), value)
                self.assertEqual(set(re.findall(r'\{[0-9]+\}', key)), set(re.findall(r'\{[0-9]+\}', value)))

    def test_explicit_interface_keys_exist(self):
        catalog = json.loads(CATALOG.read_text())
        missing = []
        for path in (PROJECT / 'Sources/PosleApp').glob('*.swift'):
            source = path.read_text()
            for match in re.finditer(r'\bL(?:F)?\(\s*("(?:\\.|[^"\\])*")', source):
                try:
                    key = json.loads(match.group(1))
                except ValueError:
                    continue
                if re.search('[А-Яа-яЁё]', key) and key not in catalog:
                    missing.append(f'{path.name}:{source.count(chr(10), 0, match.start()) + 1}: {key}')
        self.assertEqual([], missing, '\n'.join(missing))

    def test_brand_and_language_are_independent_of_content_language(self):
        catalog = json.loads(CATALOG.read_text())
        self.assertEqual('After', catalog['После'])
        self.assertEqual('Interface language', catalog['Язык интерфейса'])
        self.assertEqual('Summary language', catalog['Язык конспекта'])
        english = (PROJECT / 'packaging/en.lproj/InfoPlist.strings').read_text()
        russian = (PROJECT / 'packaging/ru.lproj/InfoPlist.strings').read_text()
        self.assertIn('"CFBundleDisplayName" = "After";', english)
        self.assertIn('"CFBundleDisplayName" = "После";', russian)


if __name__ == '__main__':
    unittest.main()
