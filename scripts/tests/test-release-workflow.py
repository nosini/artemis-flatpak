#!/usr/bin/env python3
"""Exercise tag classification, publication gates and release commands offline."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from types import SimpleNamespace as NS
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/flatpak.yml").read_text())


def evaluate(expression, **context):
    """Evaluate the boolean subset used by the workflow's publication gates."""
    expression = expression.strip().removeprefix("${{").removesuffix("}}")
    expression = re.sub(r"!(?!=)", "not ", expression.replace("&&", "and").replace("||", "or"))
    return eval(f"({expression})", {"__builtins__": {}},
                dict(context, startsWith=lambda value, prefix: value.startswith(prefix)))


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.env = dict(os.environ, APP_NAME="Artemis", TAG="v1.2026.0101.2")

    def run_step(self, job, name, **env):
        step = next(step for step in WORKFLOW["jobs"][job]["steps"]
                    if step.get("name") == name)
        return subprocess.run(
            ["bash", "-e", "-o", "pipefail", "-c", step["run"]],
            cwd=self.directory, env=dict(self.env, **env),
            capture_output=True, text=True,
        )

    def test_tag_classification(self):
        for tag, stable in (
            ("v1.2026.0101.2", True), ("v1.2026.0101.2-1", True),
            ("v1.2026.0101.2-12", True), ("v2.2027.0202.1", True),
            ("v1.2026.0101.2-rc1", False), ("v1.2026.0101.2-beta.2", False),
            ("v1.2026.0101.2rc1", False), ("v1.2026.0101.2-", False),
            ("v1.2026.0101.2-1rc1", False), ("v1.2.3", False),
        ):
            with self.subTest(tag=tag):
                output = self.directory / "output"
                result = self.run_step(
                    "setup", "Classify the release tag",
                    TAG=tag, GITHUB_OUTPUT=str(output),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(), f"stable={str(stable).lower()}\n")
                output.unlink()

    def test_publication_requires_stable_tag_or_manual_main(self):
        expression = next(step["env"]["PUBLISH"] for step in WORKFLOW["jobs"]["setup"]["steps"]
                          if step.get("name") == "Select architectures")
        for event, ref, stable, enabled, expected in (
            ("push", "refs/tags/v1.2026.0101.2", "true", "true", True),
            ("push", "refs/tags/v1.2026.0101.2-rc1", "false", "true", False),
            ("push", "refs/tags/v1.2026.0101.2", "true", "false", False),
            ("push", "refs/heads/main", "", "true", False),
            ("workflow_dispatch", "refs/heads/main", "", "true", True),
            ("workflow_dispatch", "refs/heads/update/upstream", "", "true", False),
            ("workflow_dispatch", "refs/tags/v1.2026.0101.2-rc1", "false", "true", False),
            ("pull_request", "refs/pull/1/merge", "", "true", False),
        ):
            with self.subTest(event=event, ref=ref, enabled=enabled):
                self.assertEqual(evaluate(
                    expression, github=NS(event_name=event, ref=ref),
                    steps=NS(release=NS(outputs=NS(stable=stable))),
                    vars=NS(PUBLISH_FLATPAK=enabled),
                ), expected)

    def test_release_waits_for_validation_and_required_deployment(self):
        expression = WORKFLOW["jobs"]["release"]["if"]
        for publish, setup, build, signing, deploy, cancelled, ref, expected in (
            ("true", "success", "success", "success", "success", False, "refs/tags/v1", True),
            ("false", "success", "success", "skipped", "skipped", False, "refs/tags/v1-rc1", True),
            ("true", "failure", "skipped", "skipped", "skipped", False, "refs/tags/v1", False),
            ("true", "success", "failure", "skipped", "skipped", False, "refs/tags/v1", False),
            ("true", "success", "success", "failure", "skipped", False, "refs/tags/v1", False),
            ("true", "success", "success", "success", "failure", False, "refs/tags/v1", False),
            ("true", "success", "success", "skipped", "skipped", False, "refs/tags/v1", False),
            ("true", "success", "success", "success", "skipped", False, "refs/tags/v1", False),
            ("false", "success", "failure", "skipped", "skipped", False, "refs/tags/v1", False),
            ("true", "success", "success", "success", "success", True, "refs/tags/v1", False),
            ("true", "success", "success", "success", "success", False, "refs/heads/main", False),
        ):
            with self.subTest(publish=publish, build=build, signing=signing, deploy=deploy, ref=ref):
                self.assertEqual(evaluate(
                    expression, github=NS(ref=ref), cancelled=lambda: cancelled,
                    needs=NS(setup=NS(result=setup, outputs=NS(publish=publish)),
                             build=NS(result=build), publish=NS(result=signing),
                             deploy=NS(result=deploy)),
                ), expected)

    def release_commands(self, *, stable="true", exists="false", fail="", bundle=True):
        if bundle:
            bundles = self.directory / "bundles"
            bundles.mkdir()
            (bundles / "artemis-x86_64.flatpak").touch()
        binary = self.directory / "gh"
        binary.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "args = sys.argv[1:]\n"
            "if args[:2] == ['release', 'view']:\n"
            "    sys.exit(0 if os.environ['RELEASE_EXISTS'] == 'true' else 1)\n"
            "with open(os.environ['GH_LOG'], 'a') as log:\n"
            "    log.write(json.dumps(args) + '\\n')\n"
            "sys.exit(1 if args[1] == os.environ['RELEASE_FAIL'] else 0)\n"
        )
        binary.chmod(0o755)
        log = self.directory / "gh.jsonl"
        result = self.run_step(
            "release", "Create the release and upload the tested bundles",
            PATH=f"{self.directory}:{os.environ['PATH']}", STABLE=stable,
            RELEASE_EXISTS=exists, RELEASE_FAIL=fail, GH_LOG=str(log),
        )
        commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, commands

    def test_stable_release_includes_bundle_and_verifies_existing_tag(self):
        result, commands = self.release_commands()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(commands), 1)
        args = commands[0]
        self.assertEqual(args[:3], ["release", "create", "v1.2026.0101.2"])
        self.assertIn("--verify-tag", args)
        self.assertIn("--generate-notes", args)
        self.assertIn("bundles/artemis-x86_64.flatpak", args)
        self.assertNotIn("--prerelease", args)

    def test_prerelease_cannot_become_latest(self):
        result, commands = self.release_commands(stable="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--prerelease", commands[0])
        self.assertIn("--latest=false", commands[0])

    def test_retry_updates_assets_and_finishes_interrupted_draft(self):
        result, commands = self.release_commands(exists="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([args[1] for args in commands], ["upload", "edit"])
        self.assertIn("--clobber", commands[0])
        self.assertIn("bundles/artemis-x86_64.flatpak", commands[0])
        self.assertIn("--draft=false", commands[1])

    def test_retry_keeps_existing_prerelease_out_of_latest(self):
        result, commands = self.release_commands(exists="true", stable="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([args[1] for args in commands], ["edit", "upload", "edit"])
        self.assertIn("--prerelease", commands[0])
        self.assertIn("--latest=false", commands[0])

    def test_creation_failure_fails_the_step(self):
        result, _ = self.release_commands(fail="create")
        self.assertNotEqual(result.returncode, 0)

    def test_upload_failure_does_not_publish_existing_draft(self):
        result, commands = self.release_commands(exists="true", fail="upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([args[1] for args in commands], ["upload"])

    def test_missing_bundle_does_not_create_release(self):
        result, commands = self.release_commands(bundle=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, [])


if __name__ == "__main__":
    unittest.main()
