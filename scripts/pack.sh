#!/bin/sh
# Build the release tarball install.sh unpacks: cc-gateway-<version>.tar.gz and
# its .sha256, from what the gateway runs on and nothing else — src, docs, the
# package, the README, the installer, the example config. No tests, no
# node_modules. Inside git, only files git would commit (tracked, or new and not
# ignored); outside it, the same paths as they are on disk.
#
#   sh scripts/pack.sh [--out DIR]     default DIR: dist/
set -eu

# macOS tar would add ._ files for extended attributes; nobody unpacking wants them.
export COPYFILE_DISABLE=1

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "pack.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

version=$(node -p 'require(process.argv[1]).version' "$root/package.json")
name="cc-gateway-$version"
paths="src docs package.json README.md install.sh example.config.json LICENSE"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
list="$work/files"
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # shellcheck disable=SC2086 # the paths are words on purpose
  (cd "$root" && git ls-files --cached --others --exclude-standard -- $paths) | while IFS= read -r f; do
    [ -f "$root/$f" ] && printf '%s\n' "$f"
  done | sort -u >"$list"
else
  # shellcheck disable=SC2086
  (cd "$root" && find $paths -type f ! -path '*/node_modules/*' ! -name '.DS_Store') | sort >"$list"
fi
for must in src/cli.ts src/daemon.ts package.json install.sh; do
  grep -qx "$must" "$list" || { echo "pack.sh: $must is missing from the pack" >&2; exit 1; }
done

mkdir -p "$work/$name" "$out"
out=$(cd "$out" && pwd) # the tar below runs from $work
(cd "$root" && tar -cf - -T "$list") | (cd "$work/$name" && tar -xf -)
tarball="$out/$name.tar.gz"
(cd "$work" && tar -czf "$tarball" "$name")

if command -v sha256sum >/dev/null 2>&1; then sum=$(sha256sum "$tarball"); else sum=$(shasum -a 256 "$tarball"); fi
printf '%s  %s\n' "${sum%% *}" "$name.tar.gz" >"$tarball.sha256"
echo "$tarball"
echo "$tarball.sha256"
