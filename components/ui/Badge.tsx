type BadgeProps = {
  children: React.ReactNode;
  variant?: "default" | "live" | "success" | "warning" | "danger";
};

export default function Badge({ children, variant = "default" }: BadgeProps) {
  const styles = {
    default: "border-gray-700 bg-gray-800 text-gray-300",
    live: "border-red-500/40 bg-red-500/10 text-red-400",
    success: "border-[#A6E824]/40 bg-[#A6E824]/10 text-[#A6E824]",
    warning: "border-yellow-500/40 bg-yellow-500/10 text-yellow-300",
    danger: "border-red-500/40 bg-red-950/40 text-red-400",
  };

  return (
    <span
      className={`inline-flex rounded-full border px-3 py-1 text-xs font-bold ${styles[variant]}`}
    >
      {children}
    </span>
  );
}