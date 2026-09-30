import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('desktop_worker', Path(__file__).parents[1] / 'worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class InputTests(unittest.TestCase):
    def test_share_text_and_markdown(self):
        self.assertEqual(worker.extract_url('4.5 复制打开抖音 https://v.douyin.com/abc/ 看视频。'),
                         'https://v.douyin.com/abc/')
        self.assertEqual(worker.extract_url('[https://v.douyin.com/\\_abc/](https://v.douyin.com/_abc/)'),
                         'https://v.douyin.com/_abc/')

    def test_unsafe_input(self):
        for value in ['file:///etc/passwd', '--exec something', '无链接', 'https://user:password@example.com/']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                worker.extract_url(value)

    def test_douyin_host_boundary(self):
        self.assertTrue(worker.is_douyin('https://v.douyin.com/abc/'))
        self.assertFalse(worker.is_douyin('https://douyin.com.evil.example/'))
        self.assertFalse(worker.is_douyin('https://example.com/douyin.com/'))

    def test_resolution_cap_applies_to_combined_and_split_formats(self):
        selector = worker.format_selector('720')
        self.assertEqual(selector.count('[height<=?720]'), 2)
        self.assertNotIn('/b/', selector)


class BatchExtractTests(unittest.TestCase):
    def test_real_douyin_share_text(self):
        text = ('3.87 :9pm A@g.Ok cnD:/ 08/23 跑分越高的手机，就越好用吗？ # 小米 # OPPO # 骁龙 # 联发科 # 跑分  '
                'https://v.douyin.com/4OazCjDdu4o/ 复制此链接，打开Dou音搜索，直接观看视频！')
        self.assertEqual(worker.extract_urls(text), ['https://v.douyin.com/4OazCjDdu4o/'])

    def test_chinese_glued_to_url(self):
        self.assertEqual(worker.extract_urls('链接https://v.douyin.com/abc/复制此链接打开抖音'),
                         ['https://v.douyin.com/abc/'])
        self.assertEqual(worker.extract_urls('看看https://b23.tv/x1Y2z3，这个up主绝了'),
                         ['https://b23.tv/x1Y2z3'])

    def test_multiple_links_mixed_text(self):
        text = ('第一个 https://v.douyin.com/abc/ 复制打开抖音；\n'
                '【猫和老鼠】 https://www.bilibili.com/video/BV1E6aq6pEKR/?spm_id_from=333.337 哔哩哔哩\n'
                '再来一遍 https://v.douyin.com/abc/ 和 https://youtu.be/dQw4w9WgXcQ。')
        self.assertEqual(worker.extract_urls(text), [
            'https://v.douyin.com/abc/',
            'https://www.bilibili.com/video/BV1E6aq6pEKR/?spm_id_from=333.337',
            'https://youtu.be/dQw4w9WgXcQ',
        ])

    def test_trailing_ascii_punctuation_stripped(self):
        self.assertEqual(worker.extract_urls('看这个 https://example.com/a. 还有 https://example.com/b, 没了'),
                         ['https://example.com/a', 'https://example.com/b'])

    def test_invalid_links_skipped_in_batch(self):
        self.assertEqual(worker.extract_urls('https://user:pass@evil.com/x 和 https://v.douyin.com/ok/'),
                         ['https://v.douyin.com/ok/'])
        self.assertEqual(worker.extract_urls('没有链接'), [])

    def test_extract_url_rejects_multiple(self):
        with self.assertRaises(ValueError):
            worker.extract_url('https://v.douyin.com/a/ https://v.douyin.com/b/')


if __name__ == '__main__':
    unittest.main()
