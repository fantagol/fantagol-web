"use client";

import { useState } from "react";
import FantaGolLogo from "./FantaGolLogo";

export default function Header() {
  const [open, setOpen] = useState(false);
  const [appOpen, setAppOpen] = useState(false);

  return (
    <header className="sticky top-0 z-50 border-b border-gray-700/70 bg-gradient-to-r from-gray-950 via-black to-gray-950 shadow-lg shadow-black/40 backdrop-blur">
      <div className="mx-auto flex h-18 max-w-6xl items-center justify-between px-4 md:px-6">
        <a
          href="/"
          aria-label="Vai alla home FantaGol"
          className="block -translate-x-4 translate-y-6 md:-translate-x-20 md:translate-y-6"
        >
          <FantaGolLogo />
        </a>

        <nav className="hidden items-center gap-3 md:flex md:translate-y-2">
          <div className="relative">
            <button
              type="button"
              onClick={() => setAppOpen(!appOpen)}
              className="rounded-full bg-gradient-to-r from-green-600 to-green-500 px-5 py-2 text-sm font-semibold text-white shadow-lg shadow-green-900/30 transition hover:scale-105"
            >
              Scarica App ▾
            </button>

            {appOpen && (
              <div className="absolute right-0 mt-3 w-52 overflow-hidden rounded-2xl border border-gray-700 bg-gray-950 shadow-xl">
                <a href="/download" className="block px-5 py-3 text-sm text-gray-200 hover:bg-gray-900">
                  📱 Android
                </a>
                <a href="/download" className="block border-t border-gray-800 px-5 py-3 text-sm text-gray-200 hover:bg-gray-900">
                  🍎 iPhone
                </a>
              </div>
            )}
          </div>

          <a href="/leghe" className="rounded-full border border-gray-700 bg-gray-900 px-5 py-2 text-sm font-semibold text-gray-200 transition hover:border-green-700 hover:bg-gray-800 hover:text-green-300">
            Leghe
          </a>

          <a href="/login" className="rounded-full border border-gray-700 bg-gray-900 px-5 py-2 text-sm font-semibold text-gray-200 transition hover:border-white hover:bg-gray-800">
            Accedi
          </a>
        </nav>

        <button
          type="button"
          onClick={() => setOpen(!open)}
          aria-label="Apri menu"
          className="md:hidden rounded-lg border border-gray-700 bg-gray-900 px-3 py-2 text-2xl leading-none text-white"
        >
          ☰
        </button>
      </div>

      {open && (
        <nav className="border-t border-gray-800 bg-gray-950 px-6 py-6 text-gray-300 md:hidden">
          <div className="space-y-5 text-lg">
            <a onClick={() => setOpen(false)} className="block" href="/play">Gioca Online</a>
            <a onClick={() => setOpen(false)} className="block" href="/leghe">Le mie Leghe</a>
            <a onClick={() => setOpen(false)} className="block" href="/crea-lega">Crea Lega</a>

            <div className="space-y-2">
              <div className="font-semibold text-white">Scarica App</div>
              <a onClick={() => setOpen(false)} className="block pl-4 text-base" href="/download">📱 Android</a>
              <a onClick={() => setOpen(false)} className="block pl-4 text-base" href="/download">🍎 iPhone</a>
            </div>

            <a onClick={() => setOpen(false)} className="block" href="/login">Accedi</a>
            <a onClick={() => setOpen(false)} className="block" href="/regolamento">Come si Gioca</a>
          </div>
        </nav>
      )}
    </header>
  );
}