#!/usr/bin/env bash
set -euo pipefail

version="${1:?Pass the prepared version}"
root="$(pwd)"
major="${version%%.*}"
bash scripts/verify-release.sh "v$version"
for tag in "v$((major - 1)).0.0" "v$((major + 1)).0.0" "v$major.99.0" "v$version-beta.1" "$version" "invalid"; do
  if bash scripts/verify-release.sh "$tag" >/dev/null 2>&1; then
    echo "Unexpected accepted tag: $tag" >&2
    exit 1
  fi
done

directory="$(mktemp -d)"
trap 'rm -rf "$directory"' EXIT
cp README.md "$directory/"
if [[ -f pom.xml ]]; then
  cp pom.xml "$directory/"
  mkdir -p "$directory/featurevisor-sdk/src/main/java/com/featurevisor/cli"
  cp featurevisor-sdk/src/main/java/com/featurevisor/cli/CLI.java "$directory/featurevisor-sdk/src/main/java/com/featurevisor/cli/"
fi
# Both installation examples must agree, even when the other is correct.
for occurrence in 1 2; do
  awk -v version="$version" -v occurrence="$occurrence" '
    index($0, version) && (/from: / || /<version>/) {
      count++
      if (count == occurrence) sub(version, "0.0.0")
    }
    { print }
  ' README.md > "$directory/README.md"
  if (cd "$directory" && bash "$root/scripts/verify-release.sh" "v$version") >/dev/null 2>&1; then
    echo "Accepted a mismatched README installation version" >&2
    exit 1
  fi
done
checks=9
if [[ -f pom.xml ]]; then
  cp README.md "$directory/"
  for file in pom.xml featurevisor-sdk/src/main/java/com/featurevisor/cli/CLI.java; do
    sed "s/$version/0.0.0/g" "$file" > "$directory/$file"
    if (cd "$directory" && bash "$root/scripts/verify-release.sh" "v$version") >/dev/null 2>&1; then
      echo "Accepted a mismatched version in $file" >&2
      exit 1
    fi
    cp "$file" "$directory/$file"
    checks=$((checks + 1))
  done
fi
echo "$checks release validation checks passed."
