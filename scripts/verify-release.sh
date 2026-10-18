#!/usr/bin/env bash
set -euo pipefail

tag="${1:?Pass a release tag}"
if [[ ! "$tag" =~ ^v4\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Expected a Featurevisor Swift v4 semantic version tag" >&2
  exit 1
fi
version="${tag#v}"
if [[ "$(grep -Fc "from: \"$version\"" README.md)" != 2 ]]; then
  echo "SDK and provider README installation versions must match $tag" >&2
  exit 1
fi
echo "Validated Featurevisor Swift $version"
