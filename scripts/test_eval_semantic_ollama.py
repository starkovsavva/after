import unittest

from eval_semantic_ollama import local_endpoint, note_model_input


class LoopbackOnlyTests(unittest.TestCase):
    def test_note_input_matches_single_line_empty_title_note(self):
        self.assertEqual(note_model_input("Пример"), "Пример\nПример\n\n")
        for text in ("две\nстроки", "я" * 81):
            with self.subTest(text=text), self.assertRaises(ValueError):
                note_model_input(text)

    def test_accepts_only_explicit_loopback_http_address_with_port(self):
        self.assertEqual(local_endpoint("http://127.0.0.1:32649/"), "http://127.0.0.1:32649")
        self.assertEqual(local_endpoint("http://[::1]:32649"), "http://[::1]:32649")
        for url in ("https://127.0.0.1:32649", "http://localhost:32649", "http://example.com:1234",
                    "http://127.0.0.1", "http://127.0.0.1:32649/path", "http://127.0.0.1:32649/?x=1",
                    "http://user:pass@127.0.0.1:32649", "http://127.0.0.1:99999"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                local_endpoint(url)


if __name__ == "__main__":
    unittest.main()
