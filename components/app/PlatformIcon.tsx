"use client";

import type { SVGProps } from "react";

type Platform = "android" | "iphone";

type Props = SVGProps<SVGSVGElement> & {
  platform: Platform;
  size?: number;
};

export default function PlatformIcon({
  platform,
  size = 20,
  className,
  ...props
}: Props) {
  if (platform === "android") {
    return (
      <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
        strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"
        className={className} {...props}>
        <path d="M8 7 6.5 4.8M16 7l1.5-2.2"/>
        <path d="M7 10a5 5 0 0 1 10 0v6a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2z"/>
        <circle cx="10" cy="10" r=".6" fill="currentColor" stroke="none"/>
        <circle cx="14" cy="10" r=".6" fill="currentColor" stroke="none"/>
      </svg>
    );
  }

  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none"
      stroke="currentColor" strokeWidth="2.2"
      strokeLinecap="round" strokeLinejoin="round"
      className={className} {...props}>
      <path d="M12 5c2-2 4-1.8 4.8-.7"/>
      <path d="M12 7c-3.7 0-6 2.5-6 5.8C6 16.7 8.6 19 12 19s6-2.3 6-6.2C18 9.5 15.7 7 12 7Z"/>
      <path d="M12.2 4.6c-.3-1 .2-2 .9-2.6"/>
    </svg>
  );
}
