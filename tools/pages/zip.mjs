// Bounded ZIP reader for Actions artifacts. Never extracts links or executes files.
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { inflateRawSync } from 'node:zlib';

export const limits = { archive: 200 * 1024 ** 2, build: 200 * 1024 ** 2, file: 99 * 1024 ** 2, site: 900 * 1024 ** 2 };

export function crc32(data) {
  let crc = 0xffffffff;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function safeNumber(value) {
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('ZIP64 value out of range');
  return Number(value);
}

export function entries(content) {
  if (content.length > limits.archive) throw new Error('Archive size limit exceeded');
  let end = content.length - 22;
  while (end >= Math.max(0, content.length - 65557)) {
    if (content.readUInt32LE(end) === 0x06054b50 && end + 22 + content.readUInt16LE(end + 20) === content.length) break;
    end--;
  }
  if (end < Math.max(0, content.length - 65557)) throw new Error('Missing ZIP directory');
  if (content.readUInt16LE(end + 4) || content.readUInt16LE(end + 6)) throw new Error('Multipart ZIP unsupported');
  let count = content.readUInt16LE(end + 10);
  let position = content.readUInt32LE(end + 16);
  if (count === 0xffff || position === 0xffffffff) {
    if (end < 20 || content.readUInt32LE(end - 20) !== 0x07064b50) throw new Error('Missing ZIP64 locator');
    const zip64 = safeNumber(content.readBigUInt64LE(end - 12));
    if (content.readUInt32LE(zip64) !== 0x06064b50 || content.readUInt32LE(zip64 + 16) || content.readUInt32LE(zip64 + 20)) throw new Error('Invalid ZIP64 directory');
    count = safeNumber(content.readBigUInt64LE(zip64 + 32));
    position = safeNumber(content.readBigUInt64LE(zip64 + 48));
  }
  if (count > 20000) throw new Error('Too many ZIP entries');
  const names = new Set();
  const result = [];
  let total = 0;
  for (let index = 0; index < count; index++) {
    if (content.readUInt32LE(position) !== 0x02014b50) throw new Error('Invalid ZIP entry');
    const flags = content.readUInt16LE(position + 8);
    const method = content.readUInt16LE(position + 10);
    const crc = content.readUInt32LE(position + 16);
    let compressed = content.readUInt32LE(position + 20);
    let size = content.readUInt32LE(position + 24);
    const length = content.readUInt16LE(position + 28);
    const extraLength = content.readUInt16LE(position + 30);
    const commentLength = content.readUInt16LE(position + 32);
    const mode = content.readUInt32LE(position + 38) >>> 16;
    let offset = content.readUInt32LE(position + 42);
    const name = content.subarray(position + 46, position + 46 + length).toString('utf8');
    let extra = position + 46 + length;
    const extraEnd = extra + extraLength;
    while (extra < extraEnd) {
      const tag = content.readUInt16LE(extra);
      const bytes = content.readUInt16LE(extra + 2);
      if (extra + 4 + bytes > extraEnd) throw new Error('Invalid ZIP extra field');
      if (tag === 1) {
        let at = extra + 4;
        if (size === 0xffffffff) { size = safeNumber(content.readBigUInt64LE(at)); at += 8; }
        if (compressed === 0xffffffff) { compressed = safeNumber(content.readBigUInt64LE(at)); at += 8; }
        if (offset === 0xffffffff) offset = safeNumber(content.readBigUInt64LE(at));
      }
      extra += 4 + bytes;
    }
    const directory = name.endsWith('/');
    const path = directory ? name.slice(0, -1) : name;
    const parts = path.split('/');
    const type = mode & 0o170000;
    if (!path || name.includes('\\') || name.includes('\0') || parts.some(part => !part || part.startsWith('.'))
        || parts[0] === 'previews' || names.has(path) || ![0, 0o100000, 0o040000].includes(type)
        || (type === 0o040000 && !directory) || (flags & 1) || ![0, 8].includes(method)
        || size > limits.file || compressed > limits.archive) throw new Error(`Unsafe ZIP entry: ${JSON.stringify(name)}`);
    names.add(path);
    total += size;
    if (total > limits.build) throw new Error('Expanded build size limit exceeded');
    if (content.readUInt32LE(offset) !== 0x04034b50) throw new Error('Invalid local ZIP header');
    const localNameLength = content.readUInt16LE(offset + 26);
    const localExtraLength = content.readUInt16LE(offset + 28);
    const localName = content.subarray(offset + 30, offset + 30 + localNameLength).toString('utf8');
    if (localName !== name || content.readUInt16LE(offset + 8) !== method) throw new Error('Inconsistent ZIP headers');
    const start = offset + 30 + localNameLength + localExtraLength;
    if (start + compressed > content.length) throw new Error('Truncated ZIP entry');
    result.push({ name: path, directory, method, crc, size, start, compressed });
    position += 46 + length + extraLength + commentLength;
  }
  if (!result.some(item => item.name === 'index.html' && !item.directory)) throw new Error('Artifact must contain index.html at root');
  return result;
}

export function safeExtract(content, destination) {
  const members = entries(content); // Validate every path before creating anything.
  for (const member of members) {
    const target = join(destination, member.name);
    if (member.directory) { mkdirSync(target, { recursive: true }); continue; }
    const compressed = content.subarray(member.start, member.start + member.compressed);
    const data = member.method === 0 ? compressed : inflateRawSync(compressed, { maxOutputLength: Math.max(member.size, 1) });
    if (data.length !== member.size || crc32(data) !== member.crc) throw new Error('ZIP size or checksum mismatch');
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, data, { flag: 'wx' });
  }
}
