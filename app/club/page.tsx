"use client";

import { useEffect, useState } from "react";
import Header from "../../components/Header";
import KitPreview from "../../components/club/KitPreview";
import { supabase } from "../../lib/supabaseClient";

type Club = {
  club_id: string;
  name: string;
  motto: string | null;
  crest_url: string | null;
  kit_template: string;
  kit_primary_color: string;
  kit_secondary_color: string;
  kit_third_color: string;
  kit_logo_mode: string;
  kit_crest_position: string;
  stars_count: number;
  total_titles: number;
};

export default function ClubPage() {
  const [club, setClub] = useState<Club | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function loadClub() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.user) {
        window.location.href = "/login";
        return;
      }

      const { data, error } = await supabase.rpc("get_my_club_rpc");

      if (error) {
        alert(error.message);
        setLoading(false);
        return;
      }

      if (data && data.length > 0) {
        setClub(data[0]);
      }

      setLoading(false);
    }

    loadClub();
  }, []);

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-black text-white">
        Caricamento Club...
      </main>
    );
  }

  if (!club) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-black text-white">
        Club non trovato.
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto max-w-6xl px-6 py-10">
        <p className="text-sm font-semibold uppercase tracking-[0.3em] text-[#A6E824]">
          Il Mio Club
        </p>

        <h1 className="mt-3 text-5xl font-black">{club.name}</h1>

        <p className="mt-4 text-gray-400">
          {club.motto || "Il tuo Club FantaGol sta per iniziare la sua storia."}
        </p>

        <div className="mt-10 grid gap-6 lg:grid-cols-[380px_1fr]">
          <div className="rounded-3xl border border-gray-700 bg-gradient-to-b from-[#23282b] to-[#111111] p-8">
            <KitPreview
              primary={club.kit_primary_color}
              secondary={club.kit_secondary_color}
              third={club.kit_third_color}
              template={club.kit_template}
              logoMode={club.kit_logo_mode}
              crestPosition={club.kit_crest_position}
              starsCount={club.stars_count}
            />

            <p className="mt-6 text-center text-sm text-gray-400">
              Kit ufficiale del Club
            </p>
          </div>

          <div className="space-y-6">
            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6">
              <h2 className="text-2xl font-black">Hall of Fame</h2>

              <div className="mt-6 grid grid-cols-2 gap-4">
                <div className="rounded-2xl bg-black p-5">
                  <div className="text-sm text-gray-400">Stelle</div>
                  <div className="mt-2 text-4xl font-black text-[#A6E824]">
                    {club.stars_count}
                  </div>
                </div>

                <div className="rounded-2xl bg-black p-5">
                  <div className="text-sm text-gray-400">Titoli</div>
                  <div className="mt-2 text-4xl font-black text-[#A6E824]">
                    {club.total_titles}
                  </div>
                </div>
              </div>
            </div>

            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6">
              <h2 className="text-2xl font-black">Personalizzazione</h2>

              <div className="mt-6 space-y-4">
                <button className="w-full rounded-2xl bg-[#A6E824] py-4 font-bold text-black">
                  Personalizza Kit
                </button>

                <button className="w-full rounded-2xl border border-gray-700 py-4">
                  Cambia Nome Club
                </button>

                <button className="w-full rounded-2xl border border-gray-700 py-4">
                  Cambia Motto
                </button>

                <button className="w-full rounded-2xl border border-gray-700 py-4">
                  Gestisci Stemma
                </button>
              </div>
            </div>
          </div>
        </div>
      </section>
    </main>
  );
}