#!/usr/bin/env bash
# Run the update checker and propose what it changes as a pull request from
# the update branch, then start the Flatpak build of that branch.
# Usage: update-upstream.sh CHECKER-COMMAND...
#
# While the branch has an open pull request with commits from anyone but the
# bot, such as fixed patches or regenerated dependencies, new updates are
# added on top of it and it is left for review. Otherwise the branch is
# replaced with a fresh one from the current checkout.
set -euo pipefail

: "${APP_ID:?}"
: "${APP_NAME:?}"
: "${BRANCH:=update/upstream}"
log=${CHECKER_LOG:-$(mktemp)}
output=${GITHUB_OUTPUT:-/dev/null}
bot_email='41898282+github-actions[bot]@users.noreply.github.com'
git config user.name 'github-actions[bot]'
git config user.email "$bot_email"

# ls-remote exits with 2 when the branch doesn't exist; anything else is an
# error, which must not lead to replacing a branch that may hold fixes.
pending=true
git ls-remote --exit-code --heads origin "$BRANCH" > /dev/null || {
  status=$?
  (( status == 2 )) || exit "$status"
  pending=false
}
manual=false
# The branch may only be replaced if it is still where it was when fetched
# (or still missing), so pushes made while the checker runs are never lost.
lease=
if [[ "$pending" == true ]]; then
  git fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
  lease=$(git rev-parse "origin/$BRANCH")
  pr=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[].number')
  authors=$(git log --format=%ae "HEAD..origin/$BRANCH")
  if [[ -n "$pr" && -n "$authors" ]] && grep -qvxF "$bot_email" <<< "$authors"; then
    manual=true
    git switch --quiet -c "$BRANCH" "origin/$BRANCH"
    echo "$BRANCH has changes from people; adding to it."
  fi
fi

"$@" 2>&1 | tee "$log"

if git diff --quiet; then
  echo 'All sources are up to date.'
  exit 0
fi
# Leave an identical pending update alone instead of rebuilding it.
if [[ "$manual" == false && "$pending" == true ]] && git diff --quiet "origin/$BRANCH"; then
  echo "$BRANCH already contains this update."
  exit 0
fi

version=$(sed -n 's/.*<release version="\([^"]*\)".*/\1/p' "$APP_ID.metainfo.xml" | head -1)
if git diff --quiet -- "$APP_ID.metainfo.xml"; then
  title="Update $APP_NAME sources"
else
  title="Update $APP_NAME to $version"
fi
{
  echo 'flatpak-external-data-checker found these changes:'
  echo
  echo '```'
  grep -vE '^\s*$' "$log" | tail -n 40
  echo '```'
  echo
  echo 'Check the build of this branch, and try its bundle artifact, before merging.'
} > "${log}.body"

if [[ "$manual" == true ]]; then
  git commit -qam "$title"
  git push --quiet origin "$BRANCH"
  # Keep the description, which may have notes; report in a comment.
  gh pr edit "$BRANCH" --title "$title"
  gh pr comment "$BRANCH" --body-file "${log}.body"
else
  git switch --quiet -c "$BRANCH"
  git commit -qam "$title"
  git push --quiet --force-with-lease="refs/heads/$BRANCH:$lease" origin "$BRANCH" || {
    echo "$BRANCH changed while checking for updates; leaving it alone." >&2
    exit 1
  }
  if [[ -z "$(gh pr list --head "$BRANCH" --state open --json number --jq '.[].number')" ]]; then
    gh pr create --head "$BRANCH" --title "$title" --body-file "${log}.body"
  else
    gh pr edit "$BRANCH" --title "$title" --body-file "${log}.body"
  fi
fi

# Pushes made with GITHUB_TOKEN don't start other workflows; a dispatch
# does, and its result shows on the pull request's commit.
gh workflow run flatpak.yml --ref "$BRANCH"
{
  echo "commit=$(git rev-parse HEAD)"
  echo "manual=$manual"
} >> "$output"
