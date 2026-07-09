type ProgressBarProps = {
  value: number;
  max: number;
};

export default function ProgressBar({ value, max }: ProgressBarProps) {
  const percent = max > 0 ? Math.min(100, Math.round((value / max) * 100)) : 0;

  return (
    <div className="h-3 overflow-hidden rounded-full bg-black">
      <div
        className="h-full rounded-full bg-[#A6E824] transition-all"
        style={{ width: `${percent}%` }}
      />
    </div>
  );
}
