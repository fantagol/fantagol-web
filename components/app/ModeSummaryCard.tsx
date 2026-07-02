import DashboardCard from "../ui/DashboardCard";

type ModeSummaryCardProps = {
  icon: string;
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
    <DashboardCard className="p-5">
      <div className="text-2xl">{icon}</div>
      <div className="mt-2 text-sm text-gray-400">{title}</div>
      <div className="mt-2 text-3xl font-black text-[#A6E824]">
        {value}
      </div>
      <div className="mt-1 text-sm text-gray-500">{description}</div>
    </DashboardCard>
  );
}