import { createECDH } from 'node:crypto';
import type { PushChannel } from './crypto';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const record = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === 'object' && !Array.isArray(v);
const only = (v: Record<string, unknown>, keys: string[]) => Object.keys(v).length === keys.length && Object.keys(v).every((k) => keys.includes(k));

export function parsePushPreference(input: unknown): { enabled: boolean } {
  if (!record(input) || !only(input, ['enabled']) || typeof input.enabled !== 'boolean') throw new Error('PUSH_PREFERENCE_INVALID');
  return { enabled: input.enabled };
}

export function parsePushRevoke(input: unknown): { deviceId: string } {
  if (!record(input) || !only(input, ['deviceId']) || typeof input.deviceId !== 'string' || !uuid.test(input.deviceId)) throw new Error('PUSH_REVOKE_INVALID');
  return { deviceId: input.deviceId };
}

function validBase64Url(value: unknown, expectedBytes: number): boolean {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/.test(value)) return false;

  const bytes = Buffer.from(value, 'base64url');

  return bytes.length === expectedBytes &&
    bytes.toString('base64url') === value;
}

function validateWebPushEndpoint(endpoint: unknown): asserts endpoint is string {
  if (typeof endpoint !== 'string' || endpoint.length > 2048 ||
      !/^https:\/\//.test(endpoint)) {
    throw new Error('PUSH_DEVICE_INVALID');
  }

  let url: URL;

  try {
    url = new URL(endpoint);
  } catch {
    throw new Error('PUSH_DEVICE_INVALID');
  }

  const hostname = url.hostname.toLowerCase().replace(/^\[|\]$/g, '');

  if (
    url.protocol !== 'https:' ||
    !hostname ||
    !hostname.includes('.') ||
    url.username !== '' ||
    url.password !== '' ||
    url.hash !== '' ||
    (url.port !== '' && url.port !== '443') ||
    hostname === 'localhost' ||
    hostname.endsWith('.localhost') ||
    hostname.endsWith('.local') ||
    hostname.endsWith('.internal') ||
    /^[0-9.]+$/.test(hostname) ||
    hostname.includes(':')
  ) {
    throw new Error('PUSH_DEVICE_INVALID');
  }
}

export function parsePushDevice(input: unknown): {
  channel: PushChannel;
  credential: string;
  fingerprintSource: string;
} {
  if (!record(input) || !only(input, ['channel', 'credential']) ||
      (input.channel !== 'web_push' && input.channel !== 'android_fcm')) {
    throw new Error('PUSH_DEVICE_INVALID');
  }

  if (input.channel === 'android_fcm') {
    if (typeof input.credential !== 'string' ||
        input.credential.length < 16 ||
        input.credential.length > 4096 ||
        /\s/.test(input.credential)) {
      throw new Error('PUSH_DEVICE_INVALID');
    }

    return {
      channel: 'android_fcm',
      credential: input.credential,
      fingerprintSource: input.credential
    };
  }

  const c = input.credential;

  if (!record(c) || !only(c, ['endpoint', 'keys']) ||
      !record(c.keys) || !only(c.keys, ['p256dh', 'auth'])) {
    throw new Error('PUSH_DEVICE_INVALID');
  }

  validateWebPushEndpoint(c.endpoint);

  if (!validBase64Url(c.keys.p256dh, 65) ||
      !validBase64Url(c.keys.auth, 16)) {
    throw new Error('PUSH_DEVICE_INVALID');
  }

  const publicKey = Buffer.from(c.keys.p256dh as string, 'base64url');

  if (publicKey[0] !== 4) {
    throw new Error('PUSH_DEVICE_INVALID');
  }

  // Confirm the uncompressed public key is on the P-256 curve.
  try {
    const verifier = createECDH('prime256v1');
    verifier.generateKeys();
    verifier.computeSecret(publicKey);
  } catch {
    throw new Error('PUSH_DEVICE_INVALID');
  }

  return {
    channel: 'web_push',
    credential: JSON.stringify({
      endpoint: c.endpoint,
      keys: {
        p256dh: c.keys.p256dh,
        auth: c.keys.auth
      }
    }),
    fingerprintSource: c.endpoint
  };
}