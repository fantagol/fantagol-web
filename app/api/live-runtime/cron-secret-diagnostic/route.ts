import {
  NextResponse,
} from "next/server";

function envState(
  name: string,
) {
  const raw =
    process.env[name];

  const trimmed =
    raw?.trim() ?? "";

  return {
    configured:
      trimmed.length > 0,

    rawLength:
      raw?.length ?? 0,

    trimmedLength:
      trimmed.length,
  };
}

export async function GET() {
  return NextResponse.json(
    {
      ok: true,

      providers: {
        theOddsApi: {
          apiKey:
            envState(
              "THE_ODDS_API_KEY",
            ),
        },

        footballData: {
          apiKey:
            envState(
              "FOOTBALL_DATA_API_KEY",
            ),

          baseUrl:
            envState(
              "FOOTBALL_DATA_BASE_URL",
            ),
        },
      },

      runtime: {
        cronSecret:
          envState(
            "CRON_SECRET",
          ),

        serviceRole:
          envState(
            "SUPABASE_SERVICE_ROLE_KEY",
          ),

        supabaseUrl:
          envState(
            "NEXT_PUBLIC_SUPABASE_URL",
          ),
      },
    },
    {
      status: 200,

      headers: {
        "Cache-Control":
          "no-store, max-age=0",
      },
    },
  );
}