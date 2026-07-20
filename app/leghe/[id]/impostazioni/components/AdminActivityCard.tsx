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
              className="flex flex-col gap-2 rounded-2xl border border-white/10 bg-black/30 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <div>
                <p className="font-black capitalize text-white">
                  {eventLabel(event.action_type)}
                </p>
                <p className="mt-1 text-xs font-semibold text-gray-500">
                  {formatDate(event.created_at)}
                </p>
              </div>

              <span className="max-w-full truncate rounded-full border border-white/10 bg-white/[0.03] px-3 py-1 text-xs font-bold text-gray-500">
                {event.action_type}
              </span>
            </article>
          ))}
        </div>
      )}
    </DashboardCard>
  );
}
