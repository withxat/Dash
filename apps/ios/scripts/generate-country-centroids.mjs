#!/usr/bin/env node
/**
 * Generates the WAF globe's local ISO 3166-1 alpha-2 country label points.
 *
 * Natural Earth's cartographic label points are preferable to polygon
 * centroids for archipelagos and antimeridian countries. The countries layer
 * supplies the canonical point; map units fill separately coded territories.
 * The US Minor Outlying Islands have no single Natural Earth ISO feature, so
 * their representative point is the dataset's Johnston Atoll label point.
 *
 * Usage:
 *   node apps/ios/scripts/generate-country-centroids.mjs
 *   node apps/ios/scripts/generate-country-centroids.mjs --check
 */
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import https from "node:https";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SOURCE_COMMIT = "f1890d9f152c896d250a77557a5751a93d494776";
const COUNTRY_SOURCE = {
  url:
    `https://raw.githubusercontent.com/nvkelso/natural-earth-vector/${SOURCE_COMMIT}` +
    "/geojson/ne_10m_admin_0_countries.geojson",
  sha256: "239eec57ac17f100a11e2536cffc56752c318b50ae765b0918ff7aab4ce8f255",
};
const MAP_UNIT_SOURCE = {
  url:
    `https://raw.githubusercontent.com/nvkelso/natural-earth-vector/${SOURCE_COMMIT}` +
    "/geojson/ne_10m_admin_0_map_units.geojson",
  sha256: "57da82be755f4afccd8f3b14251bb2752f5df1395f47d2d86f817470c4a48862",
};

const ISO_ALPHA_2 = new Set(
  (
    "AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ " +
    "BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR " +
    "CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR " +
    "GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU " +
    "ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ " +
    "LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ " +
    "MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF " +
    "PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI " +
    "SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR " +
    "TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW"
  ).split(" "),
);
const SUPPORTED_CODES = new Set([...ISO_ALPHA_2, "XK"]);
const BEGIN_MARKER = "  // BEGIN GENERATED WAF COUNTRY CENTROIDS";
const END_MARKER = "  // END GENERATED WAF COUNTRY CENTROIDS";
const MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024;

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.resolve(
  scriptDirectory,
  "..",
  "Dash",
  "ZoneOperationsViews.swift",
);
const checkOnly = process.argv.slice(2).includes("--check");
const unknownArguments = process.argv
  .slice(2)
  .filter((argument) => argument !== "--check");

if (unknownArguments.length > 0) {
  throw new Error(`Unknown arguments: ${unknownArguments.join(", ")}`);
}

const [countriesBuffer, mapUnitsBuffer] = await Promise.all([
  download(COUNTRY_SOURCE.url),
  download(MAP_UNIT_SOURCE.url),
]);
assertSha256(countriesBuffer, COUNTRY_SOURCE.sha256, "countries source");
assertSha256(mapUnitsBuffer, MAP_UNIT_SOURCE.sha256, "map-units source");

const countries = JSON.parse(countriesBuffer.toString("utf8"));
const mapUnits = JSON.parse(mapUnitsBuffer.toString("utf8"));
const coordinates = collectCoordinates(countries.features, mapUnits.features);
const generatedBlock = renderSwift(coordinates);
const source = await readFile(sourcePath, "utf8");
const updated = replaceGeneratedBlock(source, generatedBlock);

if (checkOnly) {
  if (updated !== source) {
    throw new Error(
      `${sourcePath} has stale country centroids. Run this script without --check.`,
    );
  }
  console.log(`Checked ${coordinates.size} WAF country centroids.`);
} else {
  await writeFile(sourcePath, updated);
  console.log(`Generated ${coordinates.size} WAF country centroids.`);
}

function collectCoordinates(countryFeatures, mapUnitFeatures) {
  const coordinates = new Map();

  addPreferredFeatures(coordinates, countryFeatures);
  addPreferredFeatures(coordinates, mapUnitFeatures, { onlyMissing: true });

  // Natural Earth represents each minor outlying island as a US map unit, not
  // one composite `UM` feature. Use its populated Johnston Atoll label point.
  coordinates.set("UM", { latitude: 16.727398, longitude: -169.53804 });

  const missing = [...ISO_ALPHA_2].filter((code) => !coordinates.has(code));
  if (missing.length > 0) {
    throw new Error(`Missing ISO country coordinates: ${missing.join(", ")}`);
  }

  for (const code of [...coordinates.keys()]) {
    if (!SUPPORTED_CODES.has(code)) coordinates.delete(code);
  }
  return coordinates;
}

function addPreferredFeatures(target, features, options = {}) {
  const candidates = new Map();
  for (const feature of features) {
    const properties = feature?.properties;
    if (!properties) continue;
    const code = countryCode(properties);
    if (!code || !SUPPORTED_CODES.has(code)) continue;
    if (options.onlyMissing && target.has(code)) continue;

    const longitude = Number(properties.LABEL_X);
    const latitude = Number(properties.LABEL_Y);
    if (
      !Number.isFinite(latitude) ||
      !Number.isFinite(longitude) ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180
    ) {
      throw new Error(`Invalid Natural Earth label point for ${code}`);
    }

    const population = Number(properties.POP_EST) || 0;
    const current = candidates.get(code);
    if (!current || population > current.population) {
      candidates.set(code, { latitude, longitude, population });
    }
  }

  for (const [code, point] of candidates) {
    target.set(code, {
      latitude: point.latitude,
      longitude: point.longitude,
    });
  }
}

function countryCode(properties) {
  for (const value of [properties.ISO_A2, properties.ISO_A2_EH]) {
    if (typeof value === "string" && /^[A-Z]{2}$/.test(value)) return value;
  }
  return null;
}

function renderSwift(coordinates) {
  const lines = [...coordinates]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(
      ([code, point]) =>
        `    "${code}": Point(latitude: ${format(point.latitude)}, longitude: ${format(point.longitude)}),`,
    );
  return [
    BEGIN_MARKER,
    "  private static let coordinates: [String: Point] = [",
    ...lines,
    "  ]",
    END_MARKER,
  ].join("\n");
}

function replaceGeneratedBlock(source, generatedBlock) {
  const start = source.indexOf(BEGIN_MARKER);
  const end = source.indexOf(END_MARKER);
  if (start < 0 || end < start) {
    throw new Error("Could not find generated centroid markers in ZoneOperationsViews.swift");
  }
  return (
    source.slice(0, start) +
    generatedBlock +
    source.slice(end + END_MARKER.length)
  );
}

function format(value) {
  const formatted = value.toFixed(6).replace(/\.?0+$/, "");
  return formatted === "-0" ? "0" : formatted;
}

function assertSha256(buffer, expected, label) {
  const actual = createHash("sha256").update(buffer).digest("hex");
  if (actual !== expected) {
    throw new Error(`${label} SHA-256 mismatch: expected ${expected}, received ${actual}`);
  }
}

function download(url, redirects = 0) {
  if (redirects > 5) {
    throw new Error(`Too many redirects while downloading ${url}`);
  }

  return new Promise((resolve, reject) => {
    const request = https.get(
      url,
      {
        headers: {
          Accept: "application/geo+json, application/json",
          "User-Agent": "Dash-WAF-country-centroid-generator",
        },
      },
      (response) => {
        if (
          response.statusCode >= 300 &&
          response.statusCode < 400 &&
          response.headers.location
        ) {
          const redirectedURL = new URL(response.headers.location, url);
          response.resume();
          if (redirectedURL.protocol !== "https:") {
            reject(new Error(`Refusing non-HTTPS redirect to ${redirectedURL.href}`));
            return;
          }
          download(redirectedURL.href, redirects + 1).then(resolve, reject);
          return;
        }
        if (response.statusCode !== 200) {
          response.resume();
          reject(new Error(`Download failed with HTTP ${response.statusCode}: ${url}`));
          return;
        }

        const chunks = [];
        let size = 0;
        response.on("data", (chunk) => {
          const buffer = Buffer.from(chunk);
          size += buffer.length;
          if (size > MAX_DOWNLOAD_BYTES) {
            request.destroy(new Error(`Download exceeds ${MAX_DOWNLOAD_BYTES} bytes`));
            return;
          }
          chunks.push(buffer);
        });
        response.on("end", () => resolve(Buffer.concat(chunks)));
        response.on("error", reject);
      },
    );
    request.setTimeout(30_000, () =>
      request.destroy(new Error(`Download timed out: ${url}`)),
    );
    request.on("error", reject);
  });
}
