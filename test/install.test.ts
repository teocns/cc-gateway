/**
 * The standalone path end to end: scripts/pack.sh builds the release tarball,
 * install.sh --from unpacks it into a scratch HOME with a scratch bin dir, the
 * launcher runs the installed copy, and --uninstall takes away what install.sh
 * put there and nothing else. The service manager is a stub on PATH that says
 * on or off; the real one is never asked. POSIX only, as install.sh is.
 */
import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

import { GATEWAY_ACCOUNTS, GATEWAY_CONFIG, GATEWAY_DATA, envName } from "../src/brand.ts"

const ROOT = fileURLToPath(new URL("..", import.meta.url))
const VERSION = (JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")) as { version: string }).version

function sandbox(): { dir: string; home: string; bin: string; env: NodeJS.ProcessEnv } {
  const dir = mkdtempSync(join(tmpdir(), "gw-install-"))
  const home = join(dir, "home")
  const bin = join(dir, "bin")
  const stubs = join(dir, "stubs")
  mkdirSync(home)
  mkdirSync(stubs)
  // launchctl (macOS) and systemctl (Linux): "on" only when the test says so.
  for (const tool of ["launchctl", "systemctl"]) {
    writeFileSync(join(stubs, tool), '#!/bin/sh\n[ "${FAKE_SERVICE_ON:-}" = 1 ]\n')
    chmodSync(join(stubs, tool), 0o755)
  }
  const env: NodeJS.ProcessEnv = { ...process.env, HOME: home, CC_GATEWAY_BIN_DIR: bin, PATH: `${stubs}:${process.env.PATH ?? ""}` }
  for (const k of ["XDG_DATA_HOME", "XDG_CONFIG_HOME", envName("GATEWAY_COMMAND"), envName("GATEWAY_CONFIG"), envName("GATEWAY_DATA_DIR")]) delete env[k]
  return { dir, home, bin, env }
}

const sh = (args: string[], env: NodeJS.ProcessEnv) => spawnSync("sh", args, { env, encoding: "utf8", cwd: ROOT })

test("pack, install --from, run the launcher, uninstall: the person's state is never touched", { skip: process.platform === "win32" && "install.sh is POSIX only" }, () => {
  const s = sandbox()
  const packed = sh([join(ROOT, "scripts", "pack.sh"), "--out", join(s.dir, "dist")], s.env)
  assert.equal(packed.status, 0, packed.stderr)
  const tarball = join(s.dir, "dist", `cc-gateway-${VERSION}.tar.gz`)
  assert.ok(existsSync(tarball) && existsSync(`${tarball}.sha256`))
  const listed = spawnSync("tar", ["-tzf", tarball], { encoding: "utf8" }).stdout.split("\n")
  assert.ok(listed.includes(`cc-gateway-${VERSION}/src/cli.ts`))
  assert.ok(listed.includes(`cc-gateway-${VERSION}/src/engine/LICENSE`))
  assert.ok(!listed.some((f) => f.includes("/test/") || f.includes("node_modules")), "tests and node_modules stay out")

  // What the person owns: config, accounts, the gateway's data. Uninstall must leave all of it.
  const MINE = `{"accounts":[],"note":"mine"}\n`
  const state = [join(s.home, ".config", GATEWAY_ACCOUNTS), join(s.home, ".config", GATEWAY_CONFIG), join(s.home, ".local", "share", GATEWAY_DATA, "trace.ndjson")]
  for (const f of state) {
    mkdirSync(join(f, ".."), { recursive: true })
    writeFileSync(f, MINE)
  }

  const install = sh([join(ROOT, "install.sh"), "--from", tarball], s.env)
  assert.equal(install.status, 0, install.stderr)
  assert.match(install.stdout, /^verified  sha256 /m)
  assert.match(install.stdout, /is not on PATH/)
  assert.match(install.stdout, /cc-gateway run -- claude/)
  // Where install.sh put it, as it says — its state folder is its own, not the brand seam's.
  const installed = new RegExp(`^installed (.+)/${VERSION.replaceAll(".", "\\.")} \\(current\\)$`, "m").exec(install.stdout)
  assert.ok(installed, install.stdout)
  const root = installed[1]
  assert.ok(root.startsWith(join(s.home, ".local", "share")), root)
  assert.ok(lstatSync(join(root, "current")).isSymbolicLink())
  assert.equal(readlinkSync(join(root, "current")), VERSION)
  assert.ok(existsSync(join(root, VERSION, "src", "cli.ts")))

  const launcher = join(s.bin, "cc-gateway")
  const help = spawnSync(launcher, ["--help"], { env: s.env, encoding: "utf8" })
  assert.equal(help.status, 0, help.stderr)
  assert.match(help.stdout, /^cc-gateway — /)
  assert.match(help.stdout, /run \[--account NAME\]/)

  // On: refused, with the verb that turns it off; nothing removed.
  const busy = sh([join(ROOT, "install.sh"), "--uninstall"], { ...s.env, FAKE_SERVICE_ON: "1" })
  assert.equal(busy.status, 1)
  assert.match(busy.stderr, /cc-gateway disable/)
  assert.ok(existsSync(launcher))

  const gone = sh([join(ROOT, "install.sh"), "--uninstall"], s.env)
  assert.equal(gone.status, 0, gone.stderr)
  assert.ok(!existsSync(launcher))
  assert.ok(!existsSync(root))
  for (const f of state) assert.equal(readFileSync(f, "utf8"), MINE, f)
})

test("install --from refuses a tarball whose .sha256 does not match, and installs nothing", { skip: process.platform === "win32" && "install.sh is POSIX only" }, () => {
  const s = sandbox()
  const packed = sh([join(ROOT, "scripts", "pack.sh"), "--out", join(s.dir, "dist")], s.env)
  assert.equal(packed.status, 0, packed.stderr)
  const tarball = join(s.dir, `cc-gateway-${VERSION}.tar.gz`)
  copyFileSync(join(s.dir, "dist", `cc-gateway-${VERSION}.tar.gz`), tarball)
  writeFileSync(`${tarball}.sha256`, `${"0".repeat(64)}  cc-gateway-${VERSION}.tar.gz\n`)
  const r = sh([join(ROOT, "install.sh"), "--from", tarball], s.env)
  assert.equal(r.status, 1)
  assert.match(r.stderr, /checksum mismatch/)
  assert.ok(!existsSync(join(s.bin, "cc-gateway")))
  assert.ok(!r.stdout.includes("installed "), "nothing was unpacked")
})
