"""Exercise pipeline state transitions without models, Git mutations, or app builds.

Fixtures are retained in the ignored run directory for inspection.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SKILL = Path(__file__).resolve().parents[1]
PROJECT = SKILL.parents[2]
ARTIFACTS = PROJECT / '.tmp/scratch/research-execute/validation'

# The fixture Git interface supplies a stable main checkout without creating
# branches or commits. Fingerprinting still reads and hashes a real dirty file.
GIT = '''#!/usr/bin/env python3
import hashlib, sys
args = sys.argv[1:]
if args[:1] == ['-C']:
    root = args[1]
    args = args[2:]
else:
    root = ''
if '--show-toplevel' in args:
    print(root.split('/.agents/')[0])
elif '--abbrev-ref' in args:
    print('main')
elif 'rev-parse' in args:
    print('a' * (12 if '--short=12' in args else 40))
elif 'hash-object' in args:
    print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest())
elif 'status' in args:
    sys.stdout.write('?? user-file.txt\\0' if '-z' in args else '?? user-file.txt\\n')
else:
    raise SystemExit('Unexpected Git operation: ' + repr(args))
'''
AGENT = '''#!/usr/bin/env python3
import os
from pathlib import Path
import re, sys
stage = os.environ['RESEARCH_EXECUTE_STAGE']
root = Path.cwd()
with (root / 'calls.txt').open('a') as calls:
    calls.write(stage + '\\n')
args = sys.argv[1:]
prompt = args[-1]
run = Path(re.search(r'Run directory: (.+)', prompt).group(1)) if 'Run directory:' in prompt else (root / '.tmp/scratch/research-execute/latest').resolve()
doc = next((root / 'docs/RESEARCHES').glob('*.md'))
mode = (root / 'mode.txt').read_text()
if stage == 'review':
    if mode == 'review-question':
        (run / 'questions.md').write_text('1. Which behavior is intended?')
        print('RESULT: QUESTIONS - needs clarification')
        raise SystemExit(0)
    status = 'Plan review completed; awaiting implementation.'
    if mode == 'owner':
        status = 'Plan review completed; awaiting owner decision: select policy'
    doc.write_text('Status: ' + status + '\\n')
    doc.rename(doc.with_name('REVIEWED - ' + doc.name))
    print('RESULT: REVIEWED - ready')
    raise SystemExit(1 if mode == 'failed-review' else 0)
if mode == 'execute-question':
    (run / 'questions.md').write_text('1. Which threshold applies?')
    Path(args[args.index('-o') + 1]).write_text('RESULT: QUESTIONS - threshold')
    print('session id: fixture-session')
    raise SystemExit(0)
if mode == 'partial':
    Path(args[args.index('-o') + 1]).write_text('RESULT: PARTIAL - pending check')
    raise SystemExit(0)
(root / 'docs/RESEARCHES/DONE').mkdir(exist_ok=True)
doc.write_text('Status: Implemented locally; not released.\\n')
doc.rename(root / 'docs/RESEARCHES/DONE' / ('DONE - ' + doc.name.removeprefix('REVIEWED - ')))
Path(args[args.index('-o') + 1]).write_text('RESULT: DONE - verified locally')
'''


class RunnerTests(unittest.TestCase):
    def setUp(self):
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='runner-', dir=ARTIFACTS))
        self.skill = self.root / '.agents/skills/research-execute'
        shutil.copytree(SKILL, self.skill, ignore=shutil.ignore_patterns('tests'))
        self.doc = self.root / 'docs/RESEARCHES/2026-11-08_12-17_Test plan.md'
        self.doc.parent.mkdir(parents=True)
        self.doc.write_text('Status: Plan awaiting implementation.\n')
        (self.root / 'user-file.txt').write_text('Pre-existing user work.\n')
        self.mode('complete')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name, content in [('git', GIT), ('agy', AGENT), ('codex', AGENT)]:
            path = self.bin / name
            path.write_text(content)
            path.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH']}
        self.env.pop('RESEARCH_EXECUTE_STAGE', None)

    def mode(self, value):
        (self.root / 'mode.txt').write_text(value)

    def run_pipeline(self, *args, expected=0):
        result = subprocess.run([str(self.skill / 'run.sh'), *map(str, args)],
                                cwd=self.root, env=self.env, text=True,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertEqual((self.root / 'user-file.txt').read_text(), 'Pre-existing user work.\n')
        return result

    def calls(self):
        path = self.root / 'calls.txt'
        return path.read_text().splitlines() if path.exists() else []

    def latest(self):
        return (self.root / '.tmp/scratch/research-execute/latest').resolve()

    def test_dry_run_renders_both_stages_without_agents(self):
        original = self.doc.read_bytes()
        self.run_pipeline('--dry-run', self.doc)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.doc.read_bytes(), original)
        runs = list((self.root / '.tmp/scratch/research-execute/runs').iterdir())
        self.assertEqual(len(runs), 1)
        for stage in ['review', 'execute']:
            prompt = (runs[0] / f'{stage}-1.prompt.md').read_text()
            self.assertIn(str(self.doc), prompt)
            self.assertNotIn('{{', prompt)

    def test_complete_pipeline_preserves_user_work_and_releases_lock(self):
        self.run_pipeline(self.doc)
        self.assertEqual(self.calls(), ['review', 'execute'])
        self.assertTrue((self.doc.parent / 'DONE' / ('DONE - ' + self.doc.name)).exists())
        self.assertFalse(self.doc.exists())
        self.assertEqual(list((self.latest().parents[1] / 'locks').iterdir()), [])
        self.assertIn('no changes since startup', (self.latest() / 'summary.md').read_text())

    def test_owner_status_stops_then_resumes_implementation(self):
        self.mode('owner')
        self.run_pipeline(self.doc, expected=10)
        self.assertEqual(self.calls(), ['review'])
        run = self.latest()
        self.assertIn('select policy', (run / 'questions.md').read_text())
        (run / 'answers.md').write_text('1. owner: use policy A.\n')
        self.mode('complete')
        self.run_pipeline('--resume', run)
        self.assertEqual(self.calls(), ['review', 'execute'])
        self.assertTrue((run / 'answers-1.md').exists())
        self.assertTrue((run / 'questions-1.md').exists())
        self.assertIn('owner: use policy A.', (run / 'execute-2.prompt.md').read_text())

    def test_review_questions_resume_review_before_implementation(self):
        self.mode('review-question')
        self.run_pipeline(self.doc, expected=10)
        run = self.latest()
        (run / 'answers.md').write_text('1. orchestrator: confirmed from source.\n')
        self.mode('complete')
        self.run_pipeline('--resume', run)
        self.assertEqual(self.calls(), ['review', 'review', 'execute'])

    def test_execution_questions_resume_same_session(self):
        self.mode('execute-question')
        self.run_pipeline(self.doc, expected=10)
        run = self.latest()
        (run / 'answers.md').write_text('1. owner: accepted threshold.\n')
        self.mode('complete')
        self.run_pipeline('--resume', run)
        self.assertEqual(self.calls(), ['review', 'execute', 'execute'])
        self.assertTrue((run / 'execute-2.last.md').exists())

    def test_review_only_needs_only_review_cli(self):
        (self.bin / 'codex').rename(self.bin / 'codex-disabled')
        self.run_pipeline('--stage', 'review', self.doc)
        self.assertEqual(self.calls(), ['review'])
        self.assertTrue(self.doc.with_name('REVIEWED - ' + self.doc.name).exists())

    def test_partial_is_not_complete(self):
        self.mode('partial')
        self.run_pipeline(self.doc, expected=12)
        self.assertTrue(self.doc.with_name('REVIEWED - ' + self.doc.name).exists())

    def test_failed_review_does_not_start_implementation(self):
        self.mode('failed-review')
        self.run_pipeline(self.doc, expected=1)
        self.assertEqual(self.calls(), ['review'])

    def test_completed_document_does_not_restart(self):
        done = self.doc.parent / 'DONE' / ('DONE - ' + self.doc.name)
        done.parent.mkdir()
        self.doc.rename(done)
        self.run_pipeline(done)
        self.assertEqual(self.calls(), [])

    def test_conflicts_and_nested_calls_preserve_document(self):
        original = hashlib.sha256(self.doc.read_bytes()).digest()
        copy = self.doc.with_name('REVIEWED - ' + self.doc.name)
        copy.write_bytes(self.doc.read_bytes())
        self.run_pipeline(self.doc, expected=1)
        self.assertEqual(hashlib.sha256(self.doc.read_bytes()).digest(), original)
        self.env['RESEARCH_EXECUTE_STAGE'] = 'review'
        self.run_pipeline(self.doc, expected=1)
        self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main()
