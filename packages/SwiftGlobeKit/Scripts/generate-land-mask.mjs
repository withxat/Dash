#!/usr/bin/env node
/**
 * Generates SwiftGlobeKit's deterministic, 1-bit equirectangular land mask.
 *
 * The source is Natural Earth 1:110m land data pinned to the v5.1.2 commit.
 * The 256x128 output matches the source's global-detail level while keeping
 * the globe shader's bundled lookup texture small. Pixel centers are sampled
 * without antialiasing: black is water and white is land.
 *
 * Usage:
 *   node Scripts/generate-land-mask.mjs
 *   node Scripts/generate-land-mask.mjs --check
 */
import { createHash } from "node:crypto";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import https from "node:https";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { inflateSync } from "node:zlib";

const SOURCE_COMMIT = "f1890d9f152c896d250a77557a5751a93d494776";
const SOURCE_URL =
  `https://raw.githubusercontent.com/nvkelso/natural-earth-vector/${SOURCE_COMMIT}` +
  "/geojson/ne_110m_land.geojson";
const SOURCE_SHA256 =
  "9e0729ee253ca7d7a5c4ae9395fb1902264c5377c52e224d13dd85010e2835d9";
const EXPECTED_OUTPUT_SHA256 =
  "b00eb21e29b2efe4b0a47595db420c158ec1babe2d65fe6d16d505ab6b093f44";

const WIDTH = 256;
const HEIGHT = 128;
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const MAX_DOWNLOAD_BYTES = 2 * 1024 * 1024;
const EPSILON = 1e-9;

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(scriptDirectory, "..");
const outputPath = path.join(
  packageDirectory,
  "Sources",
  "SwiftGlobeKit",
  "Resources",
  "LandMask.png",
);

const argumentsList = process.argv.slice(2);
const checkOnly = argumentsList.includes("--check");
const unknownArguments = argumentsList.filter(
  (argument) => argument !== "--check",
);

if (unknownArguments.length > 0) {
  throw new Error(
    `Unknown argument${unknownArguments.length === 1 ? "" : "s"}: ${unknownArguments.join(", ")}`,
  );
}

await main();

async function main() {
  runGeometrySelfTests();

  const source = await download(SOURCE_URL);
  assertSha256(source, SOURCE_SHA256, "Natural Earth source");

  const geoJSON = parseGeoJSON(source);
  const prepared = prepareFeatureCollection(geoJSON);
  const raster = rasterize(prepared.polygons, WIDTH, HEIGHT);
  const png = encodeGrayscaleOneBitPNG(raster.scanlines, WIDTH, HEIGHT);
  const metadata = inspectPNG(png);
  const outputSha256 = sha256(png);

  if (outputSha256 !== EXPECTED_OUTPUT_SHA256) {
    throw new Error(
      `Generated PNG SHA-256 mismatch: expected ${EXPECTED_OUTPUT_SHA256}, received ${outputSha256}`,
    );
  }

  let result;
  if (checkOnly) {
    const committed = await readOutput();
    if (!committed.equals(png)) {
      throw new Error(
        `${outputPath} is stale. Run node Scripts/generate-land-mask.mjs from packages/SwiftGlobeKit.`,
      );
    }
    result = "checked (committed bytes match deterministic regeneration)";
  } else {
    await mkdir(path.dirname(outputPath), { recursive: true });
    const existing = await readOutput({ optional: true });
    if (existing?.equals(png)) {
      result = "unchanged";
    } else {
      await writeFile(outputPath, png);
      result = "written";
    }
  }

  printReport({
    geometry: prepared,
    landPixels: raster.landPixels,
    metadata,
    outputSha256,
    result,
    sourceBytes: source.length,
  });
}

/**
 * Downloads a small pinned source file without redirects escaping HTTPS.
 *
 * @param {string} url
 * @param {number} redirects
 * @returns {Promise<Buffer>}
 */
function download(url, redirects = 0) {
  if (redirects > 5)
    throw new Error(`Too many redirects while downloading ${SOURCE_URL}`);

  return new Promise((resolve, reject) => {
    const request = https.get(
      url,
      {
        headers: {
          Accept: "application/geo+json, application/json",
          "User-Agent": "SwiftGlobeKit-land-mask-generator",
        },
      },
      (response) => {
        const status = response.statusCode ?? 0;

        if (status >= 300 && status < 400 && response.headers.location) {
          const redirectedURL = new URL(response.headers.location, url);
          response.resume();
          if (redirectedURL.protocol !== "https:") {
            reject(
              new Error(`Refusing non-HTTPS redirect to ${redirectedURL.href}`),
            );
            return;
          }
          download(redirectedURL.href, redirects + 1).then(resolve, reject);
          return;
        }

        if (status !== 200) {
          response.resume();
          reject(new Error(`Download failed with HTTP ${status}: ${url}`));
          return;
        }

        /** @type {Buffer[]} */
        const chunks = [];
        let byteCount = 0;
        response.on("data", (chunk) => {
          const buffer = Buffer.from(chunk);
          byteCount += buffer.length;
          if (byteCount > MAX_DOWNLOAD_BYTES) {
            request.destroy(
              new Error(`Download exceeds ${MAX_DOWNLOAD_BYTES} bytes`),
            );
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

/**
 * @param {Buffer} source
 * @returns {GeoJSONFeatureCollection}
 */
function parseGeoJSON(source) {
  let parsed;
  try {
    parsed = JSON.parse(source.toString("utf8"));
  } catch (error) {
    throw new Error(`Natural Earth source is not valid JSON: ${error.message}`);
  }

  if (parsed?.type !== "FeatureCollection" || !Array.isArray(parsed.features)) {
    throw new Error("Natural Earth source must be a GeoJSON FeatureCollection");
  }

  return parsed;
}

/**
 * Converts Polygon and MultiPolygon features into validated, reusable rings.
 *
 * Rings that cross the antimeridian are unwrapped into a continuous longitude
 * interval and tested against periodic query copies. An explicit +180/-180
 * edge at the same latitude is kept as a world-boundary edge; Natural Earth's
 * Antarctic polygon uses this GeoJSON construction to close over the pole.
 *
 * @param {GeoJSONFeatureCollection} collection
 */
function prepareFeatureCollection(collection) {
  /** @type {PreparedPolygon[]} */
  const polygons = [];
  let polygonFeatures = 0;
  let multiPolygonFeatures = 0;
  let ringCount = 0;
  let holeCount = 0;
  let antimeridianRingCount = 0;

  for (const [featureIndex, feature] of collection.features.entries()) {
    const geometry = feature?.geometry;
    if (!geometry) throw new Error(`Feature ${featureIndex} has no geometry`);

    let coordinatePolygons;
    if (geometry.type === "Polygon") {
      polygonFeatures += 1;
      coordinatePolygons = [geometry.coordinates];
    } else if (geometry.type === "MultiPolygon") {
      multiPolygonFeatures += 1;
      coordinatePolygons = geometry.coordinates;
    } else {
      throw new Error(
        `Feature ${featureIndex} has unsupported geometry type ${geometry.type}`,
      );
    }

    if (!Array.isArray(coordinatePolygons)) {
      throw new Error(`Feature ${featureIndex} has invalid coordinates`);
    }

    for (const [polygonIndex, rings] of coordinatePolygons.entries()) {
      const prepared = preparePolygon(
        rings,
        `feature ${featureIndex}, polygon ${polygonIndex}`,
      );
      polygons.push(prepared);
      ringCount += 1 + prepared.holes.length;
      holeCount += prepared.holes.length;
      antimeridianRingCount += prepared.antimeridianRingCount;
    }
  }

  if (polygons.length === 0)
    throw new Error("Natural Earth source contains no polygons");

  return {
    antimeridianRingCount,
    featureCount: collection.features.length,
    holeCount,
    multiPolygonFeatures,
    polygonFeatures,
    polygons,
    ringCount,
  };
}

/**
 * @param {number[][][]} rings
 * @param {string} context
 * @returns {PreparedPolygon}
 */
function preparePolygon(rings, context) {
  if (!Array.isArray(rings) || rings.length === 0) {
    throw new Error(`${context} has no rings`);
  }

  const preparedRings = rings.map((ring, ringIndex) =>
    prepareRing(ring, `${context}, ring ${ringIndex}`),
  );

  return {
    antimeridianRingCount: preparedRings.filter(
      (ring) => ring.crossesAntimeridian,
    ).length,
    holes: preparedRings.slice(1),
    outer: preparedRings[0],
  };
}

/**
 * @param {number[][]} coordinates
 * @param {string} context
 * @returns {PreparedRing}
 */
function prepareRing(coordinates, context) {
  if (!Array.isArray(coordinates) || coordinates.length < 4) {
    throw new Error(`${context} must contain at least four coordinates`);
  }

  const points = coordinates.map((coordinate, coordinateIndex) => {
    if (
      !Array.isArray(coordinate) ||
      coordinate.length < 2 ||
      !Number.isFinite(coordinate[0]) ||
      !Number.isFinite(coordinate[1])
    ) {
      throw new Error(`${context}, coordinate ${coordinateIndex} is invalid`);
    }

    const longitude = coordinate[0];
    const latitude = coordinate[1];
    if (
      longitude < -180 ||
      longitude > 180 ||
      latitude < -90 ||
      latitude > 90
    ) {
      throw new Error(
        `${context}, coordinate ${coordinateIndex} is outside WGS84 bounds`,
      );
    }

    return { latitude, longitude };
  });

  const first = points[0];
  const last = points.at(-1);
  if (
    Math.abs(first.longitude - last.longitude) >= EPSILON ||
    Math.abs(first.latitude - last.latitude) >= EPSILON
  ) {
    throw new Error(`${context} must be a closed GeoJSON LinearRing`);
  }

  const antimeridianEdges = points.filter((point, index) => {
    if (index === 0) return false;
    const previous = points[index - 1];
    return Math.abs(point.longitude - previous.longitude) > 180;
  });
  const hasWrappedEdge = points.some((point, index) => {
    if (index === 0) return false;
    const previous = points[index - 1];
    return (
      Math.abs(point.longitude - previous.longitude) > 180 &&
      !isExplicitWorldBoundaryEdge(previous, point)
    );
  });

  const rasterPoints = hasWrappedEdge ? unwrapRing(points) : points;
  const longitudeValues = rasterPoints.map((point) => point.longitude);
  const latitudeValues = rasterPoints.map((point) => point.latitude);

  return {
    maxLatitude: Math.max(...latitudeValues),
    maxLongitude: Math.max(...longitudeValues),
    minLatitude: Math.min(...latitudeValues),
    minLongitude: Math.min(...longitudeValues),
    crossesAntimeridian: antimeridianEdges.length > 0,
    periodic: hasWrappedEdge,
    points: rasterPoints,
  };
}

/**
 * @param {Coordinate} start
 * @param {Coordinate} end
 */
function isExplicitWorldBoundaryEdge(start, end) {
  return (
    Math.abs(Math.abs(start.longitude) - 180) < EPSILON &&
    Math.abs(Math.abs(end.longitude) - 180) < EPSILON &&
    Math.sign(start.longitude) !== Math.sign(end.longitude) &&
    Math.abs(start.latitude - end.latitude) < EPSILON
  );
}

/**
 * @param {Coordinate[]} points
 * @returns {Coordinate[]}
 */
function unwrapRing(points) {
  /** @type {Coordinate[]} */
  const unwrapped = [{ ...points[0] }];

  for (let index = 1; index < points.length; index += 1) {
    const point = points[index];
    const previousSource = points[index - 1];
    const previousUnwrapped = unwrapped[index - 1];
    let delta = point.longitude - previousSource.longitude;

    while (delta > 180) delta -= 360;
    while (delta < -180) delta += 360;

    unwrapped.push({
      latitude: point.latitude,
      longitude: previousUnwrapped.longitude + delta,
    });
  }

  return unwrapped;
}

/**
 * @param {PreparedPolygon[]} polygons
 * @param {number} width
 * @param {number} height
 */
function rasterize(polygons, width, height) {
  if (width <= 0 || height <= 0 || width % 8 !== 0) {
    throw new Error(
      "The one-bit raster dimensions must be positive and the width divisible by eight",
    );
  }

  const rowBytes = width / 8;
  const scanlines = Buffer.alloc(height * (rowBytes + 1));
  let landPixels = 0;

  for (let y = 0; y < height; y += 1) {
    const latitude = 90 - ((y + 0.5) / height) * 180;
    const rowOffset = y * (rowBytes + 1);
    scanlines[rowOffset] = 0;

    for (let x = 0; x < width; x += 1) {
      const longitude = ((x + 0.5) / width) * 360 - 180;
      if (!pointInPolygons(longitude, latitude, polygons)) continue;

      const byteOffset = rowOffset + 1 + Math.floor(x / 8);
      scanlines[byteOffset] |= 1 << (7 - (x % 8));
      landPixels += 1;
    }
  }

  return { landPixels, scanlines };
}

/**
 * @param {number} longitude
 * @param {number} latitude
 * @param {PreparedPolygon[]} polygons
 */
function pointInPolygons(longitude, latitude, polygons) {
  return polygons.some((polygon) =>
    pointInPolygon(longitude, latitude, polygon),
  );
}

/**
 * GeoJSON defines the first ring as the exterior and subsequent rings as
 * holes, independent of winding order.
 *
 * @param {number} longitude
 * @param {number} latitude
 * @param {PreparedPolygon} polygon
 */
function pointInPolygon(longitude, latitude, polygon) {
  if (!pointInRing(longitude, latitude, polygon.outer)) return false;
  return !polygon.holes.some((hole) => pointInRing(longitude, latitude, hole));
}

/**
 * @param {number} longitude
 * @param {number} latitude
 * @param {PreparedRing} ring
 */
function pointInRing(longitude, latitude, ring) {
  if (latitude < ring.minLatitude || latitude > ring.maxLatitude) return false;

  if (!ring.periodic) {
    if (longitude < ring.minLongitude || longitude > ring.maxLongitude)
      return false;
    return pointInPlanarRing(longitude, latitude, ring.points);
  }

  const center = (ring.minLongitude + ring.maxLongitude) / 2;
  const nearestCopy = longitude + Math.round((center - longitude) / 360) * 360;

  for (const queryLongitude of [
    nearestCopy - 360,
    nearestCopy,
    nearestCopy + 360,
  ]) {
    if (
      queryLongitude < ring.minLongitude ||
      queryLongitude > ring.maxLongitude
    )
      continue;
    if (pointInPlanarRing(queryLongitude, latitude, ring.points)) return true;
  }

  return false;
}

/**
 * Even-odd ray casting at a pixel center.
 *
 * @param {number} longitude
 * @param {number} latitude
 * @param {Coordinate[]} points
 */
function pointInPlanarRing(longitude, latitude, points) {
  let inside = false;

  for (
    let index = 0, previousIndex = points.length - 1;
    index < points.length;
    previousIndex = index++
  ) {
    const point = points[index];
    const previous = points[previousIndex];
    const crossesLatitude =
      point.latitude > latitude !== previous.latitude > latitude;

    if (
      crossesLatitude &&
      longitude <
        ((previous.longitude - point.longitude) * (latitude - point.latitude)) /
          (previous.latitude - point.latitude) +
          point.longitude
    ) {
      inside = !inside;
    }
  }

  return inside;
}

/**
 * Builds a PNG with IHDR bit depth 1 and grayscale color type 0. The zlib
 * stream uses stored DEFLATE blocks, so byte output doesn't vary with the
 * host's zlib compression heuristics or version.
 *
 * @param {Buffer} scanlines
 * @param {number} width
 * @param {number} height
 */
function encodeGrayscaleOneBitPNG(scanlines, width, height) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 1;
  ihdr[9] = 0;
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  return Buffer.concat([
    PNG_SIGNATURE,
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", zlibStore(scanlines)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

/**
 * @param {string} type
 * @param {Buffer} data
 */
function pngChunk(type, data) {
  const typeBytes = Buffer.from(type, "ascii");
  const chunk = Buffer.alloc(12 + data.length);
  chunk.writeUInt32BE(data.length, 0);
  typeBytes.copy(chunk, 4);
  data.copy(chunk, 8);
  chunk.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])), 8 + data.length);
  return chunk;
}

/**
 * Emits a deterministic zlib stream composed solely of stored DEFLATE blocks.
 *
 * @param {Buffer} data
 */
function zlibStore(data) {
  const parts = [Buffer.from([0x78, 0x01])];
  let offset = 0;

  while (offset < data.length) {
    const length = Math.min(65_535, data.length - offset);
    const final = offset + length === data.length;
    const blockHeader = Buffer.alloc(5);
    blockHeader[0] = final ? 1 : 0;
    blockHeader.writeUInt16LE(length, 1);
    blockHeader.writeUInt16LE(~length & 0xffff, 3);
    parts.push(blockHeader, data.subarray(offset, offset + length));
    offset += length;
  }

  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(adler32(data), 0);
  parts.push(checksum);
  return Buffer.concat(parts);
}

/**
 * @param {Buffer} data
 */
function crc32(data) {
  let crc = 0xffffffff;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/**
 * @param {Buffer} data
 */
function adler32(data) {
  const modulus = 65_521;
  let a = 1;
  let b = 0;

  for (const byte of data) {
    a = (a + byte) % modulus;
    b = (b + a) % modulus;
  }

  return ((b << 16) | a) >>> 0;
}

/**
 * Validates the PNG container, CRCs, grayscale bit depth, scanline filters,
 * and decompressed byte count.
 *
 * @param {Buffer} png
 */
function inspectPNG(png) {
  if (!png.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) {
    throw new Error("Generated file does not have a PNG signature");
  }

  let offset = PNG_SIGNATURE.length;
  let ihdr;
  /** @type {Buffer[]} */
  const idatChunks = [];
  let sawIend = false;

  while (offset < png.length) {
    if (offset + 12 > png.length)
      throw new Error("PNG contains a truncated chunk");

    const length = png.readUInt32BE(offset);
    const type = png.toString("ascii", offset + 4, offset + 8);
    const dataStart = offset + 8;
    const dataEnd = dataStart + length;
    const crcOffset = dataEnd;
    if (crcOffset + 4 > png.length)
      throw new Error(`PNG ${type} chunk is truncated`);

    const data = png.subarray(dataStart, dataEnd);
    const expectedCRC = png.readUInt32BE(crcOffset);
    const actualCRC = crc32(Buffer.concat([Buffer.from(type, "ascii"), data]));
    if (actualCRC !== expectedCRC)
      throw new Error(`PNG ${type} CRC is invalid`);

    if (type === "IHDR") ihdr = data;
    else if (type === "IDAT") idatChunks.push(data);
    else if (type === "IEND") sawIend = true;

    offset = crcOffset + 4;
  }

  if (!ihdr || ihdr.length !== 13)
    throw new Error("PNG must contain one valid IHDR chunk");
  if (idatChunks.length === 0) throw new Error("PNG must contain IDAT data");
  if (!sawIend) throw new Error("PNG must contain IEND");

  const width = ihdr.readUInt32BE(0);
  const height = ihdr.readUInt32BE(4);
  const bitDepth = ihdr[8];
  const colorType = ihdr[9];
  const compression = ihdr[10];
  const filter = ihdr[11];
  const interlace = ihdr[12];

  if (width !== WIDTH || height !== HEIGHT) {
    throw new Error(
      `PNG dimensions must be ${WIDTH}x${HEIGHT}, received ${width}x${height}`,
    );
  }
  if (bitDepth !== 1 || colorType !== 0) {
    throw new Error(
      `PNG must be 1-bit grayscale; received bit depth ${bitDepth}, color type ${colorType}`,
    );
  }
  if (compression !== 0 || filter !== 0 || interlace !== 0) {
    throw new Error(
      "PNG must use standard compression/filter methods without interlacing",
    );
  }

  const decoded = inflateSync(Buffer.concat(idatChunks));
  const rowBytes = Math.ceil(width / 8);
  const expectedDecodedBytes = height * (rowBytes + 1);
  if (decoded.length !== expectedDecodedBytes) {
    throw new Error(
      `PNG decoded data must be ${expectedDecodedBytes} bytes, received ${decoded.length}`,
    );
  }

  for (let y = 0; y < height; y += 1) {
    if (decoded[y * (rowBytes + 1)] !== 0) {
      throw new Error(`PNG scanline ${y} uses a nonzero filter`);
    }
  }

  return {
    bitDepth,
    colorType,
    decodedBytes: decoded.length,
    height,
    width,
  };
}

function runGeometrySelfTests() {
  const antimeridian = preparePolygon(
    [
      [
        [170, -10],
        [-170, -10],
        [-170, 10],
        [170, 10],
        [170, -10],
      ],
    ],
    "antimeridian self-test",
  );
  assert(
    pointInPolygon(179, 0, antimeridian),
    "Antimeridian polygon must contain +179°",
  );
  assert(
    pointInPolygon(-179, 0, antimeridian),
    "Antimeridian polygon must contain -179°",
  );
  assert(
    !pointInPolygon(0, 0, antimeridian),
    "Antimeridian polygon must exclude 0°",
  );

  const withHole = preparePolygon(
    [
      [
        [-20, -20],
        [20, -20],
        [20, 20],
        [-20, 20],
        [-20, -20],
      ],
      [
        [-5, -5],
        [-5, 5],
        [5, 5],
        [5, -5],
        [-5, -5],
      ],
    ],
    "hole self-test",
  );
  assert(
    pointInPolygon(10, 0, withHole),
    "Polygon exterior must rasterize as land",
  );
  assert(
    !pointInPolygon(0, 0, withHole),
    "Polygon hole must rasterize as water",
  );

  const polarBoundary = preparePolygon(
    [
      [
        [-180, -90],
        [180, -90],
        [180, -80],
        [-180, -80],
        [-180, -90],
      ],
    ],
    "world-boundary self-test",
  );
  assert(
    pointInPolygon(0, -85, polarBoundary),
    "Explicit world-boundary edge must not collapse",
  );

  const multiPolygonCollection = {
    features: [
      {
        geometry: {
          coordinates: [
            [
              [
                [-40, -5],
                [-30, -5],
                [-30, 5],
                [-40, 5],
                [-40, -5],
              ],
            ],
            [
              [
                [30, -5],
                [40, -5],
                [40, 5],
                [30, 5],
                [30, -5],
              ],
            ],
          ],
          type: "MultiPolygon",
        },
        type: "Feature",
      },
    ],
    type: "FeatureCollection",
  };
  const preparedMultiPolygon = prepareFeatureCollection(multiPolygonCollection);
  assert(
    pointInPolygons(-35, 0, preparedMultiPolygon.polygons) &&
      pointInPolygons(35, 0, preparedMultiPolygon.polygons),
    "Every MultiPolygon member must rasterize",
  );
}

/**
 * @param {boolean} condition
 * @param {string} message
 */
function assert(condition, message) {
  if (!condition) throw new Error(`Geometry self-test failed: ${message}`);
}

/**
 * @param {Buffer} data
 * @param {string} expected
 * @param {string} label
 */
function assertSha256(data, expected, label) {
  const actual = sha256(data);
  if (actual !== expected) {
    throw new Error(
      `${label} SHA-256 mismatch: expected ${expected}, received ${actual}`,
    );
  }
}

/**
 * @param {Buffer} data
 */
function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

/**
 * @param {{ optional?: boolean }} options
 */
async function readOutput({ optional = false } = {}) {
  try {
    return await readFile(outputPath);
  } catch (error) {
    if (optional && error.code === "ENOENT") return undefined;
    if (error.code === "ENOENT")
      throw new Error(`Missing generated asset: ${outputPath}`);
    throw error;
  }
}

function printReport({
  geometry,
  landPixels,
  metadata,
  outputSha256,
  result,
  sourceBytes,
}) {
  const totalPixels = metadata.width * metadata.height;
  const landPercentage = ((landPixels / totalPixels) * 100).toFixed(2);

  console.log(`Natural Earth source: ${SOURCE_URL}`);
  console.log(`Source SHA-256: ${SOURCE_SHA256} (${sourceBytes} bytes)`);
  console.log(
    `Geometry: ${geometry.featureCount} features, ${geometry.polygons.length} polygons, ` +
      `${geometry.ringCount} rings, ${geometry.holeCount} holes, ` +
      `${geometry.antimeridianRingCount} antimeridian-aware rings`,
  );
  console.log(
    `PNG: ${metadata.width}x${metadata.height}, grayscale color type ${metadata.colorType}, ` +
      `${metadata.bitDepth}-bit, ${metadata.decodedBytes} decoded bytes`,
  );
  console.log(
    `Land coverage: ${landPixels}/${totalPixels} pixels (${landPercentage}%)`,
  );
  console.log(`Output SHA-256: ${outputSha256}`);
  console.log(`Output: ${outputPath} (${result})`);
}

/**
 * @typedef {{
 *   type: 'FeatureCollection',
 *   features: Array<{
 *     type: 'Feature',
 *     geometry: {
 *       type: 'Polygon' | 'MultiPolygon',
 *       coordinates: number[][][] | number[][][][]
 *     }
 *   }>
 * }} GeoJSONFeatureCollection
 */

/**
 * @typedef {{ longitude: number, latitude: number }} Coordinate
 */

/**
 * @typedef {{
 *   points: Coordinate[],
 *   crossesAntimeridian: boolean,
 *   periodic: boolean,
 *   minLongitude: number,
 *   maxLongitude: number,
 *   minLatitude: number,
 *   maxLatitude: number
 * }} PreparedRing
 */

/**
 * @typedef {{
 *   outer: PreparedRing,
 *   holes: PreparedRing[],
 *   antimeridianRingCount: number
 * }} PreparedPolygon
 */
