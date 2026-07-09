"use client";

import { useEffect, useMemo, useState } from "react";
import FantaGolLogo from "../../../components/FantaGolLogo";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
import KitPreview from "../../../components/club/KitPreview";
import { supabase } from "../../../lib/supabaseClient";

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

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

const KIT_TEMPLATES = [
  { value: "solid", label: "Tinta unita" },
  { value: "center_band", label: "Palo centrale" },
  { value: "vertical_3", label: "Bande verticali 3" },
  { value: "vertical_5", label: "Bande verticali 5" },
  { value: "thin_stripes", label: "Righe sottili" },
  { value: "horizontal_3", label: "Bande orizzontali" },
  { value: "horizontal_band", label: "Fascia orizzontale" },
  { value: "chest_panel", label: "Petto pieno" },
  { value: "diagonal", label: "Diagonale" },
  { value: "diagonal_reverse", label: "Diagonale inversa" },
  { value: "sash", label: "Sash" },
  { value: "sleeves", label: "Maniche colorate" },
  { value: "shoulders", label: "Spalle colorate" },
  { value: "cross", label: "Croce" },
  { value: "quarters", label: "Quarti" },
  { value: "split", label: "Mezza maglia" },
  { value: "third_details", label: "Dettaglio terzo colore" },
];

const LOGO_MODES = [
  { value: "center_horizontal", label: "Stemma + wordmark" },
  { value: "wordmark_only", label: "Solo wordmark" },
];

const CREST_POSITIONS = [
  { value: "left_chest", label: "Petto sinistro" },
  { value: "right_chest", label: "Petto destro" },
];

export default function ClubKitPage() {
  const [club, setClub] = useState<Club | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);

  const [template, setTemplate] = useState("solid");
  const [primary, setPrimary] = useState("#FFFFFF");
  const [secondary, setSecondary] = useState("#111417");
  const [third, setThird] = useState("#A6E824");
  const [logoMode, setLogoMode] = useState("center_horizontal");
  const [crestPosition, setCrestPosition] = useState("left_chest");

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
        setClub(loadedClub);
        setTemplate(loadedClub.kit_template || "solid");
        setPrimary(loadedClub.kit_primary_color || "#FFFFFF");
        setSecondary(loadedClub.kit_secondary_color || "#111417");
        setThird(loadedClub.kit_third_color || "#A6E824");
        setLogoMode(loadedClub.kit_logo_mode || "center_horizontal");
        setCrestPosition(loadedClub.kit_crest_position || "left_chest");
      }

      setLoading(false);
    }

    loadClub();
  }, []);

  const selectedTemplateLabel = useMemo(() => {
    return KIT_TEMPLATES.find((item) => item.value === template)?.label || "Tinta unita";
  }, [template]);

  async function saveKit() {
    if (!club) return;

    setSaving(true);
    setSaved(false);

    const { error } = await supabase.rpc("update_my_club_kit_rpc", {
      p_kit_template: template,
      p_kit_primary_color: primary,
      p_kit_secondary_color: secondary,
      p_kit_third_color: third,
      p_kit_logo_mode: logoMode,
      p_kit_crest_position: crestPosition,
    });

    setSaving(false);

    if (error) {
      alert(error.message);
      return;
    }

    setSaved(true);
    setClub({
      ...club,
      kit_template: template,
      kit_primary_color: primary,
      kit_secondary_color: secondary,
      kit_third_color: third,
      kit_logo_mode: logoMode,
      kit_crest_position: crestPosition,
    });
  }

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-black text-white">
        Caricamento Kit...
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
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
          <a
                        className="pointer-events-none relative z-0 block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6"
          >
            <FantaGolLogo />
          </a>

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
              Personalizza Kit
            </p>
            <h1 className="mt-3 text-4xl font-black md:text-5xl">{club.name}</h1>
            <p className="mt-3 max-w-2xl text-gray-400">
              Scegli modello, colori e posizione dello stemma. L'anteprima si aggiorna in tempo reale.
            </p>
          </div>

          <button
            type="button"
            onClick={saveKit}
            disabled={saving}
            className="rounded-2xl bg-[#A6E824] px-8 py-4 font-black text-black transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
          >
            {saving ? "Salvataggio..." : "Salva Kit"}
          </button>
        </div>

        {saved && (
          <div className="mt-6 rounded-2xl border border-[#A6E824]/40 bg-[#A6E824]/10 px-5 py-4 text-sm font-bold text-[#A6E824]">
            Kit salvato correttamente.
          </div>
        )}

        <div className="mt-10 grid gap-6 lg:grid-cols-[380px_1fr]">
          <div className="rounded-3xl border border-gray-700 bg-gradient-to-b from-[#23282b] to-[#111111] p-8">
            <KitPreview
              primary={primary}
              secondary={secondary}
              third={third}
              template={template}
              logoMode={logoMode}
              crestPosition={crestPosition}
              starsCount={club.stars_count}
            />

            <div className="mt-6 rounded-2xl bg-black/50 p-4 text-center">
              <p className="text-xs uppercase tracking-[0.25em] text-gray-500">Template</p>
              <p className="mt-1 text-lg font-black text-[#A6E824]">{selectedTemplateLabel}</p>
            </div>
          </div>

          <div className="space-y-6">
            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6">
              <h2 className="text-2xl font-black">Modello Maglia</h2>

              <div className="mt-6 grid gap-3 sm:grid-cols-2">
                {KIT_TEMPLATES.map((item) => (
                  <button
                    key={item.value}
                    type="button"
                    onClick={() => setTemplate(item.value)}
                    className={`rounded-2xl border px-4 py-3 text-left font-bold transition ${
                      template === item.value
                        ? "border-[#A6E824] bg-[#A6E824] text-black"
                        : "border-gray-700 bg-black text-gray-200 hover:border-[#A6E824]"
                    }`}
                  >
                    {item.label}
                  </button>
                ))}
              </div>
            </div>

            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6">
              <h2 className="text-2xl font-black">Colori</h2>

              <div className="mt-6 grid gap-4 sm:grid-cols-3">
                <label className="rounded-2xl border border-gray-700 bg-black p-4">
                  <span className="block text-sm font-bold text-gray-400">Primario</span>
                  <input
                    type="color"
                    value={primary}
                    onChange={(event) => setPrimary(event.target.value)}
                    className="mt-3 h-12 w-full cursor-pointer rounded-xl border border-gray-700 bg-transparent"
                  />
                  <span className="mt-2 block text-xs text-gray-500">{primary}</span>
                </label>

                <label className="rounded-2xl border border-gray-700 bg-black p-4">
                  <span className="block text-sm font-bold text-gray-400">Secondario</span>
                  <input
                    type="color"
                    value={secondary}
                    onChange={(event) => setSecondary(event.target.value)}
                    className="mt-3 h-12 w-full cursor-pointer rounded-xl border border-gray-700 bg-transparent"
                  />
                  <span className="mt-2 block text-xs text-gray-500">{secondary}</span>
                </label>

                <label className="rounded-2xl border border-gray-700 bg-black p-4">
                  <span className="block text-sm font-bold text-gray-400">Dettagli</span>
                  <input
                    type="color"
                    value={third}
                    onChange={(event) => setThird(event.target.value)}
                    className="mt-3 h-12 w-full cursor-pointer rounded-xl border border-gray-700 bg-transparent"
                  />
                  <span className="mt-2 block text-xs text-gray-500">{third}</span>
                </label>
              </div>
            </div>

            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6">
              <h2 className="text-2xl font-black">Logo e Stemma</h2>

              <div className="mt-6 grid gap-4 md:grid-cols-2">
                <label className="block">
                  <span className="text-sm font-bold text-gray-400">Logo sulla maglia</span>
                  <select
                    value={logoMode}
                    onChange={(event) => setLogoMode(event.target.value)}
                    className="mt-3 w-full rounded-2xl border border-gray-700 bg-black px-4 py-4 font-bold text-white outline-none focus:border-[#A6E824]"
                  >
                    {LOGO_MODES.map((item) => (
                      <option key={item.value} value={item.value}>
                        {item.label}
                      </option>
                    ))}
                  </select>
                </label>

                <label className="block">
                  <span className="text-sm font-bold text-gray-400">Posizione stemma</span>
                  <select
                    value={crestPosition}
                    onChange={(event) => setCrestPosition(event.target.value)}
                    className="mt-3 w-full rounded-2xl border border-gray-700 bg-black px-4 py-4 font-bold text-white outline-none focus:border-[#A6E824]"
                  >
                    {CREST_POSITIONS.map((item) => (
                      <option key={item.value} value={item.value}>
                        {item.label}
                      </option>
                    ))}
                  </select>
                </label>
              </div>
            </div>
          </div>
        </div>
      </section>
    </main>
  );
}

