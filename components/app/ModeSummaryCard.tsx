import type { ReactNode } from "react";

import DashboardCard from "../ui/DashboardCard";

type ModeSummaryCardProps = {
  icon: ReactNode;
  title: string;
  value: string;
  description: string;
};

export default function ModeSummaryCard({
  icon,
  title,
  value,
  description,
}: ModeSummaryCardProps) {
  return (
    <DashboardCard className="h-full p-5">
      <div className="flex items-start justify-between gap-4">
        <div>{icon}</div>
        <div className="rounded-full border border-white/10 bg-black/25 px-2 py-1 text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
          Modalità
        </div>
      </div>

      <div className="mt-3 text-sm font-bold text-gray-400">{title}</div>
      <div className="mt-2 text-3xl font-black text-[#A6E824]">{value}</div>
      <div className="mt-1 text-sm text-gray-500">{description}</div>
    </DashboardCard>
  );
}
