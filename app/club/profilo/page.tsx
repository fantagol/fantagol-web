"use client";

import { ChangeEvent, useEffect, useState } from "react";
import FantaGolLogo from "../../../components/FantaGolLogo";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
import { supabase } from "../../../lib/supabaseClient";

type Club = {
  club_id: string;
  name: string;
  motto: string | null;
  crest_url: string | null;
  stars_count: number;
  total_titles: number;
  real_name?: string | null;
};

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

export default function ClubProfilePage() {
  const [club, setClub] = useState<Club | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [saved, setSaved] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);

  const [name, setName] = useState("");
  const [motto, setMotto] = useState("");
  const [realName, setRealName] = useState("");
  const [avatarUrl, setAvatarUrl] = useState<string | null>(null);
  const [avatarPreview, setAvatarPreview] = useState<string | null>(null);

  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });

  useEffect(() => {
    async function loadClub() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.user) {
        window.location.href = "/login";
        return;
      }

      const { data: leaguesData } = await supabase.rpc("get_my_leagues_rpc");
      const firstLeague = (leaguesData || [])[0];

      if (firstLeague) {
        setLeagueInfo({
          leagueName: firstLeague.league_name || "Lega FantaGol",
          displayName: firstLeague.display_name || "Club FantaGol",
          inviteCode: firstLeague.invite_code || firstLeague.league_id || "",
          role: firstLeague.role || "member",
        });
      }

      const { data, error } = await supabase.rpc("get_my_club_rpc");

      if (error) {
        alert(error.message);
        setLoading(false);
        return;
      }

      if (data && data.length > 0) {
        const loadedClub = data[0] as Club;
        const currentDisplayName =
          firstLeague?.display_name || loadedClub.name || "";

        setClub({
          ...loadedClub,
          name: currentDisplayName,
        });
        setName(currentDisplayName);
        setMotto(loadedClub.motto || "");
        setRealName(loadedClub.real_name || "");
        setAvatarUrl(loadedClub.crest_url || null);
        setAvatarPreview(loadedClub.crest_url || null);
      }

      setLoading(false);
    }

    loadClub();
  }, []);

  async function uploadAvatar(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];

    if (!file || !club) return;

    if (!file.type.startsWith("image/")) {
      alert("Carica un file immagine.");
      return;
    }

    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session?.user) {
      window.location.href = "/login";
      return;
    }

    setUploading(true);
    setSaved(false);

    const extension = file.name.split(".").pop() || "png";
    const filePath = `${session.user.id}/${club.club_id}.${extension}`;

    const { error: uploadError } = await supabase.storage
      .from("club-avatars")
      .upload(filePath, file, {
        cacheControl: "3600",
        upsert: true,
      });

    if (uploadError) {
      setUploading(false);
      alert(uploadError.message);
      return;
    }

    const { data } = supabase.storage.from("club-avatars").getPublicUrl(filePath);

    setAvatarUrl(data.publicUrl);
    setAvatarPreview(data.publicUrl);
    setUploading(false);
  }

  async function saveProfile() {
    if (!club) return;

    const cleanName = name.trim();
    const cleanMotto = motto.trim();

    if (!cleanName) {
      alert("Il nome del Club non può essere vuoto.");
      return;
    }

    setSaving(true);
    setSaved(false);

    const { error } = await supabase.rpc("update_my_club_profile_rpc", {
      p_name: cleanName,
      p_motto: cleanMotto || null,
      p_crest_url: avatarUrl,
    });

    setSaving(false);

    if (error) {
      alert(error.message);
      return;
    }

    setSaved(true);
    setClub({
      ...club,
      name: cleanName,
      motto: cleanMotto || null,
      crest_url: avatarUrl,
    });
    setLeagueInfo((current) => ({
      ...current,
      displayName: cleanName,
    }));
  }

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-black text-white">
        Caricamento Profilo Club...
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
    <main className="min-h-screen bg-black pt-14 text-white">
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-gradient-to-r from-[#2a2f32] via-[#1f2427] to-[#2a2f32] shadow-2xl shadow-black/80 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
          <div className="pointer-events-none relative z-0 block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6">
            <FantaGolLogo />
          </div>

          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu"
            className="rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
          >
            ☰
          </button>
        </div>
      </header>

      <HamburgerDrawer
        open={menuOpen}
        leagueName={leagueInfo.leagueName}
        displayName={leagueInfo.displayName}
        inviteCode={leagueInfo.inviteCode}
        role={leagueInfo.role}
        onClose={() => setMenuOpen(false)}
      />

      <section className="mx-auto max-w-6xl px-6 py-10">
        <a href="/club" className="text-sm font-bold text-[#A6E824] hover:underline">
          ← Torna al Club
        </a>

        <div className="mt-6 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.3em] text-[#A6E824]">
              Profilo Club
            </p>
            <h1 className="mt-3 text-4xl font-black md:text-5xl">
              {name.trim() || club.name}
            </h1>
            <p className="mt-3 max-w-2xl text-gray-400">
              Crea l'avatar rotondo del tuo Club, aggiorna il nome e aggiungi un motto personale.
            </p>
          </div>

          <button
            type="button"
            onClick={saveProfile}
            disabled={saving || uploading}
            className="rounded-2xl bg-[#A6E824] px-8 py-4 font-black text-black transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
          >
            {saving ? "Salvataggio..." : "Salva Profilo"}
          </button>
        </div>

        {saved && (
          <div className="mt-6 rounded-2xl border border-[#A6E824]/40 bg-[#A6E824]/10 px-5 py-4 text-sm font-bold text-[#A6E824]">
            Profilo Club salvato correttamente.
          </div>
        )}

        <div className="mt-10 grid gap-6 lg:grid-cols-[380px_1fr]">
          <div className="rounded-3xl border border-gray-700 bg-gradient-to-b from-[#23282b] to-[#111111] p-8">
            <div className="mx-auto flex h-56 w-56 items-center justify-center overflow-hidden rounded-full border-4 border-[#A6E824]/70 bg-black shadow-2xl shadow-black/70">
              {avatarPreview ? (
                <img
                  src={avatarPreview}
                  alt="Avatar Club"
                  className="h-full w-full object-cover"
                />
              ) : (
                <div className="flex h-full w-full items-center justify-center bg-[#151515] text-6xl font-black text-[#A6E824]">
                  {name.trim().slice(0, 1).toUpperCase() || "F"}
                </div>
              )}
            </div>

            <p className="mt-6 text-center text-sm text-gray-400">
              Avatar ufficiale del Club
            </p>

            <label className="mt-6 block cursor-pointer rounded-2xl border border-gray-700 bg-black px-5 py-4 text-center font-bold transition hover:border-[#A6E824] hover:text-[#A6E824]">
              {uploading ? "Caricamento..." : "Carica Immagine"}
              <input
                type="file"
                accept="image/*"
                onChange={uploadAvatar}
                disabled={uploading}
                className="hidden"
              />
            </label>

            <p className="mt-4 text-center text-xs leading-5 text-gray-500">
              Usa un'immagine quadrata o centrata: verrà mostrata in formato rotondo nelle classifiche,
              nelle sfide e nel menu.
            </p>
          </div>

          <div className="space-y-6">
            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6">
              <h2 className="text-2xl font-black">Identità Club</h2>

              <div className="mt-6 space-y-5">
                <label className="block">
                  <span className="text-sm font-bold text-gray-400">Nome Club</span>
                  <input
                    type="text"
                    value={name}
                    onChange={(event) => setName(event.target.value)}
                    maxLength={32}
                    className="mt-3 w-full rounded-2xl border border-gray-700 bg-black px-4 py-4 font-bold text-white outline-none transition placeholder:text-gray-600 focus:border-[#A6E824]"
                    placeholder="Nome del tuo Club"
                  />
                  <span className="mt-2 block text-xs text-gray-500">
                    {name.length}/32 caratteri
                  </span>
                </label>

                <label className="block">
                  <span className="text-sm font-bold text-gray-400">Nome reale</span>
                  <input
                    type="text"
                    value={realName}
                    onChange={(event) => setRealName(event.target.value)}
                    maxLength={40}
                    className="mt-3 w-full rounded-2xl border border-gray-700 bg-black px-4 py-4 font-bold text-white outline-none transition placeholder:text-gray-600 focus:border-[#A6E824]"
                    placeholder="Es. Mario"
                  />
                  <span className="mt-2 block text-xs text-gray-500">
                    Visibile solo nella pagina Membri della lega e nelle chat.
                  </span>
                </label>

                <label className="block">
                  <span className="text-sm font-bold text-gray-400">Motto</span>
                  <textarea
                    value={motto}
                    onChange={(event) => setMotto(event.target.value)}
                    maxLength={90}
                    rows={4}
                    className="mt-3 w-full resize-none rounded-2xl border border-gray-700 bg-black px-4 py-4 font-bold text-white outline-none transition placeholder:text-gray-600 focus:border-[#A6E824]"
                    placeholder="Scrivi il motto del tuo Club"
                  />
                  <span className="mt-2 block text-xs text-gray-500">
                    {motto.length}/90 caratteri
                  </span>
                </label>
              </div>
            </div>

            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6">
              <h2 className="text-2xl font-black">Anteprima</h2>

              <div className="mt-6 rounded-2xl border border-gray-800 bg-black p-5">
                <div className="flex items-center gap-4">
                  <div className="flex h-16 w-16 shrink-0 items-center justify-center overflow-hidden rounded-full border-2 border-[#A6E824]/70 bg-[#151515]">
                    {avatarPreview ? (
                      <img
                        src={avatarPreview}
                        alt="Anteprima avatar"
                        className="h-full w-full object-cover"
                      />
                    ) : (
                      <span className="text-2xl font-black text-[#A6E824]">
                        {name.trim().slice(0, 1).toUpperCase() || "F"}
                      </span>
                    )}
                  </div>

                  <div>
                    <div className="text-xl font-black">
                      {name.trim() || "Club FantaGol"}
                    </div>
                    <div className="mt-1 text-xs font-semibold text-gray-500">
                      {realName.trim() || "Nome reale"}
                    </div>
                    <div className="mt-1 text-sm text-gray-400">
                      {motto.trim() || "Il tuo Club FantaGol sta per iniziare la sua storia."}
                    </div>
                  </div>
                </div>
              </div>

              <p className="mt-4 text-sm leading-6 text-gray-400">
                Questa identità accompagnerà il tuo Club in dashboard, classifiche, live e sfide.
              </p>
            </div>
          </div>
        </div>
      </section>
    </main>
  );
}
