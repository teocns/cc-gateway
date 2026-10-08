#!/bin/sh
# Install cc-gateway: a release unpacked under ~/.local/share/ak/cc-gateway/<version>,
# a `current` link at it, and a `cc-gateway` launcher in ~/.local/bin. POSIX
# (macOS, Linux); Windows is not covered by this script yet.
#
#   sh install.sh [--version X.Y.Z]     a release from GitHub (default: the latest)
#   sh install.sh --from FILE.tar.gz    a tarball on disk (its .sha256 beside it is checked)
#   sh install.sh --uninstall           the launcher and the install dirs; never accounts, config or data
#
# A release comes through `gh` when it is logged in (the repo may be private),
# else through curl. CC_GATEWAY_BIN_DIR moves the launcher; XDG_DATA_HOME moves the install.
set -eu

REPO=teocns/cc-gateway
NODE_MIN=22.7
# The folder name the gateway's state lives under, shared with the agentic kit's `ak gateway`:
# ~/.config/<it>, ~/.local/share/<it>, the service com.<it>.gateway. Fixed; never renamed here.
STATE=ak

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

version=""
from=""
uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs X.Y.Z"; version=${2#v}; shift 2 ;;
    --from) [ $# -ge 2 ] || die "--from needs a .tar.gz"; from=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 (--help lists them)" ;;
  esac
done

data_root="${XDG_DATA_HOME:-$HOME/.local/share}/$STATE/cc-gateway"
bin_dir="${CC_GATEWAY_BIN_DIR:-$HOME/.local/bin}"
launcher="$bin_dir/cc-gateway"

# The service is on when its manager has it loaded. `disable` unloads it; the
# unit file may stay, so the file alone says nothing.
service_on() {
  case "$(uname -s)" in
    Darwin) launchctl print "gui/$(id -u)/com.$STATE.gateway" >/dev/null 2>&1 ;;
    Linux) command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet "$STATE-gateway.service" ;;
    *) return 1 ;;
  esac
}

if [ "$uninstall" = 1 ]; then
  if service_on; then
    die "the gateway service is on — run \`cc-gateway disable\` first, then this again (it would keep running with no command left to stop it)"
  fi
  if [ -f "$launcher" ]; then
    if grep -q 'cc-gateway/current/src/cli.ts' "$launcher"; then
      rm -f "$launcher"
      say "removed   $launcher"
    else
      say "kept      $launcher — not a launcher this script wrote"
    fi
  fi
  if [ -d "$data_root" ]; then
    rm -rf "$data_root"
    say "removed   $data_root"
  fi
  say "kept      accounts, config and the gateway's data — this script never touches them"
  exit 0
fi

# ---- node ≥ 22.7: the gateway runs from source with --experimental-strip-types
command -v node >/dev/null 2>&1 || die "node is not on PATH — cc-gateway needs node ≥ $NODE_MIN"
node_ok=$(node -e 'const [a, b] = process.versions.node.split(".").map(Number); const [x, y] = process.argv[1].split(".").map(Number); console.log(a > x || (a === x && b >= y) ? "yes" : "no")' "$NODE_MIN")
[ "$node_ok" = yes ] || die "node $(node -v) is too old — cc-gateway needs node ≥ $NODE_MIN"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ---- the tarball: on disk, through gh, or through curl
if [ -n "$from" ]; then
  [ -f "$from" ] || die "no file at $from"
  tarball=$from
  sumfile="$from.sha256"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if [ -n "$version" ]; then wanted="v$version"; else wanted=latest; fi
  say "download  $REPO $wanted (gh)"
  if [ -n "$version" ]; then
    gh release download "v$version" -R "$REPO" -p 'cc-gateway-*.tar.gz*' -D "$work" || die "gh could not download v$version from $REPO"
  else
    gh release download -R "$REPO" -p 'cc-gateway-*.tar.gz*' -D "$work" || die "gh could not download the latest release from $REPO"
  fi
  tarball=""
  for f in "$work"/cc-gateway-*.tar.gz; do if [ -f "$f" ]; then tarball=$f; fi; done
  [ -n "$tarball" ] || die "the release has no cc-gateway-*.tar.gz"
  sumfile="$tarball.sha256"
else
  command -v curl >/dev/null 2>&1 || die "neither gh (logged in) nor curl is available to download a release"
  if [ -z "$version" ]; then
    # /releases/latest redirects to /releases/tag/v<version>.
    latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") || die "could not reach github.com/$REPO — a private repo needs \`gh auth login\`"
    version=${latest##*/v}
    case "$version" in ''|*/*) die "could not tell the latest version from $latest" ;; esac
  fi
  url="https://github.com/$REPO/releases/download/v$version/cc-gateway-$version.tar.gz"
  say "download  $url"
  tarball="$work/cc-gateway-$version.tar.gz"
  curl -fsSL -o "$tarball" "$url" || die "could not download $url"
  sumfile="$tarball.sha256"
  curl -fsSL -o "$sumfile" "$url.sha256" 2>/dev/null || rm -f "$sumfile"
fi

# ---- the checksum, when the release has one
if [ -f "$sumfile" ]; then
  want=$(cut -d ' ' -f 1 <"$sumfile")
  if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tarball"); else got=$(shasum -a 256 "$tarball"); fi
  got=${got%% *}
  [ "$want" = "$got" ] || die "checksum mismatch for $tarball — expected $want, got $got"
  say "verified  sha256 $got"
else
  say "unverified no .sha256 beside $tarball"
fi

# ---- unpack: <data_root>/<version>, then `current` points at it
top=$(tar -tzf "$tarball" | head -n 1)
top=${top%%/*}
case "$top" in cc-gateway-*) ;; *) die "$tarball is not a cc-gateway release (its top folder is \"$top\")" ;; esac
ver=${top#cc-gateway-}
[ -z "$version" ] || [ "$version" = "$ver" ] || die "asked for $version, the tarball holds $ver"

mkdir -p "$data_root"
staging="$data_root/.$ver.partial"
rm -rf "$staging"
mkdir -p "$staging"
tar -xzf "$tarball" -C "$staging" --strip-components=1
[ -f "$staging/src/cli.ts" ] || die "$tarball has no src/cli.ts"
rm -rf "${data_root:?}/$ver"
mv "$staging" "$data_root/$ver"
ln -sfn "$ver" "$data_root/current"
say "installed $data_root/$ver (current)"

# ---- the launcher
mkdir -p "$bin_dir"
cat >"$launcher" <<EOF
#!/bin/sh
# cc-gateway — written by install.sh; \`install.sh --uninstall\` removes it.
exec node --experimental-strip-types --no-warnings "$data_root/current/src/cli.ts" "\$@"
EOF
chmod 755 "$launcher"
say "launcher  $launcher"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) say "warn      $bin_dir is not on PATH — add it, e.g. export PATH=\"$bin_dir:\$PATH\"" ;;
esac

say ""
say "next:"
say "  cc-gateway account login     a browser login (or: account import — Claude Code's own)"
say "  cc-gateway enable            start the service"
say "  cc-gateway run -- claude     one claude through it"
