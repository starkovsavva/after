import copy
import unittest

from eval_knowledge_judgments import evaluate


class JudgmentEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.corpus = {"documents": [{"id": "a", "type": "note"}, {"id": "b", "type": "meeting"}, {"id": "c", "type": "note"}],
                       "queries": [{"id": "a", "relevant": ["b"], "irrelevant": ["c"]},
                                   {"id": "c", "relevant": [], "irrelevant": ["a", "b"]}]}
        self.payload = {"model": "fixture", "revision": "sha256:fixture", "vectors": {"a": [1, 0], "b": [0.9, 0.1], "c": [0, 1]}}

    def test_related_meeting_and_negative_abstention(self):
        result = evaluate(self.corpus, self.payload, threshold=0.8)
        self.assertEqual(result["precision_returned"], 1)
        self.assertEqual(result["macro_recall_at_k"], 1)
        self.assertEqual(result["negative_query_false_positive_rate"], 0)
        self.assertEqual(result["pair_types"]["note→meeting"]["relevant"], 1)

    def test_false_positive_and_macro_recall(self):
        result = evaluate(self.corpus, self.payload, threshold=0.0, k=1)
        self.assertEqual(result["negative_query_false_positive_rate"], 1)
        self.assertEqual(result["precision_returned"], 0.5)

    def test_incomplete_or_duplicate_judgments_rejected(self):
        for relevant, irrelevant in [(["b"], []), (["b", "b"], ["c"]), (["b"], ["b", "c"]), (["a"], ["b", "c"])]:
            invalid = copy.deepcopy(self.corpus)
            invalid["queries"][0].update(relevant=relevant, irrelevant=irrelevant)
            with self.subTest(relevant=relevant, irrelevant=irrelevant), self.assertRaises(ValueError):
                evaluate(invalid, self.payload, threshold=0.5)

    def test_bad_vectors_and_duplicate_queries_rejected(self):
        invalid = copy.deepcopy(self.payload)
        invalid["vectors"]["a"] = [float("nan"), 0]
        with self.assertRaises(ValueError):
            evaluate(self.corpus, invalid, threshold=0.5)
        invalid_corpus = copy.deepcopy(self.corpus)
        invalid_corpus["queries"].append(invalid_corpus["queries"][0])
        with self.assertRaises(ValueError):
            evaluate(invalid_corpus, self.payload, threshold=0.5)

    def test_no_results_has_undefined_precision(self):
        result = evaluate(self.corpus, self.payload, threshold=1.0)
        self.assertIsNone(result["precision_returned"])
        self.assertEqual(result["positive_query_coverage"], 0)
        self.assertEqual(result["macro_recall_at_k"], 0)


if __name__ == "__main__":
    unittest.main()
