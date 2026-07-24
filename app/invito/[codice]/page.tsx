"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "next/navigation";
import Header from "../../../components/Header";
import { supabase } from "../../../lib/supabaseClient";

const PENDING_AUTH_DESTINATION_KEY = "fantagol.pendingAuthDestination.v1";
const PENDING_INVITE_INTENT_KEY = "fantagol.pendingInviteIntent.v1";

type PendingInviteIntent = {
  inviteCode: string;
  displayName: string;
};

function readPendingInviteIntent(
  expectedInviteCode: string,
): PendingInviteIntent | null {
  const raw = window.localStorage.getItem(PENDING_INVITE_INTENT_KEY);

  if (!raw) {
    return null;
  }

  try {
    const parsed = JSON.parse(raw) as Partial<PendingInviteIntent>;

    if (
      typeof parsed.inviteCode !== "string" ||
      typeof parsed.displayName !== "string"
    ) {
      return null;
    }

    const intent = {
      inviteCode: parsed.inviteCode.trim(),
      displayName: parsed.displayName.trim(),
    };

    if (
      intent.inviteCode.toUpperCase() !==
      expectedInviteCode.trim().toUpperCase()
    ) {
      return null;
    }

    return intent;
  } catch {
    return null;
  }
}

export default function InvitoPage() {
  const params = useParams();

  const codice = useMemo(
    () => decodeURIComponent(String(params.codice ?? "")).trim(),
    [params.codice],
  );

  const inviteDestination = `/invito/${encodeURIComponent(codice)}`;

  const [displayName, setDisplayName] = useState("");
  const [loading, setLoading] = useState(false);
  const [sessionChecked, setSessionChecked] = useState(false);

  const autoResumeAttempted = useRef(false);

  const joinLeague = useCallback(
    async (name: string) => {
      const normalizedName = name.trim();

      if (!normalizedName) {
        alert("Inserisci il nome con cui vuoi apparire nella lega.");
        return;
      }

      setLoading(true);

      const { data, error } = await supabase.rpc("join_league_rpc", {
        target_invite_code: codice,
        member_display_name: normalizedName,
      });

      if (error) {
        setLoading(false);
        alert(error.message);
        return;
      }

      const leagueId = data?.[0]?.joined_league_id;

      if (!leagueId) {
        setLoading(false);
        alert("Errore durante l'ingresso nella lega.");
        return;
      }

      window.localStorage.removeItem(PENDING_INVITE_INTENT_KEY);
      window.location.assign(`/leghe/${leagueId}`);
    },
    [codice],
  );

  useEffect(() => {
    let cancelled = false;

    async function restoreInviteContinuation() {
      const pendingIntent = readPendingInviteIntent(codice);

      if (pendingIntent?.displayName) {
        setDisplayName(pendingIntent.displayName);
      }

      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (cancelled) {
        return;
      }

      setSessionChecked(true);

      if (
        session?.user &&
        pendingIntent?.displayName &&
        !autoResumeAttempted.current
      ) {
        autoResumeAttempted.current = true;
        await joinLeague(pendingIntent.displayName);
      }
    }

    void restoreInviteContinuation();

    return () => {
      cancelled = true;
    };
  }, [codice, joinLeague]);

  async function handleJoinLeague(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const normalizedName = displayName.trim();

    if (!normalizedName) {
      return;
    }

    setLoading(true);

    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session?.user) {
      window.localStorage.setItem(
        PENDING_INVITE_INTENT_KEY,
        JSON.stringify({
          inviteCode: codice,
          displayName: normalizedName,
        }),
      );

      window.localStorage.setItem(
        PENDING_AUTH_DESTINATION_KEY,
        inviteDestination,
      );

      const loginHref = `/login?returnTo=${encodeURIComponent(
        inviteDestination,
      )}`;

      window.location.assign(loginHref);
      return;
    }

    await joinLeague(normalizedName);
  }

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-md rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            Invito lega
          </p>

          <h1 className="mb-3 text-3xl font-black">Entra nella lega</h1>

          <p className="mb-6 text-gray-400">
            Hai ricevuto un invito FantaGol. Scegli il nome con cui vuoi apparire
            in questa lega.
          </p>

          <div className="mb-6 rounded-2xl border border-gray-700 bg-black p-4 text-sm text-gray-300">
            Codice invito:{" "}
            <span className="font-bold text-[#A6E824]">{codice}</span>
          </div>

          <form onSubmit={handleJoinLeague} className="space-y-5">
            <div>
              <label className="mb-2 block text-sm font-semibold text-gray-300">
                Il tuo nome in questa lega
              </label>

              <input
                type="text"
                required
                value={displayName}
                onChange={(event) => setDisplayName(event.target.value)}
                placeholder="Es. Cesare"
                disabled={loading}
                className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824] disabled:opacity-60"
              />
            </div>

            <button
              type="submit"
              disabled={loading || !sessionChecked}
              className="w-full rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110 disabled:opacity-60"
            >
              {loading
                ? "Ingresso in corso..."
                : sessionChecked
                  ? "Entra nella lega"
                  : "Verifica accesso..."}
            </button>
          </form>

          <p className="mt-6 text-center text-sm text-gray-500">
            Ogni utente può scegliere un nome diverso per ogni lega.
          </p>
        </div>
      </section>
    </main>
  );
}
