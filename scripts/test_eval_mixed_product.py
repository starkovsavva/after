import unittest
from eval_mixed_product import metrics

class ProductMetricsTests(unittest.TestCase):
    def test_overlap_is_deduplicated_and_wrong_pair_lowers_precision(self):
        docs=[dict(id='a',type='note',label='one'),dict(id='b',type='meeting',label='one'),dict(id='c',type='note',label='other')]
        sources=[dict(kind='note',noteID='a'),dict(kind='meeting',meetingID='b'),dict(kind='note',noteID='c')]
        result=metrics(docs,[dict(sources=sources),dict(sources=sources[:2])])
        self.assertEqual((result['returned'],result['correct'],result['expected']),(2,1,1))
        self.assertEqual(result['precision'],0.5)
        self.assertEqual(result['positive_source_coverage'],1)
        self.assertEqual(result['false_pairs'],[('b','c')])
    def test_missing_pairs_do_not_invent_precision(self):
        docs=[dict(id='a',type='note',label='one'),dict(id='b',type='meeting',label='one')]
        result=metrics(docs,[])
        self.assertIsNone(result['precision'])
        self.assertEqual(result['recall'],0)
        self.assertEqual(result['positive_source_coverage'],0)

if __name__=='__main__':unittest.main()
