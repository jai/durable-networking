#!/usr/bin/env bash
# Releases main's newest commit that passed CI, at most once an hour, when it holds feat or fix commits no tag has yet.
# The version comes from Conventional Commits since the last vX.Y.Z tag: a breaking change bumps
# major (minor while at 0.x), feat bumps minor, fix bumps patch. Anything else releases nothing.
# DRY_RUN=1 prints what it would do. Needs gh signed in and the repo's tags fetched.
set -euo pipefail
repo=${GITHUB_REPOSITORY:-jai/durable-networking}

# At most one release an hour, timed from the newest GitHub Release. 50 minutes, not 60: the clock starts this on the
# hour, and the last release went out a little after the last hour's start.
age=$(gh api "repos/$repo/releases/latest" --jq '(now - (.published_at | fromdate)) | floor' 2>/dev/null || true)
if [[ -n "$age" ]] && (( age < 3000 )); then
  echo "The last release went out $((age / 60)) minutes ago; at most one release an hour."; exit 0
fi

sha=$(gh run list --workflow ci.yml --branch main --event push --status success --limit 1 \
  --json headSha --jq '.[0].headSha // empty')
if [[ -z "$sha" ]]; then echo "No green CI run on main."; exit 0; fi

last=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "$sha" 2>/dev/null || true)
range=${last:+$last..}$sha

breaking=0 feat=0 fix=0
features="" fixes=""
while IFS=$'\t' read -r short subject; do
  body=$(git log -1 --format=%b "$short")
  if [[ "$subject" =~ ^[a-z]+(\(.*\))?!: ]] || grep -q '^BREAKING[ -]CHANGE:' <<<"$body"; then breaking=1; fi
  if [[ "$subject" =~ ^feat(\(.*\))?!?:\ (.*) ]]; then feat=1; features+="- ${BASH_REMATCH[2]} ($short)"$'\n'; fi
  if [[ "$subject" =~ ^fix(\(.*\))?!?:\ (.*) ]]; then fix=1; fixes+="- ${BASH_REMATCH[2]} ($short)"$'\n'; fi
done < <(git log --no-merges --format=$'%h\t%s' "$range")

if (( !breaking && !feat && !fix )); then echo "Nothing to release since ${last:-the start} (CI-green $sha)."; exit 0; fi

IFS=. read -r major minor patch <<<"${last#v}"
major=${major:-0} minor=${minor:-0} patch=${patch:-0}
if (( breaking && major > 0 )); then major=$((major + 1)) minor=0 patch=0
elif (( breaking || feat )); then minor=$((minor + 1)) patch=0
else patch=$((patch + 1)); fi
next="v$major.$minor.$patch"

notes=""
[[ -n "$features" ]] && notes+=$'## Features\n\n'"$features"$'\n'
[[ -n "$fixes" ]] && notes+=$'## Fixes\n\n'"$fixes"$'\n'
[[ -n "$last" ]] && notes+="Since $last: https://github.com/$repo/compare/$last...$next"

echo "Release $next at $sha (after ${last:-nothing})."
printf '%s\n' "$notes"
if [[ "${DRY_RUN:-}" == 1 ]]; then exit 0; fi
gh release create "$next" --target "$sha" --title "$next" --notes "$notes"
