#!/usr/bin/env node
/**
 * Generate protocol constants from doc/protocol.yaml
 * Usage: node scripts/generate-protocol.mjs
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const yamlPath = join(root, 'doc/protocol.yaml');
const text = readFileSync(yamlPath, 'utf8');

function parseSimpleYaml(source) {
  const result = { version: 1 };
  let section = null;
  for (const rawLine of source.split('\n')) {
    const line = rawLine.trimEnd();
    if (!line || line.startsWith('#')) continue;
    if (line.endsWith(':') && !line.startsWith('-')) {
      section = line.slice(0, -1);
      result[section] = [];
      continue;
    }
    const m = line.match(/^\s*-\s+(\S+)/);
    if (m && section) {
      result[section].push(m[1]);
    } else if (line.startsWith('version:')) {
      result.version = Number(line.split(':')[1].trim());
    }
  }
  return result;
}

const spec = parseSimpleYaml(text);

function swiftEnum(name, values) {
  const cases = values.map((v) => `    static let ${toSwiftCase(v)} = "${v}"`).join('\n');
  return `enum ${name} {\n${cases}\n}`;
}

function toSwiftCase(value) {
  return value.replace(/[^a-zA-Z0-9]+/g, '_').replace(/^_|_$/g, '');
}

function cMacroBlock(prefix, values) {
  return values.map((v) => `#define ${prefix}_${toCMacro(v)} "${v}"`).join('\n');
}

function toCMacro(value) {
  return value.replace(/[^a-zA-Z0-9]+/g, '_').toUpperCase();
}

const swiftPath = join(
  root,
  'client/macos-native/Sources/VibeCodingPlusNative/Server/ProtocolConstants.swift'
);
const swiftBody = `import Foundation

/// Generated from doc/protocol.yaml — do not edit by hand.
enum LANProtocol {
    static let version = ${spec.version}
}

${swiftEnum('LANDeviceMessage', spec.device_to_server)}

${swiftEnum('LANServerMessage', spec.server_to_device)}

${swiftEnum('LANSendTarget', spec.send_targets)}

${swiftEnum('LANVoiceMode', spec.voice_modes)}
`;
writeFileSync(swiftPath, swiftBody);

const cHeaderPath = join(root, 'firmware/main/protocol_messages.h');
const cBody = `#ifndef PROTOCOL_MESSAGES_H
#define PROTOCOL_MESSAGES_H

#define LAN_PROTOCOL_VERSION ${spec.version}

${cMacroBlock('LAN_MSG_DEVICE', spec.device_to_server)}

${cMacroBlock('LAN_MSG_SERVER', spec.server_to_device)}

#endif
`;
writeFileSync(cHeaderPath, cBody);

console.log(`Generated ${swiftPath}`);
console.log(`Generated ${cHeaderPath}`);
