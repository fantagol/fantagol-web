"use client";

/* eslint-disable @next/next/no-img-element -- Dynamic external assets intentionally preserve the current crop, fallback, and sizing contracts. */
import { useMemo, useState } from "react";

type TeamCrestSize = "xs" | "sm" | "md" | "lg" | "xl";

type TeamCrestProps = {
  crestReference?: string | null;
  logoUrl?: string | null;
  alt: string;
  fallbackLabel: string;
  size?: TeamCrestSize;
  className?: string;
};

const sizeClasses: Record<TeamCrestSize, string> = {
  xs: "h-5 w-5",
  sm: "h-7 w-7",
  md: "h-9 w-9",
  lg: "h-11 w-11",
  xl: "h-14 w-14",
};

const fallbackTextClasses: Record<TeamCrestSize, string> = {
  xs: "text-[6px]",
  sm: "text-[7px]",
  md: "text-[9px]",
  lg: "text-[10px]",
  xl: "text-xs",
};

function initials(label: string) {
  return label
    .split(/\s+/)
    .filter(Boolean)
    .map((part) => part[0])
    .join("")
    .slice(0, 3)
    .toUpperCase();
}

export default function TeamCrest({
  crestReference,
  logoUrl,
  alt,
  fallbackLabel,
  size = "md",
  className = "",
}: TeamCrestProps) {
  const sources = useMemo(
    () => [crestReference, logoUrl].filter((value): value is string => Boolean(value)),
    [crestReference, logoUrl]
  );
  const [sourceIndex, setSourceIndex] = useState(0);
  const currentSource = sources[sourceIndex] ?? null;

  return (
    <span
      className={`${sizeClasses[size]} ${className} flex shrink-0 items-center justify-center overflow-hidden rounded-full border border-white/10 bg-[#11181d] shadow-[0_2px_8px_rgba(0,0,0,0.28)]`}
    >
      {currentSource ? (
        <img
          src={currentSource}
          alt={alt}
          loading="lazy"
          decoding="async"
          onError={() => setSourceIndex((current) => current + 1)}
          className="h-full w-full object-contain p-[10%] drop-shadow-[0_0_2px_rgba(255,255,255,0.95)]"
        />
      ) : (
        <span
          className={`${fallbackTextClasses[size]} font-black tracking-tight text-white`}
          title={fallbackLabel}
        >
          {initials(fallbackLabel)}
        </span>
      )}
    </span>
  );
}
