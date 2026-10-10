#!/usr/bin/env bash
# Tests for scripts/update-upstream.sh against a local origin, with a stand-in
# for the update checker and the GitHub CLI.
set -euo pipefail
script=$(realpath "$(dirname "$0")/../update-upstream.sh")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export APP_ID=eu.nosini.Example APP_NAME=Example
export GIT_CONFIG_GLOBAL=$tmp/gitconfig
git config --global init.defaultBranch main
git config --global user.name Person
git config --global user.email person@example.com

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# gh: record every call; `pr list` prints the open pull request, if any.
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TEST_DIR/gh.log"
case "$1 $2" in
  'pr list') cat "$TEST_DIR/open-pr" 2>/dev/null || true ;;
  'pr create') echo 7 > "$TEST_DIR/open-pr" ;;
esac
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" TEST_DIR=$tmp

# The checker stand-in sets the version in the manifest and adds a release.
# With CONCURRENT_PUSH set, a person pushes to the update branch meanwhile.
cat > "$tmp/checker" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ -n "${CONCURRENT_PUSH:-}" ]]; then
  rm -rf "$TEST_DIR/concurrent"
  git clone -q "$TEST_DIR/origin.git" "$TEST_DIR/concurrent"
  git -C "$TEST_DIR/concurrent" switch -q update/upstream 2>/dev/null \
    || git -C "$TEST_DIR/concurrent" switch -q -c update/upstream
  echo "$CONCURRENT_PUSH" > "$TEST_DIR/concurrent/fix.txt"
  git -C "$TEST_DIR/concurrent" add fix.txt
  git -C "$TEST_DIR/concurrent" commit -qm "$CONCURRENT_PUSH"
  git -C "$TEST_DIR/concurrent" push -q origin update/upstream
fi
if ! grep -qx "version: $1" eu.nosini.Example.yml; then
  sed -i "s/^version: .*/version: $1/" eu.nosini.Example.yml
  sed -i "s|<releases>|<releases>\\n<release version=\"$1\"/>|" eu.nosini.Example.metainfo.xml
  echo "Updated to $1"
fi
EOF
chmod +x "$tmp/checker"

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/seed"
(
  cd "$tmp/seed"
  echo 'version: 1.0' > eu.nosini.Example.yml
  printf '<component>\n<releases>\n<release version="1.0"/>\n</releases>\n</component>\n' \
    > eu.nosini.Example.metainfo.xml
  git add .
  git commit -qm 'Initial commit'
  git push -q origin main
)

run() {
  rm -rf "$tmp/work" "$tmp/output"
  git clone -q "$tmp/origin.git" "$tmp/work"
  (cd "$tmp/work" && GITHUB_OUTPUT=$tmp/output bash "$script" "$tmp/checker" "$1") > "$tmp/run.log"
}
branch_head() {
  git -C "$tmp/origin.git" rev-parse --verify --quiet refs/heads/update/upstream
}

# A new release becomes a branch and a pull request.
run 2.0
head=$(branch_head) || fail 'no update branch'
git -C "$tmp/origin.git" log -1 --format=%s "$head" | grep -qx 'Update Example to 2.0' \
  || fail 'wrong title'
grep -q '^pr create' "$tmp/gh.log" || fail 'no pull request'
grep -qx 'manual=false' "$tmp/output" || fail 'expected manual=false'

# The same release again leaves the branch alone.
run 2.0
[[ "$(branch_head)" == "$head" ]] || fail 'identical update replaced the branch'
grep -q 'already contains' "$tmp/run.log" || fail 'expected "already contains"'

# A fix pushed while the checker runs is not overwritten.
if CONCURRENT_PUSH='Concurrent fix' run 2.5; then
  fail 'replaced a branch that changed during the run'
fi
git -C "$tmp/origin.git" log -1 --format=%s "$(branch_head)" | grep -qx 'Concurrent fix' \
  || fail 'the concurrent fix was overwritten'

# A person fixes the update on its branch; the next release goes on top.
git clone -q -b update/upstream "$tmp/origin.git" "$tmp/fix"
(
  cd "$tmp/fix"
  echo 'fixed' > patch.txt
  git add patch.txt
  git commit -qm 'Fix the patch'
  git push -q origin update/upstream
)
fix=$(git -C "$tmp/fix" rev-parse HEAD)
run 3.0
git -C "$tmp/origin.git" merge-base --is-ancestor "$fix" "$(branch_head)" \
  || fail 'the next update discarded the fix'
git -C "$tmp/origin.git" log -1 --format=%s "$(branch_head)" | grep -qx 'Update Example to 3.0' \
  || fail 'release 3.0 missing on the fixed branch'
grep -qx 'manual=true' "$tmp/output" || fail 'expected manual=true'
grep -q '^pr comment' "$tmp/gh.log" || fail 'no comment on the pull request'

# Nothing new: nothing is pushed.
head=$(branch_head)
run 3.0
[[ "$(branch_head)" == "$head" ]] || fail 'branch changed without an update'
grep -q 'up to date' "$tmp/run.log" || fail 'expected "up to date"'

# A branch created while the checker runs is not overwritten either.
git -C "$tmp/origin.git" branch -D update/upstream > /dev/null
rm "$tmp/open-pr"
if CONCURRENT_PUSH='New branch' run 3.5; then
  fail 'replaced a branch that was created during the run'
fi
git -C "$tmp/origin.git" log -1 --format=%s "$(branch_head)" | grep -qx 'New branch' \
  || fail 'the new branch was overwritten'
echo 7 > "$tmp/open-pr"

# Once the pull request is closed, the next update starts from main again.
rm "$tmp/open-pr"
run 4.0
if git -C "$tmp/origin.git" merge-base --is-ancestor "$fix" "$(branch_head)"; then
  fail 'a closed update branch was continued'
fi
grep -qx 'manual=false' "$tmp/output" || fail 'expected manual=false'

echo 'update-upstream.sh: all tests passed'
