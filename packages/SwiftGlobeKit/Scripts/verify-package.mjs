#!/usr/bin/env node
/**
 * Type-checks the iOS-only SwiftUI bridge and compiles the Metal shader
 * without launching a simulator.
 */
import { spawn } from "node:child_process";
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(scriptDirectory, "..");
const sourceDirectory = path.join(packageDirectory, "Sources", "SwiftGlobeKit");
const temporaryDirectory = await mkdtemp(
  path.join(tmpdir(), "swift-globe-kit-verify-"),
);

try {
  const simulatorSDK = (
    await run("xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"], {
      captureOutput: true,
    })
  ).trim();
  const simulatorArchitecture = process.arch === "arm64" ? "arm64" : "x86_64";
  const swiftSources = (await readdir(sourceDirectory))
    .filter((name) => name.endsWith(".swift"))
    .sort()
    .map((name) => path.join(sourceDirectory, name));
  const bundleAccessor = path.join(
    temporaryDirectory,
    "resource_bundle_accessor.swift",
  );
  await writeFile(
    bundleAccessor,
    [
      "import Foundation",
      "",
      "extension Foundation.Bundle {",
      "  static let module = Bundle.main",
      "}",
      "",
    ].join("\n"),
  );

  await run("xcrun", [
    "swiftc",
    "-typecheck",
    "-parse-as-library",
    "-swift-version",
    "6",
    "-strict-concurrency=complete",
    "-warnings-as-errors",
    "-target",
    `${simulatorArchitecture}-apple-ios17.0-simulator`,
    "-sdk",
    simulatorSDK,
    "-module-name",
    "SwiftGlobeKit",
    ...swiftSources,
    bundleAccessor,
  ]);

  const shaderSource = path.join(sourceDirectory, "GlobeShaders.metal");
  const airOutput = path.join(temporaryDirectory, "GlobeShaders.air");
  const libraryOutput = path.join(temporaryDirectory, "GlobeShaders.metallib");
  await run("xcrun", [
    "--sdk",
    "iphonesimulator",
    "metal",
    "-std=ios-metal2.4",
    "-Wall",
    "-Wextra",
    "-c",
    shaderSource,
    "-o",
    airOutput,
  ]);
  await run("xcrun", [
    "--sdk",
    "iphonesimulator",
    "metallib",
    airOutput,
    "-o",
    libraryOutput,
  ]);

  const symbolTable = await run(
    "xcrun",
    ["--sdk", "iphonesimulator", "metal-objdump", "-t", libraryOutput],
    { captureOutput: true },
  );
  const entryPoints = [
    "swift_globe::swiftGlobeVertex",
    "swift_globe::swiftGlobeFragment",
    "swift_globe::swiftGlobeArcVertex",
    "swift_globe::swiftGlobeArcFragment",
    "swift_globe::swiftGlobeMarkerVertex",
    "swift_globe::swiftGlobeMarkerFragment",
  ];
  const missingEntryPoints = entryPoints.filter(
    (entryPoint) => !symbolTable.includes(entryPoint),
  );
  if (missingEntryPoints.length > 0) {
    throw new Error(
      `Metal library is missing entry points: ${missingEntryPoints.join(", ")}`,
    );
  }

  console.log(
    "verify-package: iOS Swift typecheck and 6 Metal entry points passed",
  );
} finally {
  await rm(temporaryDirectory, { force: true, recursive: true });
}

/**
 * @param {string} command
 * @param {string[]} argumentsList
 * @param {{ captureOutput?: boolean }} options
 */
function run(command, argumentsList, { captureOutput = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, argumentsList, {
      cwd: packageDirectory,
      stdio: captureOutput ? ["ignore", "pipe", "pipe"] : "inherit",
    });
    const output = [];
    const errorOutput = [];

    if (captureOutput) {
      child.stdout.on("data", (chunk) => output.push(Buffer.from(chunk)));
      child.stderr.on("data", (chunk) => errorOutput.push(Buffer.from(chunk)));
    }

    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (code === 0) {
        resolve(Buffer.concat(output).toString("utf8"));
        return;
      }

      const detail = Buffer.concat(errorOutput).toString("utf8").trim();
      reject(
        new Error(
          `${command} exited with ${signal ? `signal ${signal}` : `code ${code}`}` +
            (detail ? `\n${detail}` : ""),
        ),
      );
    });
  });
}
