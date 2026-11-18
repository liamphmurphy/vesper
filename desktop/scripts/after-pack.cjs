const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

function isMachO(filePath) {
  let fd;
  try {
    const stat = fs.lstatSync(filePath);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 4) return false;
    fd = fs.openSync(filePath, "r");
    const buf = Buffer.alloc(4);
    fs.readSync(fd, buf, 0, 4, 0);
    const magic = buf.readUInt32BE(0);
    return (
      magic === 0xfeedface ||
      magic === 0xcefaedfe ||
      magic === 0xfeedfacf ||
      magic === 0xcffaedfe ||
      magic === 0xcafebabe ||
      magic === 0xbebafeca
    );
  } catch {
    return false;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function walkMachOs(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isSymbolicLink()) continue;
    if (entry.isDirectory()) {
      walkMachOs(full, out);
    } else if (isMachO(full)) {
      out.push(full);
    }
  }
  return out;
}

function codesign(args) {
  execFileSync("codesign", args, { stdio: "inherit" });
}

exports.default = async function afterSign(context) {
  if (context.electronPlatformName !== "darwin") {
    return;
  }

  const appName = `${context.packager.appInfo.productFilename}.app`;
  const appPath = path.join(context.appOutDir, appName);
  const resourcesDir = path.join(appPath, "Contents", "Resources");
  const projectResourcesDir = path.join(context.packager.projectDir, "resources");
  const repoRoot = path.resolve(context.packager.projectDir, "..");
  const entitlementsPath = path.join(repoRoot, "deploy", "microvm", "vz.entitlements");

  if (!fs.existsSync(entitlementsPath)) {
    throw new Error(`Missing virtualization entitlements file: ${entitlementsPath}`);
  }

  // electron-builder strips top-level node_modules when copying extraResources; restore the full
  // web tree (the design worker's node_modules) before signing native .node addons inside web/.
  const stagedWebDir = path.join(projectResourcesDir, "web");
  const packagedWebDir = path.join(resourcesDir, "web");
  if (fs.existsSync(stagedWebDir)) {
    fs.rmSync(packagedWebDir, { recursive: true, force: true });
    fs.cpSync(stagedWebDir, packagedWebDir, { recursive: true, verbatimSymlinks: true });
  }

  // 1. Inside-out ad-hoc signing for bundled PostgreSQL 17 binaries/dylibs and the design worker's native addon.
  for (const sub of ["postgres", "web"]) {
    const targetDir = path.join(resourcesDir, sub);
    for (const file of walkMachOs(targetDir)) {
      codesign(["--force", "--sign", "-", file]);
    }
  }

  // 2. Sign bundled vesper binary with Virtualization.framework entitlement WITHOUT --options runtime.
  const vesperBin = path.join(resourcesDir, "bin", "vesper");
  if (fs.existsSync(vesperBin)) {
    codesign(["--force", "--sign", "-", "--entitlements", entitlementsPath, vesperBin]);
  }

  // 3. Re-seal outer Vesper.app bundle (no --deep so vesper retains vz entitlement).
  codesign(["--force", "--sign", "-", appPath]);
};
