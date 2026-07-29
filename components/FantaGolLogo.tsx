"use client";

/* eslint-disable @next/next/no-img-element -- Static branded asset intentionally preserves the established dimensions and rendering contract. */

import type { MouseEvent, PointerEvent } from "react";

export default function FantaGolLogo() {
  function neutralizeNavigation(
    event:
      | MouseEvent<HTMLImageElement>
      | PointerEvent<HTMLImageElement>,
  ) {
    event.preventDefault();
    event.stopPropagation();
  }

  return (
    <img
      src="/logo/logo-horizontal-v2.png"
      alt="FantaGol"
      draggable={false}
      className="h-48 md:h-60 w-auto"
      onPointerDown={neutralizeNavigation}
      onClick={neutralizeNavigation}
      onAuxClick={neutralizeNavigation}
    />
  );
}
