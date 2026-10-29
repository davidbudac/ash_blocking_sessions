"""Local-only packaging contract tests; Python is a developer dependency only."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TAG = '<script src="https://cdn.jsdelivr.net/npm/echarts@5.5.0/dist/echarts.min.js"></script>'
TEMPLATE = TAG + '\n<script>\nwindow.ASH_META =\n__META_JSON__\n;\nwindow.ASH_DATA =\n__DATA_JSON__\n;\n</script>\n'


def protocol(meta, data):
    return '\n'.join(['__META_JSON_BEGIN__'] + ['#'+s+'#' for s in meta] +
                     ['__META_JSON_END__', '__DATA_JSON_BEGIN__'] +
                     ['#'+s+'#' for s in data] + ['__DATA_JSON_END__', ''])


class Packaging(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy(ROOT/'run_report.sh', self.root)
        shutil.copytree(ROOT/'scripts', self.root/'scripts')
        (self.root/'assets').mkdir()
        (self.root/'assets/vendor').symlink_to(ROOT/'assets/vendor', target_is_directory=True)
        (self.root/'assets/template.html').write_text(TEMPLATE)
        (self.root/'bin').mkdir()
        fake = self.root/'bin/sqlplus'
        fake.write_text('#!/bin/sh\ntouch "$CALLED"\ncat "$PAYLOAD"\nexit "${FAKE_RC:-0}"\n')
        fake.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root/'bin')+':'+os.environ['PATH'],
                        PAYLOAD=str(self.root/'payload'), CALLED=str(self.root/'called'))
        (self.root/'payload').write_text(protocol(['{}'], ['[]']))

    def run_report(self, begin='AUTO', end='AUTO', name='test.html', ok=True):
        result = subprocess.run(['sh', str(self.root/'run_report.sh'), 'AUTO', begin, end, name],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout+result.stderr)
        return result

    def test_unicode_whitespace_and_split_script(self):
        value = {'text': '  Žluťoučký 🦊 </ScRiPt><script>alert(1)</script><!--  ', 'n': '\u2028'}
        raw = json.dumps(value, ensure_ascii=False)
        at = raw.index('</')+2
        (self.root/'payload').write_text(protocol([raw[:at], raw[at:]], ['[', '  ', ']']))
        self.run_report()
        html = (self.root/'reports/test.html').read_text()
        embedded = re.search(r'window.ASH_META =\n(.*?)\n;', html, re.S).group(1)
        self.assertEqual(json.loads(embedded), value)
        self.assertNotIn('<', embedded)
        self.assertIn('[  ]', html)
        self.assertNotIn('<script src=', html)
        vendor = re.search(r'<script>\n(.*?)\n</script>', html, re.S).group(1)
        self.assertEqual(vendor.encode(), (ROOT/'assets/vendor/echarts-5.5.0.min.js').read_bytes())

    def test_bad_protocols(self):
        good = protocol(['{}'], ['[]'])
        cases = [good.replace('#{}#', '{}'), good.replace('__META_JSON_END__\n', ''),
                 good+good, good.replace('#{}#', '#'+('x'*501)+'#'),
                 good.replace('#{}#', '#a\tb#'), good.replace('#[]#', ''),
                 good.replace('__DATA_JSON_BEGIN__', '__DATA_JSON_BOGUS__'),
                 good+'ORA-00942: missing\n']
        for bad in cases:
            with self.subTest(bad=bad[:60]):
                (self.root/'payload').write_text(bad)
                self.run_report(ok=False)
                self.assertFalse((self.root/'reports/test.html').exists())

    def test_full_unicode_chunk(self):
        text = '🦊'*498
        raw = json.dumps(text, ensure_ascii=False)
        self.assertEqual(len(raw), 500)
        (self.root/'payload').write_text(protocol(['{}'], ['[', raw, ']']))
        self.run_report()
        html = (self.root/'reports/test.html').read_text()
        embedded = re.search(r'window.ASH_DATA =\n(.*?)\n;', html, re.S).group(1)
        self.assertEqual(json.loads(embedded), [text])

    def test_sqlplus_failure(self):
        self.env['FAKE_RC'] = '7'
        self.run_report(ok=False)
        self.assertFalse((self.root/'reports/test.html').exists())

    def test_placeholder_validation(self):
        for template in [TEMPLATE+'__META_JSON__\n', TEMPLATE+'prefix __DATA_JSON__\n',
                         TEMPLATE.replace('__META_JSON__', ' __META_JSON__'), TEMPLATE.replace(TAG, '')]:
            (self.root/'assets/template.html').write_text(template)
            self.run_report(ok=False)

    def test_times_rejected_before_sqlplus(self):
        for b,e in [('2026-02-29T00:00:00','AUTO'), ('2026-01-01T24:00:00','AUTO'),
                    (r'2026-01-01T00:00:0\060','AUTO'),
                    ('AUTO',r'2026-01-01T00:00:0\060'),
                    ("x'&foo",'AUTO'), ('2026-01-02T00:00:00','2026-01-01T00:00:00')]:
            self.run_report(b,e,ok=False)
            self.assertFalse((self.root/'called').exists())
        self.run_report('2024-02-29T00:00:00','2024-03-01T00:00:00')

    def test_paths_and_overwrite(self):
        for name in ['../escape.html','/tmp/escape.html','ash_blocking_demo.html','.hidden.html']:
            self.run_report(name=name,ok=False)
        self.run_report()
        before = (self.root/'reports/test.html').read_bytes()
        self.run_report(ok=False)
        self.assertEqual(before,(self.root/'reports/test.html').read_bytes())
        (self.root/'reports/link.html').symlink_to(self.root/'missing')
        self.run_report(name='link.html',ok=False)

    def test_destination_created_during_query(self):
        fake = self.root/'bin/sqlplus'
        for kind in ['directory', 'symlink', 'file']:
            name = kind + '.html'
            destination = self.root/'reports'/name
            actions = {
                'directory': 'mkdir "reports/directory.html"',
                'symlink': 'mkdir "reports/elsewhere"; ln -s elsewhere "reports/symlink.html"',
                'file': 'printf original > "reports/file.html"',
            }
            fake.write_text('#!/bin/sh\n' + actions[kind] + '\ncat "$PAYLOAD"\n')
            self.run_report(name=name, ok=False)
            if kind == 'file':
                self.assertEqual(destination.read_text(), 'original')
            else:
                self.assertEqual(list(destination.iterdir()), [])

    def test_fixture_and_determinism(self):
        (self.root/'docs').mkdir()
        (self.root/'reports').mkdir()
        cmd=['sh',str(self.root/'scripts/regenerate-demos.sh')]
        subprocess.run(cmd,check=True,capture_output=True)
        one=(self.root/'docs/demo.html').read_bytes()
        subprocess.run(cmd,check=True,capture_output=True)
        self.assertEqual(one,(self.root/'reports/ash_blocking_demo.html').read_bytes())
        self.assertEqual(one,(self.root/'docs/demo.html').read_bytes())
        for key in ['meta','data']:
            json.loads(''.join((self.root/f'scripts/demo-fixture/{key}.chunks').read_text().splitlines()))


if __name__ == '__main__':
    unittest.main()
