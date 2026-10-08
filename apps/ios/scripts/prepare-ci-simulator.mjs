#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro";

export function matchingRuntime(runtimes, sdkVersion) {
  const sdkFamily = sdkVersion.split(".").slice(0, 2).join(".");
  return runtimes
    .filter((runtime) =>
      runtime.isAvailable &&
      runtime.identifier.startsWith("com.apple.CoreSimulator.SimRuntime.iOS-") &&
      runtime.version.split(".").slice(0, 2).join(".") === sdkFamily &&
      (!runtime.supportedDeviceTypes ||
        runtime.supportedDeviceTypes.some((type) => type.identifier === DEVICE_TYPE))
    )
    .sort((a, b) => b.version.localeCompare(a.version, "en", { numeric: true }))[0];
}

function execute(command, args, { capture = false } = {}) {
  console.log(`> ${command} ${args.join(" ")}`);
  return execFileSync(command, args, {
    encoding: "utf8",
    stdio: capture ? ["ignore", "pipe", "inherit"] : "inherit",
  })?.trim();
}

export function prepareSimulator(run = execute) {
  run("xcodebuild", ["-version"]);
  const sdkVersion = run("xcrun", ["--sdk", "iphonesimulator", "--show-sdk-version"], { capture: true });
  if (!/^\d+\.\d+(?:\.\d+)?$/.test(sdkVersion)) {
    throw new Error(`Unexpected iOS Simulator SDK version: ${sdkVersion}`);
  }
  const readRuntime = () => matchingRuntime(
    JSON.parse(run("xcrun", ["simctl", "list", "runtimes", "--json"], { capture: true })).runtimes,
    sdkVersion,
  );
  let runtime = readRuntime();
  if (!runtime) {
    // The runner image may have only a newer Xcode's runtime. Download the
    // selected Xcode's SDK version instead of letting OS:latest pick for us.
    run("xcodebuild", ["-downloadPlatform", "iOS", "-buildVersion", sdkVersion]);
    runtime = readRuntime();
  }
  if (!runtime) {
    throw new Error(`No available iPhone 17 Pro runtime matches iOS ${sdkVersion} after download.`);
  }
  const udid = run("xcrun", [
    "simctl", "create", "Dash CI iPhone 17 Pro", DEVICE_TYPE, runtime.identifier,
  ], { capture: true });
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(udid)) {
    throw new Error(`simctl create returned an invalid device ID: ${udid}`);
  }
  run("xcrun", ["simctl", "boot", udid]);
  run("xcrun", ["simctl", "bootstatus", udid, "-b"]);
  return `platform=iOS Simulator,id=${udid}`;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const destination = prepareSimulator();
    console.log(`Prepared ${destination}`);
    if (process.env.GITHUB_OUTPUT) {
      appendFileSync(process.env.GITHUB_OUTPUT, `destination=${destination}\n`);
    }
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  }
}
