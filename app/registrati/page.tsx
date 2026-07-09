"use client";

import { useState } from "react";
import Header from "../../components/Header";
import { supabase } from "../../lib/supabaseClient";

export default function RegistratiPage() {
  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  async function handleGoogleLogin() {
    const { error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: {
        redirectTo: `${window.location.origin}/auth/callback`,
      },
    });

    if (error) alert(error.message);
  }

  async function handleRegister(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const { error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: {
          username,
        },
        emailRedirectTo: `${window.location.origin}/leghe`,
      },
    });

    if (error) {
      alert(error.message);
      return;
    }

    alert("Registrazione completata. Controlla la tua email per confermare l'account.");
  }

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-md rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            FantaGol
          </p>

          <h1 className="mb-3 text-3xl font-black">Crea il tuo account</h1>

          <p className="mb-8 text-gray-400">
            Registrati per creare leghe, ricevere inviti e iniziare a giocare.
          </p>

          <button
            type="button"
            onClick={handleGoogleLogin}
            className="mb-6 w-full rounded-xl border border-gray-600 bg-white px-5 py-3 font-semibold text-black transition hover:bg-gray-200"
          >
            Continua con Google
          </button>

          <div className="mb-6 flex items-center gap-4 text-sm text-gray-500">
            <div className="h-px flex-1 bg-gray-700" />
            oppure
            <div className="h-px flex-1 bg-gray-700" />
          </div>

          <form onSubmit={handleRegister} className="space-y-4">
            <input
              type="text"
              placeholder="Nome utente"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
            />

            <input
              type="email"
              placeholder="Email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
            />

            <input
              type="password"
              placeholder="Password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
            />

<label className="flex items-start gap-3 text-sm text-gray-400">
  <input
    type="checkbox"
    required
    className="mt-1 h-4 w-4 rounded border-gray-700 bg-[#111111] accent-[#A6E824]"
  />
  <span>
    Accetto i{" "}
    <a href="/termini" className="font-semibold text-[#A6E824] hover:brightness-110">
      Termini di utilizzo
    </a>{" "}
    e ho letto l&apos;
    <a href="/privacy" className="font-semibold text-[#A6E824] hover:brightness-110">
      Informativa Privacy
    </a>
    .
  </span>
</label>

            <button
              type="submit"
              className="w-full rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
            >
              Registrati
            </button>
          </form>

          <p className="mt-6 text-center text-sm text-gray-400">
            Hai già un account?{" "}
            <a href="/login" className="font-semibold text-[#A6E824] hover:brightness-110">
              Accedi
            </a>
          </p>
        </div>
      </section>
    </main>
  );
}
