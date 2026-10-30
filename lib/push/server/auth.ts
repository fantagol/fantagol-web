import 'server-only';
import { createClient } from '@supabase/supabase-js';

/** This guard does not authorize database writes or grant RPC execution. */
export async function requirePushUser(authorization: string | null): Promise<string> {
  const match = /^Bearer ([A-Za-z0-9._~-]{1,8192})$/.exec(authorization ?? '');
  if (!match) throw new Error('PUSH_AUTH_REQUIRED');
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anonKey) throw new Error('PUSH_AUTH_CONFIG_MISSING');
  const supabase = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data, error } = await supabase.auth.getUser(match[1]);
  if (error || !data.user?.id) throw new Error('PUSH_AUTH_REQUIRED');
  return data.user.id;
}
