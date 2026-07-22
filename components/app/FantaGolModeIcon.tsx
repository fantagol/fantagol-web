import type { SVGProps } from "react";

export type FantaGolMode = "punti-puri" | "fantacalcio" | "one-to-one";

type FantaGolModeIconProps = {
  mode: FantaGolMode;
  className?: string;
  decorative?: boolean;
};

const sharedSvgProps: SVGProps<SVGSVGElement> = {
  viewBox: "0 0 32 32",
  fill: "none",
  xmlns: "http://www.w3.org/2000/svg",
};

function PurePointsIcon() {
  return (
    <svg {...sharedSvgProps} aria-hidden="true">
      <path
        d="M16 3.75 19.35 11l7.9.76-5.96 5.23 1.73 7.76L16 20.72l-7.02 4.03 1.73-7.76-5.96-5.23 7.9-.76L16 3.75Z"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinejoin="round"
      />
      <path
        d="m16 9.2 1.68 3.64 3.97.38-3 2.63.87 3.9L16 17.73l-3.52 2.02.87-3.9-3-2.63 3.97-.38L16 9.2Z"
        fill="currentColor"
        opacity="0.32"
      />
      <circle cx="16" cy="15.5" r="2.25" fill="currentColor" />
    </svg>
  );
}

function FantacalcioIcon() {
  return (
    <svg {...sharedSvgProps} aria-hidden="true">
      <rect
        x="4.25"
        y="6.25"
        width="23.5"
        height="19.5"
        rx="3"
        stroke="currentColor"
        strokeWidth="1.8"
      />
      <path d="M16 6.25v19.5" stroke="currentColor" strokeWidth="1.5" opacity="0.72" />
      <circle cx="16" cy="16" r="3.35" stroke="currentColor" strokeWidth="1.5" />
      <path
        d="M4.25 11.25h3.6c1.1 0 2 .9 2 2v5.5c0 1.1-.9 2-2 2h-3.6M27.75 11.25h-3.6c-1.1 0-2 .9-2 2v5.5c0 1.1.9 2 2 2h3.6"
        stroke="currentColor"
        strokeWidth="1.5"
      />
      <circle cx="16" cy="16" r="1.25" fill="currentColor" />
    </svg>
  );
}

function OneToOneIcon() {
  return (
    <svg {...sharedSvgProps} aria-hidden="true">
      {/* Spada da sinistra in basso verso destra in alto */}
      <path
        d="M8.15 23.85 22.6 9.4"
        stroke="currentColor"
        strokeWidth="2.4"
        strokeLinecap="round"
      />
      <path
        d="m22.6 9.4 3.25-3.25-.95 4.25-2.3-1Z"
        fill="currentColor"
        stroke="currentColor"
        strokeWidth="0.85"
        strokeLinejoin="round"
      />
      <path
        d="m6.75 20.95 4.3 4.3"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <path
        d="M6.4 25.6 9.05 22.95"
        stroke="currentColor"
        strokeWidth="2.8"
        strokeLinecap="round"
      />

      {/* Spada da destra in basso verso sinistra in alto */}
      <path
        d="M23.85 23.85 9.4 9.4"
        stroke="currentColor"
        strokeWidth="2.4"
        strokeLinecap="round"
      />
      <path
        d="M9.4 9.4 6.15 6.15l.95 4.25 2.3-1Z"
        fill="currentColor"
        stroke="currentColor"
        strokeWidth="0.85"
        strokeLinejoin="round"
      />
      <path
        d="m25.25 20.95-4.3 4.3"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <path
        d="m25.6 25.6-2.65-2.65"
        stroke="currentColor"
        strokeWidth="2.8"
        strokeLinecap="round"
      />

    </svg>
  );
}

export default function FantaGolModeIcon({
  mode,
  className = "h-7 w-7",
  decorative = true,
}: FantaGolModeIconProps) {
  const label =
    mode === "punti-puri"
      ? "Punti Puri"
      : mode === "fantacalcio"
        ? "Fantacalcio"
        : "One To One";

  return (
    <span
      className={`relative inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-xl border border-[#A6E824]/35 bg-[#071015] text-[#A6E824] shadow-[0_0_16px_rgba(166,232,36,0.14)] ${className}`}
      aria-hidden={decorative ? true : undefined}
      role={decorative ? undefined : "img"}
      aria-label={decorative ? undefined : label}
    >
      <span className="absolute inset-1 rounded-lg bg-[#A6E824]/[0.04]" />
      <span className="relative h-7 w-7">
        {mode === "punti-puri" ? <PurePointsIcon /> : null}
        {mode === "fantacalcio" ? <FantacalcioIcon /> : null}
        {mode === "one-to-one" ? <OneToOneIcon /> : null}
      </span>
    </span>
  );
}
