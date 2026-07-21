import Badge from "../../../../../components/ui/Badge";
import DashboardCard from "../../../../../components/ui/DashboardCard";

import type { AdminEvent } from "../types";
import { eventLabel, formatDate } from "../utils";

type Props = {
  events: AdminEvent[];
};

export default function AdminActivityCard({ events }: Props) {
  return (
    <DashboardCard className="mt-6">
      <div className="flex items-center justify-between gap-4">
        <div>
          <p className="text-xs font-black uppercase tracking-[0.2em] text-[#A6E824]">
            Trasparenza
          </p>
          <h2 className="mt-2 text-2xl font-black">
            Attività amministrative
          </h2>
        </div>
        <Badge>{events.length} eventi</Badge>
      </div>

      {events.length === 0 ? (
        <div className="mt-5 rounded-2xl border border-white/10 bg-black/30 p-5 text-sm font-semibold text-gray-500">
          Nessuna attività amministrativa disponibile.
        </div>
      ) : (
        <div className="mt-5 space-y-3">
          {events.map((event) => (
            <article
              key={event.id}
              className="rounded-2xl border border-white/10 bg-black/30 px-4 py-3"
            >
              <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <p className="font-black capitalize text-white">
                    {eventLabel(event.action_type)}
                  </p>
                  <p className="mt-1 text-xs font-semibold text-gray-500">
                    {formatDate(event.created_at)}
                  </p>
                </div>
                <span className="rounded-full border border-white/10 bg-white/[0.03] px-3 py-1 text-xs font-bold text-gray-500">
                  {event.action_type}
                </span>
              </div>

              {(event.actor_display_name ||
                event.target_display_name) && (
                <p className="mt-3 text-xs font-semibold text-gray-500">
                  {event.actor_display_name && (
                    <>Autore: {event.actor_display_name}</>
                  )}
                  {event.actor_display_name &&
                    event.target_display_name &&
                    " · "}
                  {event.target_display_name && (
                    <>Destinatario: {event.target_display_name}</>
                  )}
                </p>
              )}
            </article>
          ))}
        </div>
      )}
    </DashboardCard>
  );
}
