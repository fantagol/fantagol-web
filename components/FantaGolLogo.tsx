/* eslint-disable @next/next/no-img-element -- Dynamic external assets intentionally preserve the current crop, fallback, and sizing contracts. */
export default function FantaGolLogo() {
  return (
    <img
      src="/logo/logo-horizontal-v2.png"
      alt="FantaGol"
      className="h-48 md:h-60 w-auto"
    />
  );
}
