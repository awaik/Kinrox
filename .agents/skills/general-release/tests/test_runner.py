"""Exercise the release runner's state transitions without live agents, signing, or publication.

Each test builds a throwaway Git repository (with a bare origin) inside the ignored scratch
directory, copies the runner into it, and puts fake `agy`, `gh`, and build tools first on
PATH. The Kinrox checkout itself is never touched. Fixtures stay in the scratch directory for
inspection.
"""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

SKILL = Path(__file__).resolve().parents[1]
PROJECT = SKILL.parents[2]
ARTIFACTS = PROJECT / '.tmp/scratch/general-release/validation'

# The fake agy answers the review in text and the apply and release stages with one JSON object
# (`--output-format json`), like the real CLI.
AGY = '''#!/usr/bin/env python3
import json, os, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
stage = os.environ.get('GENERAL_RELEASE_STAGE', '')
resume = '--conversation' in args
with Path(os.environ['FAKE_LOG']).open('a') as log:
    log.write('agy ' + stage + (' resume' if resume else '') + ' ' + args[args.index('--model') + 1] + '\\n')
if stage == 'review':
    print('RESULT: CRITICAL 0 / MAJOR 0 / MINOR 0 - ready')
    raise SystemExit(0)
with (Path(os.environ['FAKE_LOG']).parent / 'agy-args.txt').open('a') as log:
    log.write(' '.join(args[:-1]) + '\\n')
mode = Path(os.environ['FAKE_MODE']).read_text().strip()
run = (Path.cwd() / '.tmp/scratch/general-release/latest').resolve()
if stage == 'apply' and mode.startswith('apply-idle'):
    # Finishes, then hangs on agy's idle marker; '-active' keeps its cli-*.log busy and completes.
    agy_log = Path.cwd() / '.tmp/antigravity-cli/log/cli-fake.log'
    agy_log.parent.mkdir(parents=True, exist_ok=True)
    agy_handle = agy_log.open('a')
    agy_handle.write('INFO started\\n'); agy_handle.flush()
    print('root agent idle; waiting for 1 background task(s) to finish', file=sys.stderr, flush=True)
    if mode == 'apply-idle-hang':
        time.sleep(30)
    for _ in range(10):
        time.sleep(0.3)
        agy_handle.write('INFO Monitor run_command FINISHED\\n'); agy_handle.flush()
if stage == 'apply':
    if mode == 'apply-hang':
        child = subprocess.Popen(['sleep', '60'])
        (Path(os.environ['FAKE_LOG']).parent / 'pids.txt').write_text(f'{os.getpid()} {child.pid}')
        time.sleep(60)
    if mode == 'apply-question' and not resume:
        (run / 'questions.md').write_text('1. Which behavior is intended?')
        text = 'RESULT: QUESTIONS - one question'
    else:
        text = 'RESULT: APPLIED 0 / REJECTED 0 - checks green'
else:
    (run / 'release.env').write_text('FINALIZED=1\\n')
    text = 'RESULT: PARTIAL - Pages run not verified' if mode == 'release-partial' else 'RESULT: RELEASED - published'
status = 'ERROR' if mode in ('agy-error', 'apply-error') else 'SUCCESS'
print(json.dumps({'conversation_id': 'fake-conv', 'status': status, 'response': text}))
'''
GH = '#!/bin/sh\nexit 0\n'
APPCAST_STUB = '#!/usr/bin/env python3\nraise SystemExit(0)\n'


def write_exec(path, text):
    path.write_text(text)
    path.chmod(0o755)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        name = self.id().rsplit('.', 1)[-1]
        self.base = ARTIFACTS / name
        shutil.rmtree(self.base, ignore_errors=True)
        self.repo = self.base / 'repo'
        self.origin = self.base / 'origin.git'
        self.bin = self.base / 'bin'
        self.repo.mkdir(parents=True)
        self.bin.mkdir()
        self.env = dict(os.environ)
        self.env.update({
            'PATH': f'{self.bin}:{os.environ["PATH"]}',
            'FAKE_LOG': str(self.base / 'calls.txt'),
            'FAKE_MODE': str(self.base / 'mode.txt'),
            'GIT_AUTHOR_NAME': 'Test', 'GIT_AUTHOR_EMAIL': 'test@example.invalid',
            'GIT_COMMITTER_NAME': 'Test', 'GIT_COMMITTER_EMAIL': 'test@example.invalid',
        })
        for var in ('GENERAL_RELEASE_STAGE', 'RESEARCH_EXECUTE_STAGE', 'AGY_MODEL', 'APPLE_TEAM_ID',
                    'APPLE_SIGNING_IDENTITY', 'NOTARYTOOL_PROFILE', 'RELEASE_AGENT', 'APPLY_EFFORT',
                    'RELEASE_EFFORT'):
            self.env.pop(var, None)
        write_exec(self.bin / 'agy', AGY)
        write_exec(self.bin / 'gh', GH)
        for tool in ('xcodebuild', 'xcrun', 'xcodegen', 'hdiutil', 'codesign'):
            write_exec(self.bin / tool, '#!/bin/sh\nexit 0\n')
        (self.base / 'mode.txt').write_text('ok')
        skill = self.repo / '.agents/skills/general-release'
        skill.mkdir(parents=True)
        shutil.copy(SKILL / 'run.sh', skill / 'run.sh')
        for part in ('lib', 'bin'):
            shutil.copytree(PROJECT / '.agents' / part, self.repo / '.agents' / part,
                            ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copytree(SKILL / 'prompts', skill / 'prompts')
        fingerprint = self.repo / '.agents/skills/research-execute'
        fingerprint.mkdir(parents=True)
        shutil.copy(PROJECT / '.agents/skills/research-execute/fingerprint.mjs', fingerprint / 'fingerprint.mjs')
        (self.repo / 'Config').mkdir()
        (self.repo / 'Config/PlayerMac.xcconfig').write_text(
            'MARKETING_VERSION = 0.5.8\nCURRENT_PROJECT_VERSION = 18\n')
        (self.repo / 'Scripts').mkdir()
        write_exec(self.repo / 'Scripts/update-appcast.py', APPCAST_STUB)
        (self.repo / 'site').mkdir()
        (self.repo / 'site/appcast.xml').write_text('<rss/>\n')
        (self.repo / '.gitignore').write_text('.tmp/\ndist/\n')
        self.git('init', '-q', '-b', 'main')
        self.git('add', '-A')
        self.git('-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'Initial')
        subprocess.run(['git', 'init', '-q', '--bare', str(self.origin)], check=True, env=self.env)
        self.git('remote', 'add', 'origin', str(self.origin))
        self.git('push', '-q', 'origin', 'main')
        self.git('fetch', '-q', 'origin')
        (self.repo / 'user-change.txt').write_text('uncommitted package content\n')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True, env=self.env,
                              capture_output=True, text=True).stdout

    def run_script(self, *args, env=None):
        merged = dict(self.env)
        merged.update(env or {})
        return subprocess.run(['bash', str(self.repo / '.agents/skills/general-release/run.sh'), *args],
                              cwd=self.repo, env=merged, capture_output=True, text=True)

    def new_run(self, version='0.5.9', build='19'):
        result = self.run_script('--version', version, '--build', build)
        return result, (self.repo / '.tmp/scratch/general-release/latest').resolve()

    def state(self, run):
        return dict(line.split('=', 1) for line in (run / 'state.env').read_text().splitlines())

    def calls(self):
        return (self.base / 'calls.txt').read_text().splitlines() if (self.base / 'calls.txt').exists() else []

    def release_env(self, agent='agy'):
        return {'APPLE_TEAM_ID': 'TEAM', 'APPLE_SIGNING_IDENTITY': 'IDENTITY', 'NOTARYTOOL_PROFILE': 'PROFILE',
                'RELEASE_AGENT': agent}

    def agent_released(self):
        return any(call.startswith('agy release') for call in self.calls())

    def approve(self, run):
        (run / 'control.md').write_text('Checked.\nVERDICT: RELEASE\n')

    def test_new_run_stops_for_control(self):
        result, run = self.new_run()
        self.assertEqual(result.returncode, 11, result.stderr)
        self.assertTrue((run / 'review.md').is_file())
        self.assertTrue((run / 'apply-1.last.md').is_file())
        self.assertEqual(self.state(run)['PENDING_STAGE'], 'control')
        self.assertEqual(self.state(run)['VERSION'], '0.5.9')
        self.assertIn('agy review Gemini 4 Carbon (High)', self.calls())
        self.assertIn('agy apply Gemini 4 Neon (High)', self.calls())
        rendered = (run / 'apply-1.prompt.md').read_text()
        self.assertIn('Kinrox Mac 0.5.9 (build 19)', rendered)
        self.assertNotIn('{{', rendered)

    def test_dry_run_renders_every_prompt_without_agents(self):
        result = self.run_script('--version', '0.5.9', '--build', '19', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        run = next((self.repo / '.tmp/scratch/general-release/runs').glob('dry-run-*'))
        for name in ('review', 'apply-1', 'release-1'):
            text = (run / f'{name}.prompt.md').read_text()
            self.assertNotIn('{{', text, name)
            self.assertIn('0.5.9', text, name)
        self.assertEqual(self.calls(), [])

    def test_forbidden_agy_model_is_refused(self):
        for model in ('Gemini 4 Argon (High)', 'Gemini 4 Carbon (Low)', 'Gemini 3.8 Flash (High)'):
            result = self.run_script('--version', '0.5.9', '--build', '19', '--dry-run', env={'AGY_MODEL': model})
            self.assertEqual(result.returncode, 1, model)
            self.assertIn('Forbidden agy model', result.stderr)

    def test_version_and_build_must_increase(self):
        for version, build, code in (('0.5.8', '19', 1), ('0.5.9', '18', 1), ('0.5.7', '19', 1),
                                     ('0.5', '19', 2), ('0.5.9', '0', 2)):
            result = self.run_script('--version', version, '--build', build, '--dry-run')
            self.assertEqual(result.returncode, code, (version, build, result.stderr))
        self.assertEqual(self.run_script('--dry-run').returncode, 2)

    def test_existing_tag_is_refused(self):
        self.git('tag', 'v0.5.9')
        result = self.run_script('--version', '0.5.9', '--build', '19')
        self.assertEqual(result.returncode, 1)
        self.assertIn('already exists', result.stderr)

    def test_extra_branch_stops_with_13(self):
        self.git('branch', 'side')
        result = self.run_script('--version', '0.5.9', '--build', '19')
        self.assertEqual(result.returncode, 13)
        self.assertEqual(self.calls(), [])

    def test_nothing_to_release(self):
        (self.repo / 'user-change.txt').unlink()
        result = self.run_script('--version', '0.5.9', '--build', '19')
        self.assertEqual(result.returncode, 0)
        self.assertIn('Nothing to release', result.stdout)

    def test_nested_run_is_blocked(self):
        result = self.run_script('--version', '0.5.9', '--build', '19', env={'GENERAL_RELEASE_STAGE': 'apply'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('Nested', result.stderr)

    def test_questions_then_resume_continues_the_session(self):
        (self.base / 'mode.txt').write_text('apply-question')
        result, run = self.new_run()
        self.assertEqual(result.returncode, 10, result.stderr)
        self.assertTrue((run / 'questions.md').is_file())
        (run / 'answers.md').write_text('1. owner: the first behavior.\n')
        result = self.run_script('--resume', str(run))
        self.assertEqual(result.returncode, 11, result.stderr)
        self.assertIn('agy apply resume Gemini 4 Neon (High)', self.calls())
        resumed = (run / 'apply-2.prompt.md').read_text()
        self.assertIn('Kinrox Mac 0.5.9 (build 19)', resumed)  # full prompt, not only the answers
        self.assertIn('owner: the first behavior.', resumed)
        self.assertTrue((run / 'answers-1.md').is_file())
        self.assertTrue((run / 'questions-1.md').is_file())
        self.assertEqual(self.state(run)['ROUND'], '2')

    def test_release_needs_verdict(self):
        _, run = self.new_run()
        result = self.run_script('--release', str(run), env=self.release_env())
        self.assertEqual(result.returncode, 1)
        self.assertIn('VERDICT: RELEASE', result.stderr)
        self.assertFalse(self.agent_released())

    def test_release_needs_signing_environment(self):
        _, run = self.new_run()
        self.approve(run)
        result = self.run_script('--release', str(run))
        self.assertEqual(result.returncode, 1)
        self.assertIn('APPLE_TEAM_ID', result.stderr)
        self.assertFalse(self.agent_released())

    def test_release_refuses_new_commits_after_review(self):
        _, run = self.new_run()
        self.approve(run)
        self.git('add', '-A')
        self.git('-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'Late change')
        result = self.run_script('--release', str(run), env=self.release_env())
        self.assertEqual(result.returncode, 1)
        self.assertIn('HEAD changed', result.stderr)

    def test_release_success_and_single_use(self):
        _, run = self.new_run()
        self.approve(run)
        result = self.run_script('--release', str(run), env=self.release_env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('agy release Gemini 4 Neon (Medium)', self.calls())
        self.assertEqual(self.state(run)['PENDING_STAGE'], 'done')
        self.assertTrue((run / 'git-status-release.txt').is_file())
        self.assertIn('user-change.txt', (run / 'git-status-release.txt').read_text())
        again = self.run_script('--release', str(run), env=self.release_env())
        self.assertEqual(again.returncode, 1)

    def test_partial_release_exits_12_and_resumes_only_with_answers(self):
        (self.base / 'mode.txt').write_text('release-partial')
        _, run = self.new_run()
        self.approve(run)
        result = self.run_script('--release', str(run), env=self.release_env())
        self.assertEqual(result.returncode, 12)
        self.assertEqual(self.state(run)['PENDING_STAGE'], 'release')
        self.assertEqual(self.run_script('--resume', str(run)).returncode, 1)
        (self.base / 'mode.txt').write_text('ok')
        (run / 'answers.md').write_text('1. orchestrator: Pages run verified manually.\n')
        result = self.run_script('--resume', str(run))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('agy release resume Gemini 4 Neon (Medium)', self.calls())
        self.assertEqual(self.state(run)['PENDING_STAGE'], 'done')


    def test_apply_defaults_to_agy_neon_high(self):
        _, run = self.new_run()
        args = (self.base / 'agy-args.txt').read_text()
        self.assertTrue(args.startswith('--dangerously-skip-permissions --model Gemini 4 Neon (High) --output-format json'), args)
        self.assertIn('RESULT: APPLIED', (run / 'apply-1.last.md').read_text())
        self.assertEqual(self.state(run)['APPLY_SESSION'], 'agy:fake-conv')
        self.assertIn('apply agy Gemini 4 Neon (High); release orchestrator', (run / 'summary.md').read_text())

    def test_effort_selects_matching_neon_level(self):
        result = self.run_script('--version', '0.5.9', '--build', '19', '--dry-run',
                                 env={'APPLY_EFFORT': 'xhigh', 'RELEASE_AGENT': 'agy'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('agy --model "Gemini 4 Neon (XHigh)" -p <apply-1.prompt.md>', result.stderr)
        self.assertIn('agy --model "Gemini 4 Neon (Medium)" -p <release-1.prompt.md>', result.stderr)
        for env in ({'APPLY_EFFORT': 'max'}, {'RELEASE_AGENT': 'agy', 'RELEASE_EFFORT': 'ultra'}):
            result = self.run_script('--version', '0.5.9', '--build', '19', '--dry-run', env=env)
            self.assertEqual(result.returncode, 1, env)
            self.assertIn('_EFFORT must be', result.stderr)

    def test_failed_agy_status_is_not_released(self):
        _, run = self.new_run()
        self.approve(run)
        (self.base / 'mode.txt').write_text('agy-error')
        result = self.run_script('--release', str(run), env=self.release_env())
        self.assertEqual(result.returncode, 12, result.stderr)
        self.assertIn('Exit code: 1', (run / 'summary.md').read_text())

    def test_dry_run_renders_orchestrator_release_checklist(self):
        result = self.run_script('--version', '0.5.9', '--build', '19', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        run = next((self.repo / '.tmp/scratch/general-release/runs').glob('dry-run-*'))
        text = (run / 'release-1.prompt.md').read_text()
        self.assertIn('Orchestrator release checklist', text)
        self.assertIn('--finish', text)

    def test_orchestrator_release_hands_off_and_finishes(self):
        _, run = self.new_run()
        self.approve(run)
        result = self.run_script('--release', str(run), env=self.release_env('orchestrator'))
        self.assertEqual(result.returncode, 14, result.stderr)
        self.assertFalse(self.agent_released())
        state = self.state(run)
        self.assertEqual((state['PENDING_STAGE'], state['RELEASE_RUNNER']), ('release', 'orchestrator'))
        prompt = (run / 'release-2.prompt.md').read_text()
        self.assertIn('Orchestrator release checklist', prompt)
        self.assertIn(str(run / 'release-2.last.md'), prompt)
        self.assertNotIn('{{', prompt)
        self.assertEqual(self.run_script('--release', str(run), env=self.release_env('orchestrator')).returncode, 1)
        self.assertEqual(self.run_script('--finish', str(run)).returncode, 1)  # no answer yet
        (run / 'answers.md').write_text('1. orchestrator: n/a\n')
        refused = self.run_script('--resume', str(run))
        self.assertEqual(refused.returncode, 1)
        self.assertIn('--finish', refused.stderr)
        (run / 'answers.md').unlink()
        (run / 'release-2.last.md').write_text('Pages pending.\nRESULT: PARTIAL - Pages run not verified\n')
        self.assertEqual(self.run_script('--finish', str(run)).returncode, 12)
        self.assertEqual(self.state(run)['PENDING_STAGE'], 'release')
        (run / 'release-2.last.md').write_text('All verified.\nRESULT: RELEASED - published\n')
        result = self.run_script('--finish', str(run))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state(run)['PENDING_STAGE'], 'done')
        self.assertEqual(self.run_script('--finish', str(run)).returncode, 1)
        self.assertFalse(self.agent_released())

    def test_default_release_agent_is_orchestrator(self):
        _, run = self.new_run()
        self.approve(run)
        env = self.release_env()
        del env['RELEASE_AGENT']
        self.assertEqual(self.run_script('--release', str(run), env=env).returncode, 14)

    def test_failed_apply_does_not_advance_to_control(self):
        (self.base / 'mode.txt').write_text('apply-error')
        result, run = self.new_run()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.state(run)['PENDING_STAGE'], 'apply')
        self.assertIn('Exit code: 1', (run / 'summary.md').read_text())

    def test_apply_timeout_stops_agent_process_group(self):
        (self.base / 'mode.txt').write_text('apply-hang')
        result = self.run_script('--version', '0.5.9', '--build', '19', env={'AGENT_TIMEOUT': '1'})
        run = (self.repo / '.tmp/scratch/general-release/latest').resolve()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.state(run)['PENDING_STAGE'], 'apply')
        self.assertIn('Timed out after 1s', (run / 'apply-1.log').read_text())
        for pid in map(int, (self.base / 'pids.txt').read_text().split()):
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        self.assertEqual(
            self.run_script('--version', '0.5.9', '--build', '19', '--dry-run', env={'AGENT_TIMEOUT': '0'}).returncode,
            1)

    def test_idle_watchdog_stops_hung_apply_without_retry(self):
        (self.base / 'mode.txt').write_text('apply-idle-hang')
        result = self.run_script('--version', '0.5.9', '--build', '19', env={'AGY_IDLE_STOP_SECONDS': '1'})
        run = (self.repo / '.tmp/scratch/general-release/latest').resolve()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.state(run)['PENDING_STAGE'], 'apply')
        log = (run / 'apply-1.log').read_text()
        self.assertIn('[watchdog] agy idle for', log)
        self.assertIn('stopped (SIGTERM)', log)
        self.assertEqual([c for c in self.calls() if c.startswith('agy apply')], ['agy apply Gemini 4 Neon (High)'])

    def test_idle_watchdog_keeps_apply_with_activity(self):
        (self.base / 'mode.txt').write_text('apply-idle-active')
        result = self.run_script('--version', '0.5.9', '--build', '19', env={'AGY_IDLE_STOP_SECONDS': '1'})
        run = (self.repo / '.tmp/scratch/general-release/latest').resolve()
        self.assertEqual(result.returncode, 11, result.stderr)
        self.assertNotIn('[watchdog]', (run / 'apply-1.log').read_text())

    def test_unknown_release_agent_is_refused(self):
        for agent in ('gemini', 'codex'):
            result = self.run_script('--version', '0.5.9', '--build', '19', '--dry-run', env={'RELEASE_AGENT': agent})
            self.assertEqual(result.returncode, 1)
            self.assertIn('RELEASE_AGENT', result.stderr)


if __name__ == '__main__':
    unittest.main()
