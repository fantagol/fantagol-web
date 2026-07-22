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

  const isJuventus = useMemo(() => {
    const searchableValue = [
      alt,
      fallbackLabel,
      crestReference,
      logoUrl,
      currentSource,
    ]
      .filter((value): value is string => Boolean(value))
      .join(" ")
      .toLowerCase();

    return (
      searchableValue.includes("juventus") ||
      searchableValue.includes("/juve") ||
      searchableValue.includes("juve.")
    );
  }, [alt, fallbackLabel, crestReference, logoUrl, currentSource]);

  const isLazio = useMemo(() => {
    const searchableValue = [alt, fallbackLabel, crestReference, logoUrl, currentSource]
      .filter((value): value is string => Boolean(value))
      .join(" ")
      .toLowerCase();
    return searchableValue.includes("lazio");
  }, [alt, fallbackLabel, crestReference, logoUrl, currentSource]);

  const isNapoli = useMemo(() => {
    const searchableValue = [alt, fallbackLabel, crestReference, logoUrl, currentSource]
      .filter((value): value is string => Boolean(value))
      .join(" ")
      .toLowerCase();
    return searchableValue.includes("napoli");
  }, [alt, fallbackLabel, crestReference, logoUrl, currentSource]);

  return (
    <span
      className={`${sizeClasses[size]} ${className} flex shrink-0 items-center justify-center`}
    >
      {currentSource ? (
        <img
          src={currentSource}
          alt={alt}
          loading="lazy"
          decoding="async"
          onError={() => setSourceIndex((current) => current + 1)}
          className={`h-full w-full object-contain ${
            isJuventus
              ? "brightness-0 invert drop-shadow-[0_0_1px_rgba(255,255,255,0.75)] drop-shadow-[0_0_4px_rgba(255,255,255,0.28)]"
              : isLazio || isNapoli
                ? "scale-[1.25]"
                : ""
          }`}
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
