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
export function parsePushDevice(input: unknown): { channel: PushChannel; credential: string; fingerprintSource: string } {
  if (!record(input) || !only(input, ['channel', 'credential']) || (input.channel !== 'web_push' && input.channel !== 'android_fcm')) throw new Error('PUSH_DEVICE_INVALID');
  if (input.channel === 'android_fcm') {
    if (typeof input.credential !== 'string' || input.credential.length < 16 || input.credential.length > 4096 || /\s/.test(input.credential)) throw new Error('PUSH_DEVICE_INVALID');
    return { channel: 'android_fcm', credential: input.credential, fingerprintSource: input.credential };
  }
  const c = input.credential;
  if (!record(c) || !only(c, ['endpoint', 'keys']) || typeof c.endpoint !== 'string' || c.endpoint.length > 2048 || !/^https:\/\//.test(c.endpoint) || !record(c.keys) || !only(c.keys, ['p256dh', 'auth']) || typeof c.keys.p256dh !== 'string' || typeof c.keys.auth !== 'string' || !c.keys.p256dh || !c.keys.auth) throw new Error('PUSH_DEVICE_INVALID');
  return { channel: 'web_push', credential: JSON.stringify({ endpoint: c.endpoint, keys: { p256dh: c.keys.p256dh, auth: c.keys.auth } }), fingerprintSource: c.endpoint };
}
