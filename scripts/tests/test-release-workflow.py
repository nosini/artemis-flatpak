#!/usr/bin/env python3
"""Exercise tag classification, publication gates and release commands offline."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/flatpak.yml").read_text())
APP_ID = "eu.nosini.Artemis"


def evaluate(expression, **context):
    """Evaluate the boolean subset used by the workflow's publication gates."""
    expression = expression.strip().removeprefix("${{").removesuffix("}}")
    expression = expression.replace("&&", " and ").replace("||", " or ")
    expression = re.sub(r"!(?!=)", " not ", expression)
    # Context properties may contain hyphens, as in
    # steps.build-cache.outputs.cache-hit.
    expression = re.sub(r"(?<=[\w.])-(?=[\w])", "_", expression)
    cancelled = context.pop("cancelled", False)
    return eval(" ".join(expression.split()),
                {"__builtins__": {}, "true": True, "false": False}, {
                    "startsWith": lambda value, prefix: value.startswith(prefix),
                    "cancelled": lambda: cancelled,
                    **context,
                })


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.env = dict(os.environ, APP_NAME="Artemis", TAG="v1.2026.0101.2",
                        APP_ID=APP_ID)
        # The tag check reads the version from the metainfo.
        (self.directory / f"{APP_ID}.metainfo.xml").write_text(
            '<?xml version="1.0"?>\n'
            f'<component type="desktop-application"><id>{APP_ID}</id>'
            '<releases><release version="1.2026.0101.2" date="2026-01-01"/>'
            '</releases></component>\n'
        )

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

    def test_stable_tag_must_match_the_app_version(self):
        for tag, code in (("v1.2026.0101.2", 0), ("v1.2026.0101.2-2", 0),
                          ("v1.2026.0101.3", 1)):
            with self.subTest(tag=tag):
                result = self.run_step(
                    "setup", "Check the release tag against the app version", TAG=tag,
                )
                self.assertEqual(result.returncode, code, result.stderr)

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

    def test_publication_event_policy(self):
        arches = next(step for step in WORKFLOW["jobs"]["setup"]["steps"]
                      if step.get("id") == "arches")
        # The publish input only exists on manual runs; on every other event
        # it is null, which must not enable publication.
        for event, ref, stable, enabled, requested, expected in (
            ("push", "refs/tags/v1.2026.0101.2", "true", "true", None, True),
            ("push", "refs/tags/v1.2026.0101.2-rc1", "false", "true", None, False),
            ("push", "refs/tags/v1.2026.0101.2", "true", "false", None, False),
            ("push", "refs/heads/main", "", "true", None, False),
            ("workflow_dispatch", "refs/heads/main", "", "true", True, True),
            ("workflow_dispatch", "refs/heads/main", "", "false", True, False),
            ("workflow_dispatch", "refs/heads/main", "", "true", False, False),
            ("workflow_dispatch", "refs/heads/update/upstream", "", "true", True, False),
            ("workflow_dispatch", "refs/tags/v1.2026.0101.2", "true", "true", True, True),
            ("workflow_dispatch", "refs/tags/v1.2026.0101.2-rc1", "false", "true", True, False),
            ("pull_request", "refs/pull/1/merge", "", "true", None, False),
        ):
            with self.subTest(event=event, ref=ref, enabled=enabled,
                              requested=requested):
                actual = evaluate(
                    arches["env"]["PUBLISH"],
                    github=SimpleNamespace(event_name=event, ref=ref),
                    inputs=SimpleNamespace(publish=requested),
                    vars=SimpleNamespace(PUBLISH_FLATPAK=enabled),
                    steps=SimpleNamespace(release=SimpleNamespace(
                        outputs=SimpleNamespace(stable=stable))),
                )
                self.assertEqual(actual, expected)

    def test_publishing_runs_share_a_concurrency_group(self):
        group = WORKFLOW["concurrency"]["group"]
        inner = re.search(r"\${{(.*)}}", group, re.S).group(1)

        def evaluate_group(event, ref, publish=None):
            return "flatpak-" + evaluate(
                "${{" + inner + "}}",
                github=SimpleNamespace(event_name=event, ref=ref),
                inputs=SimpleNamespace(publish=publish),
            )

        # Different refs that can publish must wait for each other.
        self.assertEqual(evaluate_group("push", "refs/tags/v1.2026.0101.2"),
                         "flatpak-publish")
        self.assertEqual(evaluate_group("workflow_dispatch", "refs/heads/main", True),
                         "flatpak-publish")
        # Builds and cache warm-ups must not cancel or delay a publication.
        self.assertEqual(evaluate_group("workflow_dispatch", "refs/heads/main", False),
                         "flatpak-refs/heads/main")
        self.assertEqual(evaluate_group("pull_request", "refs/pull/1/merge"),
                         "flatpak-refs/pull/1/merge")
        self.assertEqual(evaluate_group("push", "refs/heads/topic"),
                         "flatpak-refs/heads/topic")

    def test_release_waits_for_validation_and_required_deployment(self):
        for publish in ("true", "false"):
            defaults = dict(setup="success", build="success",
                            publish="success" if publish == "true" else "skipped",
                            deploy="success" if publish == "true" else "skipped")
            cases = [
                (defaults, "push", "refs/tags/v1.2026.0101.2", False, None, True),
                (defaults, "push", "refs/tags/v1.2026.0101.2-rc1", False, None, True),
                (defaults, "push", "refs/heads/main", False, None, False),
                (defaults, "push", "refs/tags/v1.2026.0101.2", True, None, False),
                (defaults, "workflow_dispatch", "refs/tags/v1.2026.0101.2", False, True, True),
                (defaults, "workflow_dispatch", "refs/tags/v1.2026.0101.2", False, False, False),
            ]
            for job in defaults:
                for result in ("failure", "cancelled", "skipped"):
                    if result != defaults[job]:
                        cases.append((dict(defaults, **{job: result}),
                                      "push", "refs/tags/v1.2026.0101.2", False, None, False))
            for results, event, ref, cancelled, requested, expected in cases:
                with self.subTest(publish=publish, results=results, ref=ref,
                                  event=event, cancelled=cancelled,
                                  requested=requested):
                    needs = SimpleNamespace(**{
                        job: SimpleNamespace(result=result)
                        for job, result in results.items()
                    })
                    needs.setup.outputs = SimpleNamespace(publish=publish)
                    actual = evaluate(
                        WORKFLOW["jobs"]["release"]["if"], needs=needs,
                        inputs=SimpleNamespace(publish=requested),
                        github=SimpleNamespace(event_name=event, ref=ref),
                        cancelled=cancelled,
                    )
                    self.assertEqual(actual, expected)

    def test_runtimes_are_made_updatable_before_the_build(self):
        names = [step.get("name") or step.get("uses", "")
                 for step in WORKFLOW["jobs"]["build"]["steps"]]
        builder = next(i for i, name in enumerate(names) if "/flatpak-builder@" in name)
        self.assertLess(names.index("Make the preinstalled runtimes updatable"), builder)

    def test_cache_covers_the_pinned_dependencies(self):
        steps = {step["name"]: step for step in WORKFLOW["jobs"]["build"]["steps"]
                 if step.get("name")}
        restore = steps["Restore the Flatpak build cache"]["with"]
        self.assertTrue(restore["key"].startswith("${{ env.CACHE_PREFIX }}-"))
        self.assertIn("nuget-sources.json", restore["key"])
        self.assertNotIn("github.run_", restore["key"])
        self.assertTrue(restore["restore-keys"].startswith("${{ env.CACHE_PREFIX }}-"))
        builder = next(step for step in WORKFLOW["jobs"]["build"]["steps"]
                       if "/flatpak-builder@" in step.get("uses", ""))
        # This app compiles managed .NET code, so keep ccache enabled.
        self.assertIs(builder["with"]["cache"], True)
        self.assertIs(builder["with"]["restore-cache"], False)
        self.assertIs(builder["with"]["save-cache"], False)
        self.assertEqual(builder["with"]["state-dir"], ".flatpak-builder")

    def test_cache_is_saved_after_the_tested_repository_is_uploaded(self):
        steps = WORKFLOW["jobs"]["build"]["steps"]
        names = [step["name"] for step in steps if step.get("name")]
        self.assertLess(names.index("Check the installed app against its runtime"),
                        names.index("Upload the tested repository"))
        self.assertLess(names.index("Upload the tested repository"),
                        names.index("Save the tested Flatpak build cache"))
        save = next(step for step in steps
                    if step.get("name") == "Save the tested Flatpak build cache")
        for ref_name, hit, expected in (("main", "false", True),
                                        ("main", "true", False),
                                        ("v1.2026.0101.2", "false", False),
                                        ("topic", "false", False)):
            with self.subTest(ref=ref_name, hit=hit):
                self.assertEqual(evaluate(
                    save["if"],
                    steps=SimpleNamespace(build_cache=SimpleNamespace(
                        outputs=SimpleNamespace(cache_hit=hit))),
                    github=SimpleNamespace(
                        ref_name=ref_name,
                        event=SimpleNamespace(repository=SimpleNamespace(
                            default_branch="main"))),
                ), expected)

    def test_verification_pulls_every_signed_commit(self):
        script = next(step for step in WORKFLOW["jobs"]["publish"]["steps"]
                      if step.get("name") == "Verify the signed repository")["run"]
        # App and extension commits must be checked, not only the summary, and
        # a repository without them must fail the step.
        self.assertIn("--set=gpg-verify=true", script)
        self.assertIn('pull signed-test "${refs[@]}"', script)
        self.assertIn("has no app or runtime refs", script)
        self.assertIn("appstream2/$arch", script)

    def test_announcement_waits_for_deployment_and_uses_separate_credentials(self):
        job = WORKFLOW["jobs"]["announce"]
        self.assertEqual(job["needs"], "deploy")
        self.assertNotIn("if", job)  # Default success() skips failed/skipped deployment.
        self.assertEqual(job["permissions"], {})
        self.assertEqual(len(job["steps"]), 1)
        step = job["steps"][0]
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ secrets.FLATPAK_REPO_DISPATCH_TOKEN }}")
        self.assertNotIn("uses", step)  # No checkout or build with the dispatch token.

    def test_announcement_dispatches_once_and_reports_missing_or_rejected_credentials(self):
        binary = self.directory / "gh"
        binary.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['GH_LOG'], 'a') as log:\n"
            "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "sys.exit(int(os.environ.get('GH_EXIT', '0')))\n"
        )
        binary.chmod(0o755)
        log = self.directory / "gh.jsonl"
        env = dict(PATH=f"{self.directory}:{os.environ['PATH']}", GH_LOG=str(log))
        step = "Announce the publication to the shared remote"
        missing = self.run_step("announce", step, GH_TOKEN="", **env)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("::error::Set FLATPAK_REPO_DISPATCH_TOKEN", missing.stdout)
        self.assertFalse(log.exists())
        for status in (0, 1):
            result = self.run_step("announce", step, GH_TOKEN="fixture-token",
                                   GH_EXIT=str(status), **env)
            self.assertEqual(result.returncode, status)
            self.assertNotIn("fixture-token", result.stdout + result.stderr)
        commands = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(commands, [["api", "--method", "POST",
                                     "repos/nosini/flatpak-repo/dispatches",
                                     "-f", "event_type=app-published"]] * 2)

    def test_triggers_checkout_and_release_permissions(self):
        triggers = WORKFLOW[True]  # PyYAML's YAML 1.1 parses `on` as True.
        self.assertEqual(triggers["push"], {"tags": ["v*"]})
        self.assertIn("pull_request", triggers)
        self.assertIn("workflow_dispatch", triggers)
        self.assertNotIn("release", triggers)
        for job in ("setup", "build", "publish"):
            checkout = WORKFLOW["jobs"][job]["steps"][0]
            self.assertEqual(checkout["with"]["ref"], "${{ github.sha }}")
        release = WORKFLOW["jobs"]["release"]
        self.assertEqual(set(release["needs"]), {"setup", "build", "publish", "deploy"})
        self.assertEqual(release["permissions"], {"contents": "write"})
        self.assertEqual(release["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertEqual(release["env"]["GH_REPO"], "${{ github.repository }}")

    def test_auto_merge_does_not_dispatch_publication(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/update.yml").read_text())
        merge = next(step for step in workflow["jobs"]["check"]["steps"]
                     if step.get("name") == "Merge the update after a successful build")
        self.assertIn("gh pr merge", merge["run"])
        self.assertNotIn("gh workflow run", merge["run"])


if __name__ == "__main__":
    unittest.main()
