import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

import { getSupabaseServiceClient } from "@/lib/supabase/service";

type RequestBody = {
  mode?: "password" | "oauth_recent";
  password?: string;
};

function getBearerToken(request: NextRequest): string | null {
  const header = request.headers.get("authorization");
  if (!header?.startsWith("Bearer ")) return null;
  return header.slice("Bearer ".length).trim() || null;
}

function decodeJwtPayload(token: string): Record<string, unknown> {
  const payload = token.split(".")[1];
  if (!payload) throw new Error("INVALID_ACCESS_TOKEN");

  const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized.padEnd(
    normalized.length + ((4 - (normalized.length % 4)) % 4),
    "=",
  );

  return JSON.parse(
    Buffer.from(padded, "base64").toString("utf8"),
  ) as Record<string, unknown>;
}

export async function POST(request: NextRequest) {
  try {
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

    if (!supabaseUrl || !anonKey) {
      return NextResponse.json(
        { error: "Configurazione server incompleta." },
        { status: 500 },
      );
    }

    const accessToken = getBearerToken(request);

    if (!accessToken) {
      return NextResponse.json(
        { error: "Sessione non disponibile." },
        { status: 401 },
      );
    }

    const body = (await request.json()) as RequestBody;

    const userClient = createClient(supabaseUrl, anonKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
      global: {
        headers: {
          Authorization: `Bearer ${accessToken}`,
        },
      },
    });

    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser(accessToken);

    if (userError || !user?.id) {
      return NextResponse.json(
        { error: "Sessione scaduta. Accedi nuovamente." },
        { status: 401 },
      );
    }

    let confirmationMethod:
      | "password_reauthentication"
      | "oauth_reauthentication";

    if (body.mode === "password") {
      const password = body.password || "";

      if (!user.email || password.length < 1) {
        return NextResponse.json(
          { error: "Inserisci la password dell’account." },
          { status: 400 },
        );
      }

      const verificationClient = createClient(supabaseUrl, anonKey, {
        auth: {
          autoRefreshToken: false,
          persistSession: false,
        },
      });

      const { data: verification, error: verificationError } =
        await verificationClient.auth.signInWithPassword({
          email: user.email,
          password,
        });

      if (
        verificationError ||
        verification.user?.id !== user.id
      ) {
        return NextResponse.json(
          { error: "Password non corretta." },
          { status: 401 },
        );
      }

      await verificationClient.auth.signOut();
      confirmationMethod = "password_reauthentication";
    } else if (body.mode === "oauth_recent") {
      const claims = decodeJwtPayload(accessToken);
      const issuedAt =
        typeof claims.iat === "number" ? claims.iat : 0;
      const ageSeconds = Math.floor(Date.now() / 1000) - issuedAt;
      const provider =
        typeof user.app_metadata?.provider === "string"
          ? user.app_metadata.provider
          : "";

      if (
        !provider ||
        provider === "email" ||
        ageSeconds < 0 ||
        ageSeconds > 300
      ) {
        return NextResponse.json(
          {
            error:
              "Ripeti l’accesso con il provider prima di continuare.",
          },
          { status: 401 },
        );
      }

      confirmationMethod = "oauth_reauthentication";
    } else {
      return NextResponse.json(
        { error: "Metodo di ri-autenticazione non valido." },
        { status: 400 },
      );
    }

    const serviceClient = getSupabaseServiceClient();

    const { data, error } = await serviceClient.rpc(
      "issue_account_deletion_reauth_grant_internal",
      {
        p_user_id: user.id,
        p_confirmation_method: confirmationMethod,
        p_ttl: "5 minutes",
        p_correlation_id: crypto.randomUUID(),
        p_metadata: {
          channel: "account_deletion_frontend",
          provider: user.app_metadata?.provider || null,
        },
      },
    );

    if (error) {
      console.error("Account deletion grant error", error);
      return NextResponse.json(
        { error: "Impossibile autorizzare la richiesta." },
        { status: 500 },
      );
    }

    const row = Array.isArray(data) ? data[0] : data;

    if (!row?.grant_token || !row?.expires_at) {
      return NextResponse.json(
        { error: "Grant di ri-autenticazione non disponibile." },
        { status: 500 },
      );
    }

    return NextResponse.json({
      grantToken: row.grant_token,
      expiresAt: row.expires_at,
      confirmationMethod,
    });
  } catch (error) {
    console.error("Account deletion reauth route error", error);

    return NextResponse.json(
      { error: "Ri-autenticazione non riuscita." },
      { status: 500 },
    );
  }
}
