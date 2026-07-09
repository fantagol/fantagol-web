type QuickActionCardProps = {
  icon: string;
  label: string;
  href: string;
};

export default function QuickActionCard({
  icon,
  label,
  href,
}: QuickActionCardProps) {
  return (
    <a
      href={href}
      className="rounded-3xl border border-gray-700 bg-[#111417] p-5 text-center transition hover:border-[#A6E824]"
    >
      <div className="text-2xl">{icon}</div>
      <div className="mt-2 text-sm font-semibold text-white">{label}</div>
    </a>
  );
}
