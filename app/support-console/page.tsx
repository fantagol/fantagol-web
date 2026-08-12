"use client";

import { useCallback, useEffect, useState } from "react";

import { supabase } from "../../lib/supabaseClient";

type SupportStatus =
  | "new"
  | "in_progress"
  | "resolved"
  | "closed";

type SupportTicket = {
  id: string;
  user_id: string;
  league_id: string | null;
  category: string;
  subject: string;
  description: string;
  screenshot_path: string | null;
  screenshot_url: string | null;
  source_page: string | null;
  user_agent: string | null;
  locale: string | null;
  status: SupportStatus;
  created_at: string;
  updated_at: string;
  handled_by: string | null;
  handled_at: string | null;
  resolved_at: string | null;
  closed_at: string | null;
};

const STATUS_OPTIONS: Array<{
  value: SupportStatus | "all";
  label: string;
}> = [
  { value: "all", label: "Tutti" },
  { value: "new", label: "Nuovi" },
  { value: "in_progress", label: "In lavorazione" },
  { value: "resolved", label: "Risolti" },
  { value: "closed", label: "Chiusi" },
];

function formatDate(value: string | null) {
  if (!value) return "—";

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) return "—";

  return new Intl.DateTimeFormat("it-IT", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function statusLabel(status: SupportStatus) {
  switch (status) {
    case "new":
      return "Nuovo";
    case "in_progress":
      return "In lavorazione";
    case "resolved":
      return "Risolto";
    case "closed":
      return "Chiuso";
  }
}

function nextActions(status: SupportStatus) {
  switch (status) {
    case "new":
      return [{ status: "in_progress" as const, label: "Prendi in carico" }];
    case "in_progress":
      return [{ status: "resolved" as const, label: "Segna risolto" }];
    case "resolved":
      return [
        { status: "in_progress" as const, label: "Riapri" },
        { status: "closed" as const, label: "Chiudi" },
      ];
    case "closed":
      return [];
  }
}

export default function SupportConsolePage() {
  const [tickets, setTickets] = useState<SupportTicket[]>([]);
  const [filter, setFilter] = useState<SupportStatus | "all">("all");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [savingId, setSavingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const selectedTicket =
    tickets.find((ticket) => ticket.id === selectedId) || null;

  const loadTickets = useCallback(async () => {
    setLoading(true);
    setError(null);

    try {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.access_token) {
        throw new Error("Sessione non disponibile.");
      }

      const search = new URLSearchParams();

      if (filter !== "all") {
        search.set("status", filter);
      }

      const response = await fetch(
        `/api/support-console/tickets${
          search.size > 0 ? `?${search.toString()}` : ""
        }`,
        {
          headers: {
            Authorization: `Bearer ${session.access_token}`,
          },
          cache: "no-store",
        },
      );

      const payload = (await response.json()) as {
        tickets?: SupportTicket[];
        error?: string;
      };

      if (!response.ok) {
        throw new Error(payload.error || "Impossibile leggere i ticket.");
      }

      const nextTickets = payload.tickets || [];

      setTickets(nextTickets);

      setSelectedId((current) => {
        if (
          current &&
          nextTickets.some((ticket) => ticket.id === current)
        ) {
          return current;
        }

        return nextTickets[0]?.id || null;
      });
    } catch (cause) {
      setTickets([]);
      setSelectedId(null);
      setError(
        cause instanceof Error
          ? cause.message
          : "Support Console non disponibile.",
      );
    } finally {
      setLoading(false);
    }
  }, [filter]);

  useEffect(() => {
    void loadTickets();
  }, [loadTickets]);

  async function changeStatus(
    requestId: string,
    status: SupportStatus,
  ) {
    setSavingId(requestId);
    setError(null);

    try {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.access_token) {
        throw new Error("Sessione non disponibile.");
      }

      const response = await fetch("/api/support-console/tickets", {
        method: "PATCH",
        headers: {
          Authorization: `Bearer ${session.access_token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          requestId,
          status,
        }),
      });

      const payload = (await response.json()) as {
        error?: string;
      };

      if (!response.ok) {
        throw new Error(payload.error || "Aggiornamento non riuscito.");
      }

      await loadTickets();
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : "Aggiornamento non riuscito.",
      );
    } finally {
      setSavingId(null);
    }
  }

  return (
    <main className="mx-auto min-h-screen w-full max-w-7xl px-4 py-6 sm:px-6 lg:px-8">
      <section className="space-y-6">
        <header className="space-y-2">
          <p className="text-xs font-black uppercase tracking-[0.18em] text-[#A6E824]">
            Support Console
          </p>

          <h1 className="text-2xl font-black sm:text-3xl">
            Gestione Supporto
          </h1>

          <p className="max-w-2xl text-sm text-white/60">
            Richieste inviate dagli utenti tramite la sezione Supporto.
          </p>
        </header>

        <div className="flex flex-wrap gap-2">
          {STATUS_OPTIONS.map((option) => {
            const active = filter === option.value;

            return (
              <button
                key={option.value}
                type="button"
                onClick={() => setFilter(option.value)}
                className={[
                  "rounded-xl border px-3 py-2 text-xs font-black transition",
                  active
                    ? "border-[#A6E824]/60 bg-[#A6E824]/15 text-[#A6E824]"
                    : "border-white/10 bg-white/[0.03] text-white/60 hover:border-white/20 hover:text-white",
                ].join(" ")}
              >
                {option.label}
              </button>
            );
          })}
        </div>

        {error ? (
          <div className="rounded-2xl border border-red-400/25 bg-red-500/10 px-4 py-3 text-sm text-red-100">
            {error}
          </div>
        ) : null}

        <div className="grid gap-4 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.4fr)]">
          <section className="overflow-hidden rounded-3xl border border-white/10 bg-white/[0.03]">
            <div className="border-b border-white/10 px-4 py-3">
              <p className="text-sm font-black">
                Ticket
              </p>
            </div>

            {loading ? (
              <div className="px-4 py-8 text-sm text-white/50">
                Caricamento…
              </div>
            ) : tickets.length === 0 ? (
              <div className="px-4 py-8 text-sm text-white/50">
                Nessun ticket in questa sezione.
              </div>
            ) : (
              <div className="divide-y divide-white/10">
                {tickets.map((ticket) => {
                  const active = ticket.id === selectedId;

                  return (
                    <button
                      key={ticket.id}
                      type="button"
                      onClick={() => setSelectedId(ticket.id)}
                      className={[
                        "w-full px-4 py-4 text-left transition",
                        active
                          ? "bg-white/[0.07]"
                          : "hover:bg-white/[0.04]",
                      ].join(" ")}
                    >
                      <div className="flex items-start justify-between gap-3">
                        <div className="min-w-0">
                          <p className="truncate text-sm font-black">
                            {ticket.subject}
                          </p>
                          <p className="mt-1 text-xs text-white/50">
                            {ticket.category} · {formatDate(ticket.created_at)}
                          </p>
                        </div>

                        <span className="shrink-0 rounded-lg border border-white/10 px-2 py-1 text-[10px] font-black uppercase tracking-wide text-white/60">
                          {statusLabel(ticket.status)}
                        </span>
                      </div>
                    </button>
                  );
                })}
              </div>
            )}
          </section>

          <section className="rounded-3xl border border-white/10 bg-white/[0.03] p-4 sm:p-5">
            {!selectedTicket ? (
              <div className="py-12 text-center text-sm text-white/50">
                Seleziona un ticket.
              </div>
            ) : (
              <div className="space-y-5">
                <div>
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <p className="text-xs font-black uppercase tracking-[0.16em] text-white/40">
                        {selectedTicket.category}
                      </p>
                      <h2 className="mt-1 text-xl font-black">
                        {selectedTicket.subject}
                      </h2>
                    </div>

                    <span className="rounded-xl border border-[#A6E824]/25 bg-[#A6E824]/10 px-3 py-2 text-xs font-black text-[#A6E824]">
                      {statusLabel(selectedTicket.status)}
                    </span>
                  </div>

                  <p className="mt-2 text-xs text-white/40">
                    {selectedTicket.id}
                  </p>
                </div>

                <div className="rounded-2xl border border-white/10 bg-black/20 p-4">
                  <p className="whitespace-pre-wrap text-sm leading-6 text-white/85">
                    {selectedTicket.description}
                  </p>
                </div>

                {selectedTicket.screenshot_url ? (
                  <div className="space-y-2">
                    <p className="text-xs font-black uppercase tracking-[0.16em] text-white/40">
                      Screenshot
                    </p>
                    <a
                      href={selectedTicket.screenshot_url}
                      target="_blank"
                      rel="noreferrer"
                      className="block overflow-hidden rounded-2xl border border-white/10 bg-black/30"
                    >
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img
                        src={selectedTicket.screenshot_url}
                        alt="Screenshot allegato al ticket"
                        className="max-h-[520px] w-full object-contain"
                      />
                    </a>
                    <p className="text-[11px] text-white/35">
                      Accesso temporaneo firmato.
                    </p>
                  </div>
                ) : null}

                <dl className="grid gap-3 text-sm sm:grid-cols-2">
                  <div className="rounded-2xl border border-white/10 p-3">
                    <dt className="text-xs text-white/40">Utente</dt>
                    <dd className="mt-1 break-all font-bold">
                      {selectedTicket.user_id}
                    </dd>
                  </div>

                  <div className="rounded-2xl border border-white/10 p-3">
                    <dt className="text-xs text-white/40">Lega</dt>
                    <dd className="mt-1 break-all font-bold">
                      {selectedTicket.league_id || "—"}
                    </dd>
                  </div>

                  <div className="rounded-2xl border border-white/10 p-3">
                    <dt className="text-xs text-white/40">Pagina origine</dt>
                    <dd className="mt-1 break-all font-bold">
                      {selectedTicket.source_page || "—"}
                    </dd>
                  </div>

                  <div className="rounded-2xl border border-white/10 p-3">
                    <dt className="text-xs text-white/40">Creato</dt>
                    <dd className="mt-1 font-bold">
                      {formatDate(selectedTicket.created_at)}
                    </dd>
                  </div>

                  <div className="rounded-2xl border border-white/10 p-3">
                    <dt className="text-xs text-white/40">Preso in carico</dt>
                    <dd className="mt-1 font-bold">
                      {formatDate(selectedTicket.handled_at)}
                    </dd>
                  </div>

                  <div className="rounded-2xl border border-white/10 p-3">
                    <dt className="text-xs text-white/40">Risolto</dt>
                    <dd className="mt-1 font-bold">
                      {formatDate(selectedTicket.resolved_at)}
                    </dd>
                  </div>
                </dl>

                {nextActions(selectedTicket.status).length > 0 ? (
                  <div className="flex flex-wrap gap-2 border-t border-white/10 pt-4">
                    {nextActions(selectedTicket.status).map((action) => (
                      <button
                        key={action.status}
                        type="button"
                        disabled={savingId === selectedTicket.id}
                        onClick={() =>
                          void changeStatus(
                            selectedTicket.id,
                            action.status,
                          )
                        }
                        className="rounded-xl bg-[#A6E824] px-4 py-2.5 text-sm font-black text-black disabled:cursor-not-allowed disabled:opacity-50"
                      >
                        {savingId === selectedTicket.id
                          ? "Aggiornamento…"
                          : action.label}
                      </button>
                    ))}
                  </div>
                ) : null}
              </div>
            )}
          </section>
        </div>
      </section>
    </main>
  );
}