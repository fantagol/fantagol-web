"use client";

import { useState } from "react";
import FantaGolLogo from "./FantaGolLogo";

const fantagolGreen = "#A6E824";

export default function Header() {
  const [open, setOpen] = useState(false);
  const [appOpen, setAppOpen] = useState(false);

  return (
    <header className="sticky top-0 z-50 border-b border-[#A6E824]/25 bg-gradient-to-r from-[#2a2f32] via-[#1f2427] to-[#2a2f32] shadow-2xl shadow-black/80 backdrop-blur">
      <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
        <a
          href="/"
          aria-label="Vai alla home FantaGol"
          className="block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6"
        >
          <FantaGolLogo />
        </a>

        <nav className="hidden items-center gap-3 md:flex md:translate-y-2">
          <div className="relative">
            <button
              type="button"
              onClick={() => setAppOpen(!appOpen)}
              className="rounded-full bg-[#A6E824] px-5 py-2 text-sm font-semibold text-black shadow-lg shadow-[#A6E824]/25 transition hover:brightness-110"
            >
              Scarica App ▾
            </button>

            {appOpen && (
              <div className="absolute right-0 mt-3 w-52 overflow-hidden rounded-2xl border border-gray-700 bg-[#1a1a1a] shadow-xl">
                <a
                  href="/download"
                  className="block px-5 py-3 text-sm text-gray-200 hover:bg-[#262626]"
                >
                  📱 Android
                </a>

                <a
                  href="/download"
                  className="block border-t border-gray-700 px-5 py-3 text-sm text-gray-200 hover:bg-[#262626]"
                >
                  🍎 iPhone
                </a>
              </div>
            )}
          </div>

          <a
            href="/leghe"
            className="rounded-full border border-gray-600 bg-[#2b2f31] px-5 py-2 text-sm font-semibold text-gray-100 transition hover:border-[#A6E824] hover:text-white"
          >
            Leghe
          </a>

          <a
            href="/login"
            className="rounded-full border border-gray-600 bg-[#2b2f31] px-5 py-2 text-sm font-semibold text-gray-100 transition hover:border-[#A6E824] hover:text-white"
          >
            Accedi
          </a>
        </nav>

        <button
          type="button"
          onClick={() => setOpen(!open)}
          aria-label="Apri menu"
          className="rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white md:hidden"
        >
          ☰
        </button>
      </div>

      {open && (
        <nav className="border-t border-gray-700 bg-[#1a1d1f] px-6 py-6 text-gray-300 md:hidden">
          <div className="space-y-5 text-lg">
            <a onClick={() => setOpen(false)} className="block" href="/play">
              Gioca Online
            </a>

            <a onClick={() => setOpen(false)} className="block" href="/leghe">
              Le mie Leghe
            </a>

            <a onClick={() => setOpen(false)} className="block" href="/crea-lega">
              Crea Lega
            </a>

            <div className="space-y-2">
              <div style={{ color: fantagolGreen }} className="font-semibold">
                Scarica App
              </div>

              <a onClick={() => setOpen(false)} className="block pl-4 text-base" href="/download">
                📱 Android
              </a>

              <a onClick={() => setOpen(false)} className="block pl-4 text-base" href="/download">
                🍎 iPhone
              </a>
            </div>

            <a onClick={() => setOpen(false)} className="block" href="/login">
              Accedi
            </a>

            <a onClick={() => setOpen(false)} className="block" href="/regolamento">
              Come si Gioca
            </a>
          </div>
        </nav>
      )}
    </header>
  );
}