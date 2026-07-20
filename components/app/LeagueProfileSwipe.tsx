"use client";

/* eslint-disable @next/next/no-img-element -- Dynamic external assets intentionally preserve the current crop, fallback, and sizing contracts. */
import { useMemo, useRef, useState, type PointerEvent, type TouchEvent } from "react";
import KitPreview from "../club/KitPreview";

export type LeagueSwipeMode = "punti_puri" | "fantacalcio" | "one_to_one";

export type SwipeClubProfile = {
  id: string;
  clubName: string;
  avatarUrl: string | null;
  kitTemplate: string;
  kitPrimaryColor: string;
  kitSecondaryColor: string;
  kitThirdColor: string;
  kitLogoMode: string;
  kitCrestPosition: string;
  starsCount: number;
  isCurrentUser?: boolean;
};

type LeagueProfileSwipeProps = {
  mode: LeagueSwipeMode;
  profiles?: SwipeClubProfile[];
  activeIndex?: number;
  isLive: boolean;
  onChange?: (profile: SwipeClubProfile, index: number) => void;
};

const demoProfiles: SwipeClubProfile[] = [
  {
    id: "me",
    clubName: "Il Mio Club",
    avatarUrl: null,
    kitTemplate: "solid",
    kitPrimaryColor: "#FFFFFF",
    kitSecondaryColor: "#111417",
    kitThirdColor: "#A6E824",
    kitLogoMode: "center_horizontal",
    kitCrestPosition: "left_chest",
    starsCount: 0,
    isCurrentUser: true,
  },
  {
    id: "demo-1",
    clubName: "Real Exact",
    avatarUrl: null,
    kitTemplate: "vertical_3",
    kitPrimaryColor: "#A6E824",
    kitSecondaryColor: "#111417",
    kitThirdColor: "#FFFFFF",
    kitLogoMode: "center_horizontal",
    kitCrestPosition: "left_chest",
    starsCount: 2,
  },
  {
    id: "demo-2",
    clubName: "Bonus Show",
    avatarUrl: null,
    kitTemplate: "diagonal",
    kitPrimaryColor: "#1f2427",
    kitSecondaryColor: "#A6E824",
    kitThirdColor: "#FFFFFF",
    kitLogoMode: "wordmark_only",
    kitCrestPosition: "left_chest",
    starsCount: 1,
  },
];

function modeLabel(mode: LeagueSwipeMode) {
  if (mode === "fantacalcio") return "Fantacalcio";
  if (mode === "one_to_one") return "One To One";
  return "Punti Puri";
}

function AvatarMini({ profile }: { profile: SwipeClubProfile }) {
  return (
    <div className="flex h-11 w-11 shrink-0 items-center justify-center overflow-hidden rounded-full border border-[#A6E824]/50 bg-black text-base font-black text-[#A6E824]">
      {profile.avatarUrl ? (
        <img src={profile.avatarUrl} alt={profile.clubName} className="h-full w-full object-cover" />
      ) : (
        profile.clubName.slice(0, 1).toUpperCase()
      )}
    </div>
  );
}

function KitMini({ profile }: { profile: SwipeClubProfile }) {
  return (
    <div className="flex h-16 w-11 shrink-0 items-center justify-center overflow-hidden rounded-xl bg-[#111417]">
      <div className="scale-[0.3]">
        <KitPreview
          primary={profile.kitPrimaryColor}
          secondary={profile.kitSecondaryColor}
          third={profile.kitThirdColor}
          template={profile.kitTemplate}
          logoMode={profile.kitLogoMode}
          crestPosition={profile.kitCrestPosition}
          starsCount={profile.starsCount}
        />
      </div>
    </div>
  );
}

export default function LeagueProfileSwipe({
  mode,
  profiles,
  activeIndex = 0,
  isLive,
  onChange,
}: LeagueProfileSwipeProps) {
  const list = useMemo(() => (profiles && profiles.length > 0 ? profiles : demoProfiles), [profiles]);
  const safeInitialIndex = Math.min(Math.max(activeIndex, 0), Math.max(0, list.length - 1));
  const [index, setIndex] = useState(safeInitialIndex);
  const touchStartX = useRef<number | null>(null);
  const pointerStartX = useRef<number | null>(null);

  const activeProfile = list[index];
  const isFirst = index === 0;
  const isLast = index === list.length - 1;

  function goTo(nextIndex: number) {
    const bounded = Math.min(Math.max(nextIndex, 0), list.length - 1);
    setIndex(bounded);
    onChange?.(list[bounded], bounded);
  }

  function goPrev() {
    if (!isFirst) goTo(index - 1);
  }

  function goNext() {
    if (!isLast) goTo(index + 1);
  }

  function resolveSwipe(deltaX: number) {
    if (Math.abs(deltaX) < 45) return;
    if (deltaX < 0) goNext();
    if (deltaX > 0) goPrev();
  }

  function handleTouchStart(event: TouchEvent<HTMLDivElement>) {
    touchStartX.current = event.touches[0]?.clientX ?? null;
  }

  function handleTouchEnd(event: TouchEvent<HTMLDivElement>) {
    if (touchStartX.current === null) return;
    const endX = event.changedTouches[0]?.clientX ?? touchStartX.current;
    resolveSwipe(endX - touchStartX.current);
    touchStartX.current = null;
  }

  function handlePointerDown(event: PointerEvent<HTMLDivElement>) {
    if (event.pointerType === "touch") return;
    pointerStartX.current = event.clientX;
  }

  function handlePointerUp(event: PointerEvent<HTMLDivElement>) {
    if (pointerStartX.current === null) return;
    resolveSwipe(event.clientX - pointerStartX.current);
    pointerStartX.current = null;
  }

  return (
    <>
      {!isFirst && (
        <button
          type="button"
          onClick={goPrev}
          className="fixed left-3 top-1/2 z-[70] hidden h-14 w-12 -translate-y-1/2 items-center justify-center rounded-2xl border border-[#A6E824]/35 bg-black/60 text-4xl font-black text-[#A6E824] shadow-2xl shadow-black/70 backdrop-blur transition hover:border-[#A6E824] hover:bg-[#A6E824]/10 md:flex"
          aria-label="Profilo precedente"
        >
          ‹
        </button>
      )}

      {!isLast && (
        <button
          type="button"
          onClick={goNext}
          className="fixed right-3 top-1/2 z-[70] hidden h-14 w-12 -translate-y-1/2 items-center justify-center rounded-2xl border border-[#A6E824]/35 bg-black/60 text-4xl font-black text-[#A6E824] shadow-2xl shadow-black/70 backdrop-blur transition hover:border-[#A6E824] hover:bg-[#A6E824]/10 md:flex"
          aria-label="Profilo successivo"
        >
          ›
        </button>
      )}

      <section
        className="mt-3 overflow-hidden rounded-2xl border border-white/10 bg-[#0b1419] shadow-xl shadow-black/30 sm:mt-4"
        onTouchStart={handleTouchStart}
        onTouchEnd={handleTouchEnd}
        onPointerDown={handlePointerDown}
        onPointerUp={handlePointerUp}
      >
        <div className="min-w-0 rounded-2xl bg-black/10 p-3 sm:p-4">
          <div className="flex min-w-0 items-center justify-between gap-3">
            <div className="flex min-w-0 items-center gap-3">
              <AvatarMini profile={activeProfile} />

              <div className="min-w-0">
                <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
                  {activeProfile.isCurrentUser ? "Tu" : "Membro lega"} · {modeLabel(mode)}
                </p>
                <p className="mt-1 truncate text-base font-black text-white sm:text-lg">
                  {activeProfile.clubName}
                </p>
              </div>
            </div>

            <KitMini profile={activeProfile} />
          </div>

          <div className="mt-3 flex items-center justify-between gap-3">
            <div className="flex gap-1">
              {list.map((profile, itemIndex) => (
                <button
                  key={profile.id}
                  type="button"
                  onClick={() => goTo(itemIndex)}
                  className={`h-2 rounded-full transition ${itemIndex === index ? "w-6 bg-[#A6E824]" : "w-2 bg-white/20"}`}
                  aria-label={`Vai al profilo ${itemIndex + 1}`}
                />
              ))}
            </div>

            <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
              {index + 1}/{list.length}
            </p>
          </div>

          {!activeProfile.isCurrentUser && !isLive && (
            <div className="mt-3 rounded-xl border border-dashed border-white/10 bg-black/25 px-3 py-2 text-center text-[11px] font-bold text-gray-500">
              I pronostici degli altri membri saranno visibili dall&apos;inizio della fase live.
            </div>
          )}
        </div>
      </section>
    </>
  );
}

