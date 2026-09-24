#!/usr/bin/env bash
#
# Print the GitHub release body for one chart version: the `## [<version>]`
# section of CHANGELOG.md, plus a compare link when the tags can be resolved.
#
# The `release` job in .github/workflows/ci.yaml runs this once per chart that
# chart-releaser has just published, and pipes the output into `gh release edit
# <tag> --notes-file`. chart-releaser-action@v1.7.0 carries no release notes at
# all - `cr upload` reads a notes file only from inside the packaged chart, and
# the action does not pass that flag - so without this step every release body
# would stay the chart `description` from Chart.yaml, a sentence that says
# nothing about what changed in that version.
#
# The section *is* the release body, which is what keeps the notes in the
# repository and the notes on the GitHub release from drifting apart: editing
# CHANGELOG.md is how release notes are written, nothing is generated from
# commit messages.
#
#   1. locate the section for <version> - from the `## [<version>]` heading up
#      to (excluding) the next `## ` heading, with leading and trailing blank
#      lines trimmed. A version whose heading is absent exits non-zero and
#      prints nothing: the release job must go red, not publish a release whose
#      body silently stayed the chart description;
#   2. print the section;
#   3. append the `**Full Changelog**: <compare URL>` line when the repository,
#      the `<chart name>-<version>` tag and the previous `<chart name>-*` tag
#      are all resolvable. That part is best effort: any of them missing just
#      means the section is printed alone, still with exit 0.
#
# usage: hack/release-notes.sh <version>       (the bare Chart.yaml version, e.g. 2.0.0)
#        CHANGELOG_FILE=<path>                 (default: CHANGELOG.md at the repo root,
#                                               resolved from this script's own location
#                                               rather than from $PWD; set for tests)
#
# The chart name in the tag and in the tag list comes from
# charts/tuwunel/Chart.yaml, the repository's only chart.
#
# Needs bash and awk. Exits 0 with the body on stdout; 1 with a message on
# stderr and nothing on stdout when the section is missing; 2 on a usage error.
set -euo pipefail

# Repo root from this script's own location: the workflow calls the script from
# the checkout root, but a manual run should not depend on the caller's cwd.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname -- "$script_dir")"

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: hack/release-notes.sh <version>   (e.g. 2.0.0)" >&2
  exit 2
fi
version="$1"

changelog="${CHANGELOG_FILE:-$repo_root/CHANGELOG.md}"
if [ ! -f "$changelog" ]; then
  echo "no changelog file ${changelog}: it holds the release body for ${version}" >&2
  exit 1
fi

# The heading is matched by literal prefix rather than as a regex, so a version
# like `2.0.0` cannot match `2x0y0`; the character after the closing bracket has
# to be a space (the ` - <date>` separator) or the end of the line, so looking
# for `1.2.0` does not pick up a `1.2.0-rc1` heading above it.
section="$(
  awk -v version="$version" '
    BEGIN { prefix = "## [" version "]" }
    !in_section {
      if (index($0, prefix) == 1 && (length($0) == length(prefix) || substr($0, length(prefix) + 1, 1) == " ")) {
        in_section = 1
      }
      next
    }
    /^## / { exit }
    { body[count++] = $0 }
    END {
      if (!in_section) exit 1
      last = count
      while (last > 0 && body[last - 1] ~ /^[[:space:]]*$/) last--
      first = 0
      while (first < last && body[first] ~ /^[[:space:]]*$/) first++
      for (i = first; i < last; i++) print body[i]
    }
  ' "$changelog"
)" || {
  echo "no '## [${version}]' section in ${changelog}: add it before releasing ${version}, the GitHub release body is taken from it" >&2
  exit 1
}

if [ -n "$section" ]; then
  printf '%s\n' "$section"
fi

# Everything below is the compare link, which is a nicety and never a reason to
# fail: a missing remote, a checkout without tags or a chart name that cannot be
# read each leave the body as the section alone.

# `owner/repo`, from the workflow's environment or from the checkout's origin.
# Both the scp-like and the URL forms of a GitHub remote are accepted.
repo="${GITHUB_REPOSITORY:-}"
if [ -z "$repo" ]; then
  remote="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
  case "$remote" in
    git@github.com:*) repo="${remote#git@github.com:}" ;;
    ssh://git@github.com/*) repo="${remote#ssh://git@github.com/}" ;;
    https://github.com/*) repo="${remote#https://github.com/}" ;;
    http://github.com/*) repo="${remote#http://github.com/}" ;;
    git://github.com/*) repo="${remote#git://github.com/}" ;;
    *) repo="" ;;
  esac
fi
repo="${repo%.git}"

# The tag chart-releaser created, from the chart's own name: `name` and
# `version` in Chart.yaml are what the tag was built out of.
chart_yaml="$repo_root/charts/tuwunel/Chart.yaml"
chart_name=""
if [ -f "$chart_yaml" ]; then
  chart_name="$(awk '/^name:/ { print $2; exit }' "$chart_yaml")"
fi

tag=""
if [ -n "$chart_name" ]; then
  tag="${chart_name}-${version}"
fi

# The previous release tag: the entry right after the released one in the
# version-sorted list, so the compare range is the step that release made. While
# the new tag does not exist in the checkout yet (the script run by hand before
# chart-releaser creates it, or a backfill of an older version), the newest tag
# is the right answer, because a release is always the newest version. Tags
# present in the checkout are enough - the release job checks out with
# fetch-depth: 0 and chart-releaser runs `git fetch --tags`.
previous=""
if [ -n "$repo" ] && [ -n "$tag" ]; then
  if tags="$(git -C "$repo_root" tag --list "${chart_name}-*" --sort=-v:refname 2>/dev/null)" && [ -n "$tags" ]; then
    if grep -qxF -- "$tag" <<<"$tags"; then
      previous="$(awk -v tag="$tag" 'found { print; exit } $0 == tag { found = 1 }' <<<"$tags")"
    else
      previous="$(awk 'NR == 1 { print; exit }' <<<"$tags")"
    fi
  fi
fi

if [ -n "$previous" ]; then
  printf '\n**Full Changelog**: https://github.com/%s/compare/%s...%s\n' "$repo" "$previous" "$tag"
fi
