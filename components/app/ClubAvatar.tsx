"use client";

/* eslint-disable @next/next/no-img-element -- User-generated avatars require the certified crop and fallback behavior. */

type ClubAvatarProps = {
  src?: string | null;
  alt: string;
  fallbackLabel: string;
  title?: string;
  zoom?: number | null;
  x?: number | null;
  y?: number | null;
  className?: string;
  imageClassName?: string;
};

function clamp(value: number, minimum: number, maximum: number) {
  return Math.min(maximum, Math.max(minimum, value));
}

function initials(label: string) {
  const cleanLabel = label.trim();

  if (!cleanLabel) {
    return "F";
  }

  return cleanLabel
    .split(/\s+/)
    .filter(Boolean)
    .map((part) => part[0])
    .join("")
    .slice(0, 2)
    .toUpperCase();
}

export default function ClubAvatar({
  src,
  alt,
  fallbackLabel,
  title,
  zoom = 1,
  x = 0,
  y = 0,
  className = "",
  imageClassName = "",
}: ClubAvatarProps) {
  const safeZoom = clamp(Number(zoom) || 1, 0.5, 4);
  const safeX = clamp(Number(x) || 0, -100, 100);
  const safeY = clamp(Number(y) || 0, -100, 100);

  return (
    <div
      title={title}
      className={`relative flex items-center justify-center overflow-hidden rounded-full ${className}`}
      style={{
        backgroundColor: "#000000",
        backgroundImage: "none",
      }}
    >
      {src ? (
        <img
          src={src}
          alt={alt}
          draggable={false}
          className={`absolute inset-0 h-full w-full select-none object-cover ${imageClassName}`}
          style={{
            transform:
              `translate(${safeX}%, ${safeY}%) ` +
              `scale(${safeZoom})`,
            transformOrigin: "center",
          }}
        />
      ) : (
        <span className="font-black text-[#A6E824]">
          {initials(fallbackLabel)}
        </span>
      )}
    </div>
  );
}
