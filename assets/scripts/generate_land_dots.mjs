#!/usr/bin/env node
/**
 * Generates pre-baked land dot positions for the hero globe.
 *
 * Uses Natural Earth 50m land polygons + Turf.js for accurate
 * point-in-polygon testing. Outputs a JSON array of [lat, lng] pairs
 * matching the same grid logic as the runtime generateLandPoints().
 *
 * Usage: node assets/scripts/generate_land_dots.mjs
 * Output: assets/js/land_dots.json
 */

import { writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import booleanPointInPolygon from "@turf/boolean-point-in-polygon";
import { point } from "@turf/helpers";

const __dirname = dirname(fileURLToPath(import.meta.url));

const GEOJSON_URL =
  "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_land.geojson";

const STEP = 1.5;
const LAT_MIN = -80;
const LAT_MAX = 82;

async function fetchLandPolygons() {
  console.log("Fetching Natural Earth 50m land GeoJSON...");
  const res = await fetch(GEOJSON_URL);
  if (!res.ok) throw new Error(`Fetch failed: ${res.status}`);
  const geojson = await res.json();
  console.log(`  ${geojson.features.length} features loaded`);
  return geojson;
}

function isLand(lat, lng, features) {
  const pt = point([lng, lat]);
  for (const feature of features) {
    if (booleanPointInPolygon(pt, feature)) return true;
  }
  return false;
}

async function main() {
  const geojson = await fetchLandPolygons();
  const features = geojson.features;

  console.log("Generating land dots...");
  const dots = [];

  for (let lat = LAT_MIN; lat <= LAT_MAX; lat += STEP) {
    const lngStep = STEP / Math.max(Math.cos((lat * Math.PI) / 180), 0.3);
    for (let lng = -180; lng < 180; lng += lngStep) {
      if (isLand(lat, lng, features)) {
        dots.push([
          Math.round(lat * 100) / 100,
          Math.round(lng * 100) / 100,
        ]);
      }
    }
  }

  console.log(`  ${dots.length} land dots generated`);

  const outPath = join(__dirname, "..", "js", "land_dots.json");
  writeFileSync(outPath, JSON.stringify(dots));
  console.log(`Written to ${outPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
