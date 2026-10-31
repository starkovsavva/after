import json
import unittest

import eval_knowledge_semantic as subject


class EvalChecks(unittest.TestCase):
    def setUp(self):
        self.docs = json.loads(subject.CORPUS.read_text(encoding="utf-8"))["documents"]
        labels = sorted({d["label"] for d in self.docs})
        self.payload = {"model":"synthetic-fixture", "revision":"fixture-only", "vectors": {
            d["id"]:[float(i == labels.index(d["label"])) for i in range(len(labels))] for d in self.docs}}

    def test_metrics_do_not_claim_real_model_quality(self):
        result = subject.evaluate(self.docs, self.payload)
        self.assertEqual(result["documents"],30)
        self.assertEqual(result["precision_returned"],1.0)
        self.assertEqual(result["recall_at_3"],0.75)
        self.assertEqual(result["pair_recall"],1.0)
        self.assertIn("Synthetic smoke",result["warning"])

    def test_reject_incomplete_and_invalid_vectors(self):
        self.payload["vectors"].pop(self.docs[0]["id"])
        with self.assertRaises(ValueError): subject.evaluate(self.docs,self.payload)
        self.setUp()
        self.payload["vectors"][self.docs[0]["id"]]=[0,0]
        with self.assertRaises(ValueError): subject.evaluate(self.docs,self.payload)


if __name__ == "__main__":
    unittest.main()
