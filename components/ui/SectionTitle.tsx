type SectionTitleProps = {
  eyebrow?: string;
  title: string;
  subtitle?: string;
};

export default function SectionTitle({
  eyebrow,
  title,
  subtitle,
}: SectionTitleProps) {
  return (
    <div>
      {eyebrow && (
        <p className="mb-2 text-xs font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
          {eyebrow}
        </p>
      )}

      <h2 className="text-2xl font-black text-white">{title}</h2>

      {subtitle && <p className="mt-2 text-sm text-gray-400">{subtitle}</p>}
    </div>
  );
}
