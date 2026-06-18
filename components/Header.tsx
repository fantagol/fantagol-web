"use client";

import { useState } from "react";
import FantaGolLogo from "./FantaGolLogo";

export default function Header() {
  const [open, setOpen] = useState(false);

  return (
    <header className="border-b border-gray-800 relative z-50">
      <div className="max-w-6xl mx-auto px-6 h-24 flex items-center justify-between overflow-visible">
        <button
          type="button"
          onClick={() => setOpen(!open)}
          aria-label="Apri menu"
          className="md:hidden text-white text-3xl leading-none"
        >
          ☰
        </button>

        <a
          href="/"
          aria-label="Vai alla home FantaGol"
          className="block -translate-x-10 translate-y-6 md:-translate-x-24"
        >
          <FantaGolLogo />
        </a>

        <nav className="hidden md:flex gap-8 text-gray-300">
          <a href="/#funziona">Come Funziona</a>
          <a href="/#modalita">Modalità</a>
          <a href="/#perche">Perché FantaGol</a>
          <a href="/regolamento">Regolamento</a>
          <a href="/play">Play Online</a>
          <a href="/download">Download</a>
        </nav>

        <div className="md:hidden w-8" />
      </div>

      {open && (
        <nav className="md:hidden border-t border-gray-800 bg-black px-6 py-6 space-y-4 text-gray-300">
          <a onClick={() => setOpen(false)} className="block" href="/">
            Home
          </a>
          <a onClick={() => setOpen(false)} className="block" href="/#funziona">
            Come Funziona
          </a>
          <a onClick={() => setOpen(false)} className="block" href="/#modalita">
            Modalità
          </a>
          <a onClick={() => setOpen(false)} className="block" href="/#perche">
            Perché FantaGol
          </a>
          <a onClick={() => setOpen(false)} className="block" href="/regolamento">
            Regolamento
          </a>
          <a onClick={() => setOpen(false)} className="block" href="/play">
            Play Online
          </a>
          <a onClick={() => setOpen(false)} className="block" href="/download">
            Download
          </a>
        </nav>
      )}
    </header>
  );
}