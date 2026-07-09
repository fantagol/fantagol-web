type DashboardCardProps = {
  children: React.ReactNode;
  className?: string;
};

export default function DashboardCard({
  children,
  className = "",
}: DashboardCardProps) {
  return (
    <div
      className={`rounded-[2rem] border border-gray-700 bg-[#111417] p-6 shadow-xl shadow-black/40 ${className}`}
    >
      {children}
    </div>
  );
}
