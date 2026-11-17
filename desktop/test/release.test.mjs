import assert from "node:assert/strict";
import test from "node:test";
import { buildStackEnv } from "../dist/stack.js";
import { releaseAssetUrl } from "../dist/updates.js";

test("releaseAssetUrl points at this version's GitHub release asset", () => {
  assert.equal(releaseAssetUrl("0.2.0", "agent-base.erofs"), "https://github.com/liamphmurphy/vesper/releases/download/v0.2.0/agent-base.erofs");
  assert.equal(releaseAssetUrl("v1.0.0-rc.1", "Vesper-arm64.dmg"), "https://github.com/liamphmurphy/vesper/releases/download/v1.0.0-rc.1/Vesper-arm64.dmg");
  assert.equal(releaseAssetUrl("dev", "agent-base.erofs"), null, "a dev build has no release");
  assert.equal(releaseAssetUrl("0.2.0", "../../x"), null);
  assert.equal(releaseAssetUrl("0.2.0", "a?b"), null);
  assert.equal(releaseAssetUrl("0.2.0", "x", "evil.example/../a"), null);
});

test("buildStackEnv passes the release rootfs URL unless VESPER_ROOTFS_URL is already set", () => {
  const opts = {
    resources: { vesperBin: "/x/vesper", postgresBinDir: "/x/pg" },
    userDataDir: "/data",
    secretsKey: "k",
    rootfsUrl: "https://github.com/liamphmurphy/vesper/releases/download/v0.2.0/agent-base.erofs",
  };
  const env = buildStackEnv(opts, "127.0.0.1:8080", { PATH: "/bin", VESPER_NO_SIGNIN: "1" });
  assert.equal(env.VESPER_ROOTFS_URL, opts.rootfsUrl);
  assert.equal(env.VESPER_APP_ADDR, "127.0.0.1:8080");
  assert.equal(env.VESPER_NO_SIGNIN, undefined, "never runs without sign-in");
  const own = buildStackEnv(opts, "127.0.0.1:8080", { VESPER_ROOTFS_URL: "https://mirror.example/rootfs" });
  assert.equal(own.VESPER_ROOTFS_URL, "https://mirror.example/rootfs");
  const none = buildStackEnv({ ...opts, rootfsUrl: undefined }, "127.0.0.1:8080", {});
  assert.equal("VESPER_ROOTFS_URL" in none, false);
});
