import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

import { getSupabaseServiceClient } from "@/lib/supabase/service";

const SUPPORT_STATUSES = new Set([
  "new",
  "in_progress",
  "resolved",
  "closed",
]);

type SupportStatus =
  | "new"
  | "in_progress"
  | "resolved"
  | "closed";

type PatchBody = {
  requestId?: string;
  status?: SupportStatus;
};

function getBearerToken(request: NextRequest): string | null {
  const header = request.headers.get("authorization");

  if (!header?.startsWith("Bearer ")) {
    return null;
  }

  return header.slice("Bearer ".length).trim() || null;
}

function parseOperatorIds() {
  return new Set(
    (process.env.SUPPORT_CONSOLE_OPERATOR_USER_IDS || "")
      .split(",")
      .map((value) => value.trim().toLowerCase())
      .filter(Boolean),
  );
}

function isUuid(value: string) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}

async function authorizeOperator(request: NextRequest) {
  const accessToken = getBearerToken(request);

  if (!accessToken) {
    return {
      ok: false as const,
      response: NextResponse.json(
        { error: "Sessione non disponibile." },
        { status: 401 },
      ),
    };
  }

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!supabaseUrl || !anonKey) {
    return {
      ok: false as const,
      response: NextResponse.json(
        { error: "Configurazione server incompleta." },
        { status: 500 },
      ),
    };
  }

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
    error,
  } = await userClient.auth.getUser(accessToken);

  if (error || !user?.id) {
    return {
      ok: false as const,
      response: NextResponse.json(
        { error: "Sessione scaduta." },
        { status: 401 },
      ),
    };
  }

  const operatorIds = parseOperatorIds();

  if (!operatorIds.has(user.id.toLowerCase())) {
    return {
      ok: false as const,
      response: NextResponse.json(
        { error: "Accesso Support Console non autorizzato." },
        { status: 403 },
      ),
    };
  }

  return {
    ok: true as const,
    user,
  };
}

export async function GET(request: NextRequest) {
  const authorization = await authorizeOperator(request);

  if (!authorization.ok) {
    return authorization.response;
  }

  const url = new URL(request.url);
  const requestedStatus = url.searchParams.get("status")?.trim() || "";
  const requestId = url.searchParams.get("requestId")?.trim() || "";

  if (requestedStatus && !SUPPORT_STATUSES.has(requestedStatus)) {
    return NextResponse.json(
      { error: "Stato Support non valido." },
      { status: 400 },
    );
  }

  if (requestId && !isUuid(requestId)) {
    return NextResponse.json(
      { error: "Codice richiesta non valido." },
      { status: 400 },
    );
  }

  const serviceClient = getSupabaseServiceClient();

  let query = serviceClient
    .from("support_requests")
    .select(
      "id,user_id,league_id,category,subject,description,screenshot_path,source_page,user_agent,locale,status,created_at,updated_at,handled_by,handled_at,resolved_at,closed_at",
    )
    .order("created_at", { ascending: true })
    .limit(200);

  if (requestedStatus) {
    query = query.eq("status", requestedStatus);
  }

  if (requestId) {
    query = query.eq("id", requestId);
  }

  const { data, error } = await query;

  if (error) {
    console.error("Support Console ticket read error", error);

    return NextResponse.json(
      { error: "Impossibile leggere i ticket Support." },
      { status: 500 },
    );
  }

  const tickets = await Promise.all(
    (data || []).map(async (ticket) => {
      if (!ticket.screenshot_path) {
        return {
          ...ticket,
          screenshot_url: null,
        };
      }

      const { data: signed, error: signedError } =
        await serviceClient.storage
          .from("support-screenshots")
          .createSignedUrl(ticket.screenshot_path, 300);

      if (signedError) {
        console.error(
          "Support Console screenshot signing error",
          signedError,
        );

        return {
          ...ticket,
          screenshot_url: null,
        };
      }

      return {
        ...ticket,
        screenshot_url: signed.signedUrl,
      };
    }),
  );

  return NextResponse.json({
    tickets,
  });
}

export async function PATCH(request: NextRequest) {
  const authorization = await authorizeOperator(request);

  if (!authorization.ok) {
    return authorization.response;
  }

  const body = (await request.json()) as PatchBody;
  const requestId = body.requestId?.trim() || "";
  const status = body.status?.trim() || "";

  if (!isUuid(requestId)) {
    return NextResponse.json(
      { error: "Codice richiesta non valido." },
      { status: 400 },
    );
  }

  if (!SUPPORT_STATUSES.has(status)) {
    return NextResponse.json(
      { error: "Stato Support non valido." },
      { status: 400 },
    );
  }

  const serviceClient = getSupabaseServiceClient();

  const { data: current, error: currentError } =
    await serviceClient
      .from("support_requests")
      .select("id,status")
      .eq("id", requestId)
      .maybeSingle();

  if (currentError) {
    console.error("Support Console ticket lookup error", currentError);

    return NextResponse.json(
      { error: "Impossibile verificare il ticket." },
      { status: 500 },
    );
  }

  if (!current) {
    return NextResponse.json(
      { error: "Ticket non trovato." },
      { status: 404 },
    );
  }

  if (current.status === status) {
    return NextResponse.json({
      updated: false,
      ticket: current,
    });
  }

  const { data: updated, error: updateError } =
    await serviceClient
      .from("support_requests")
      .update({
        status,
        handled_by: authorization.user.id,
      })
      .eq("id", requestId)
      .select(
        "id,status,updated_at,handled_by,handled_at,resolved_at,closed_at",
      )
      .single();

  if (updateError) {
    console.error("Support Console ticket update error", updateError);

    const invalidTransition =
      updateError.message.includes(
        "SUPPORT_REQUEST_STATUS_TRANSITION_INVALID",
      );

    return NextResponse.json(
      {
        error: invalidTransition
          ? "Transizione di stato non consentita."
          : "Impossibile aggiornare il ticket.",
      },
      { status: invalidTransition ? 409 : 500 },
    );
  }

  return NextResponse.json({
    updated: true,
    ticket: updated,
  });
}