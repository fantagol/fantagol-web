"use client";

import { useState } from "react";
import Header from "../../components/Header";
import { supabase } from "../../lib/supabaseClient";

export default function PasswordResetPage() {
  const [email, setEmail] = useState("");

  async function handleReset(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/aggiorna-password`,
    });

    if (error) {
      alert(error.message);
      return;
    }

    alert("Ti abbiamo inviato una email per reimpostare la password.");
  }

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-md rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            Recupero Password
          </p>

          <h1 className="mb-3 text-3xl font-black">
            Password dimenticata?
          </h1>

          <p className="mb-8 text-gray-400">
            Inserisci la tua email e ti invieremo il link per crearne una nuova.
          </p>

          <form onSubmit={handleReset} className="space-y-4">
            <input
              type="email"
              placeholder="Email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
            />

            <button
              type="submit"
              className="w-full rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
            >
              Invia link di recupero
            </button>
          </form>

          
        </div>
      </section>
    </main>
  );
}