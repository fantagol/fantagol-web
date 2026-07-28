"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import FantaGolLogo from "./FantaGolLogo";
import { supabase } from "../lib/supabaseClient";

const fantagolGreen = "#A6E824";

export default function Header() {
  const [open, setOpen] = useState(false);
  const [isLoggedIn, setIsLoggedIn] = useState(false);

  useEffect(() => {
    let mounted = true;

    supabase.auth.getSession().then(({ data }) => {
      if (!mounted) return;
      setIsLoggedIn(Boolean(data.session));
    });

    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      setIsLoggedIn(Boolean(session));
    });

    return () => {
      mounted = false;
      listener.subscription.unsubscribe();
    };
  }, []);

  async function handleLogout() {
    await supabase.auth.signOut();
    setOpen(false);
    window.location.href = "/";
  }

  function closeMenu() {
    setOpen(false);
  }

  return (
    <header className="fixed inset-x-0 top-0 z-[100] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
      <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
        <a
                    className="relative z-10 block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6"
        >
          <FantaGolLogo />
        </a>

        <nav className="hidden items-center gap-3 md:flex md:translate-y-2">
          <a
            href="/download"
            className="rounded-full bg-[#A6E824] px-5 py-2 text-sm font-semibold text-black shadow-lg shadow-[#A6E824]/25 transition hover:brightness-110"
          >
            Scarica l&apos;app
          </a>

          <a
            href="/login"
            className="rounded-full border border-gray-600 bg-[#2b2f31] px-5 py-2 text-sm font-semibold text-gray-100 transition hover:border-[#A6E824] hover:text-white"
          >
            Leghe
          </a>

          {isLoggedIn ? (
            <button
              type="button"
              onClick={handleLogout}
              className="rounded-full border border-gray-600 bg-[#2b2f31] px-5 py-2 text-sm font-semibold text-gray-100 transition hover:border-[#A6E824] hover:text-white"
            >
              Logout
            </button>
          ) : (
            <a
              href="/login"
              className="rounded-full border border-gray-600 bg-[#2b2f31] px-5 py-2 text-sm font-semibold text-gray-100 transition hover:border-[#A6E824] hover:text-white"
            >
              Accedi
            </a>
          )}
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
        <nav className="absolute right-0 top-14 z-50 h-[calc(100vh-56px)] w-[65vw] overflow-y-auto border-l border-t border-gray-700 bg-[#1a1d1f] px-6 py-6 text-gray-300 shadow-2xl shadow-black/80 md:hidden">
          <div className="space-y-5 text-lg">
            <a onClick={closeMenu} className="block" href="/login">
              Gioca Online
            </a>

            {isLoggedIn && (
              <>
                <Link onClick={closeMenu} className="block" href="/leghe">
                  Le mie Leghe
                </Link>

                <a onClick={closeMenu} className="block" href="/crea-lega">
                  Crea Lega
                </a>
              </>
            )}

            <a
              onClick={closeMenu}
              className="block font-semibold"
              style={{ color: fantagolGreen }}
              href="/download"
            >
              Scarica l&apos;app
            </a>

            <a onClick={closeMenu} className="block" href="/regolamento">
              Come si Gioca
            </a>

            {isLoggedIn && (
              <>
                <a onClick={closeMenu} className="block" href="/supporto">
                  Supporto
                </a>

                <button
                  type="button"
                  onClick={handleLogout}
                  className="block w-full text-left text-red-300"
                >
                  Logout
                </button>
              </>
            )}
          </div>
        </nav>
      )}
    </header>
  );
}

