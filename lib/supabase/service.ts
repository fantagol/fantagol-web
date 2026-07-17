import "server-only";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

let serviceClient: SupabaseClient | null = null;

function requireServerEnvironment(name: string): string {
  const value = process.env[name]?.trim();

  if (!value) {
    throw new Error(`Missing required server environment variable: ${name}`);
  }

  return value;
}

/**
 * Returns the privileged Supabase client used exclusively by trusted
 * server-side runtime code. The client never persists or refreshes sessions.
 */
export function getSupabaseServiceClient(): SupabaseClient {
  if (serviceClient) {
    return serviceClient;
  }

  const supabaseUrl =
    process.env.SUPABASE_URL?.trim() ||
    requireServerEnvironment("NEXT_PUBLIC_SUPABASE_URL");

  const serviceRoleKey = requireServerEnvironment(
    "SUPABASE_SERVICE_ROLE_KEY",
  );

  serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
    global: {
      headers: {
        "X-Client-Info": "fantagol-live-runtime",
      },
    },
  });

  return serviceClient;
}
