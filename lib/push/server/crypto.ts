import 'server-only';
import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const fingerprintPattern = /^[a-f0-9]{64}$/;
export type PushChannel = 'web_push' | 'android_fcm';
function validateContext(userId: string, channel: PushChannel, fingerprint: string): Buffer {
  if (!uuid.test(userId) || !['web_push', 'android_fcm'].includes(channel) || !fingerprintPattern.test(fingerprint)) {
    throw new Error('PUSH_CONTEXT_INVALID');
  }
  return Buffer.from(`fantagol.push.v1\0${userId.toLowerCase()}\0${channel}\0${fingerprint}`, 'utf8');
}
function serverKey(): Buffer {
  const value = process.env.FANTAGOL_PUSH_ENCRYPTION_KEY_HEX;
  if (!value || !/^[0-9a-f]{64}$/i.test(value)) throw new Error('PUSH_KEY_NOT_CONFIGURED');
  return Buffer.from(value, 'hex');
}
/** Fingerprint binds the channel and transport endpoint; never store the endpoint in logs. */
export function endpointFingerprint(channel: PushChannel, endpoint: string): string {
  if (!['web_push', 'android_fcm'].includes(channel) || !endpoint) throw new Error('PUSH_ENDPOINT_INVALID');
  return createHash('sha256').update(`${channel}\0${endpoint}`, 'utf8').digest('hex');
}
/** Format: version(1) | IV(12) | GCM-tag(16) | ciphertext. */
export function encryptPushCredential(input: {
  userId: string; channel: PushChannel; fingerprint: string; credential: string;
}): Buffer {
  const associatedData = validateContext(input.userId, input.channel, input.fingerprint);
  if (!input.credential || Buffer.byteLength(input.credential, 'utf8') > 16384) throw new Error('PUSH_CREDENTIAL_INVALID');
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', serverKey(), iv);
  cipher.setAAD(associatedData);
  const body = Buffer.concat([cipher.update(input.credential, 'utf8'), cipher.final()]);
  return Buffer.concat([Buffer.from([1]), iv, cipher.getAuthTag(), body]);
}
export function decryptPushCredential(input: {
  userId: string; channel: PushChannel; fingerprint: string; envelope: Buffer;
}): string {
  const associatedData = validateContext(input.userId, input.channel, input.fingerprint);
  const bytes = input.envelope;
  if (!Buffer.isBuffer(bytes) || bytes.length < 30 || bytes[0] !== 1) throw new Error('PUSH_ENVELOPE_INVALID');
  const decipher = createDecipheriv('aes-256-gcm', serverKey(), bytes.subarray(1, 13));
  decipher.setAAD(associatedData);
  decipher.setAuthTag(bytes.subarray(13, 29));
  return Buffer.concat([decipher.update(bytes.subarray(29)), decipher.final()]).toString('utf8');
}
