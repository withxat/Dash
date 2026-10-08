import assert from "node:assert/strict";
import { test } from "node:test";
import { matchingRuntime, prepareSimulator } from "./prepare-ci-simulator.mjs";

const UDID = "A0000000-0000-0000-0000-000000000001";
const runtime = (version, properties = {}) => ({
  identifier: `com.apple.CoreSimulator.SimRuntime.iOS-${version.replaceAll(".", "-")}`,
  version,
  isAvailable: true,
  ...properties,
});

function mockRunner(runtimeLists) {
  const calls = [];
  let listIndex = 0;
  return {
    calls,
    run(command, args) {
      calls.push([command, ...args]);
      if (args.includes("--show-sdk-version")) return "26.4";
      if (args.includes("runtimes")) {
        return JSON.stringify({ runtimes: runtimeLists[listIndex++] });
      }
      if (args.includes("create")) return UDID;
      return "";
    },
  };
}

test("selects a compatible available iOS runtime instead of the newest installed OS", () => {
  const selected = matchingRuntime([
    runtime("27.0"), runtime("26.4"), runtime("26.4.1"),
    runtime("26.4.2", { isAvailable: false }),
    runtime("26.4.3", { supportedDeviceTypes: [{ identifier: "iPad" }] }),
    runtime("26.4.4", { identifier: "com.apple.CoreSimulator.SimRuntime.tvOS-26-4" }),
  ], "26.4");
  assert.equal(selected.version, "26.4.1");
});

test("creates and boots an explicit iPhone destination even when the runner has no devices", () => {
  const mock = mockRunner([[runtime("26.4")]]);
  assert.equal(prepareSimulator(mock.run), `platform=iOS Simulator,id=${UDID}`);
  assert.equal(mock.calls.some((call) => call.includes("-downloadPlatform")), false);
  assert.deepEqual(mock.calls.slice(-3), [
    ["xcrun", "simctl", "create", "Dash CI iPhone 17 Pro",
      "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime("26.4").identifier],
    ["xcrun", "simctl", "boot", UDID],
    ["xcrun", "simctl", "bootstatus", UDID, "-b"],
  ]);
});

test("downloads the selected Xcode's runtime if the image only has a newer one", () => {
  const mock = mockRunner([[runtime("27.0")], [runtime("27.0"), runtime("26.4")]]);
  assert.equal(prepareSimulator(mock.run), `platform=iOS Simulator,id=${UDID}`);
  assert.deepEqual(mock.calls[3], [
    "xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", "26.4",
  ]);
});

test("fails before testing if the requested runtime is still unavailable", () => {
  const mock = mockRunner([[], [runtime("26.4", { isAvailable: false })]]);
  assert.throws(() => prepareSimulator(mock.run), /No available iPhone 17 Pro runtime/);
  assert.equal(mock.calls.some((call) => call.includes("create")), false);
});

test("propagates a runtime download failure without starting a test destination", () => {
  const mock = mockRunner([[]]);
  assert.throws(() => prepareSimulator((command, args, options) => {
    if (args.includes("-downloadPlatform")) throw new Error("download failed");
    return mock.run(command, args, options);
  }), /download failed/);
  assert.equal(mock.calls.some((call) => call.includes("create")), false);
});
