// Decode the actual tvOS-rendered page, rather than relying on Vision's
// simulator barcode implementation. jsQR is vendored with its MIT license.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const jsQR = require('./vendor/jsQR.cjs');
const path = process.argv[2];
const {width, height} = JSON.parse(fs.readFileSync(path + '.json', 'utf8'));
const pixels = new Uint8ClampedArray(fs.readFileSync(path));
const found = new Set();
for (let attempt = 0; attempt < 3; attempt++) {
  const result = jsQR(pixels, width, height);
  if (!result) break;
  found.add(result.data);
  const corners = Object.entries(result.location).filter(([key]) => key.endsWith('Corner')).map(([, value]) => value);
  const minX = Math.max(0, Math.floor(Math.min(...corners.map(p => p.x))) - 12);
  const maxX = Math.min(width - 1, Math.ceil(Math.max(...corners.map(p => p.x))) + 12);
  const minY = Math.max(0, Math.floor(Math.min(...corners.map(p => p.y))) - 12);
  const maxY = Math.min(height - 1, Math.ceil(Math.max(...corners.map(p => p.y))) + 12);
  // Hide the decoded symbol in memory so the next pass finds the other panel.
  for (let y = minY; y <= maxY; y++) for (let x = minX; x <= maxX; x++) {
    const offset = (y * width + x) * 4;
    pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = pixels[offset + 3] = 255;
  }
}
assert.deepEqual([...found].sort(), [
  'https://github.com/LiveContainer/LiveContainer',
  'https://github.com/hubzzzgr/SideStore-tvOS',
].sort());
console.log('Rendered QR codes decoded to both exact GitHub destinations.');
