"use client";

import { supabase } from "../../lib/supabaseClient";

type HamburgerDrawerProps = {
  open: boolean;
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
  onClose: () => void;
};

export default function HamburgerDrawer({
  open,
  leagueName,
  displayName,
  inviteCode,
  role,
  onClose,
}: HamburgerDrawerProps) {
  if (!open) return null;

  async function logout() {
    const ok = confirm("Vuoi uscire da FantaGol?");
    if (!ok) return;

    await supabase.auth.signOut();
    window.location.href = "/";
  }

  function copyInviteLink() {
    const inviteLink = `${window.location.origin}/invito/${inviteCode}`;
    navigator.clipboard.writeText(inviteLink);
    alert("Link invito copiato.");
  }

  function goTo(path: string) {
    onClose();
    window.location.href = path;
  }

  return (
    <div className="fixed inset-0 z-[100] bg-black/70">
      <aside className="flex h-full w-[65vw] max-w-[360px] flex-col bg-[#111417] shadow-2xl">
        <div className="border-b border-gray-800 p-6">
          <button
            type="button"
            onClick={onClose}
            className="mb-6 rounded-xl border border-gray-700 px-3 py-2"
          >
            ✕
          </button>

          <h2 className="text-2xl font-black text-[#A6E824]">
            {leagueName}
          </h2>

          <p className="mt-1 text-sm text-gray-400">
            Nome nella lega: {displayName}
          </p>
        </div>

        <nav className="flex-1 space-y-4 overflow-y-auto p-6 text-lg">
          <button onClick={() => goTo("/leghe")} className="block text-left">
            🔄 Cambia lega
          </button>

          <button onClick={() => goTo("/crea-lega")} className="block text-left">
            ➕ Crea nuova lega
          </button>

          <button
            type="button"
            onClick={copyInviteLink}
            className="block text-left"
          >
            📨 Copia link invito
          </button>

          <div className="my-5 border-t border-gray-700" />

          <button onClick={() => goTo("#")} className="block text-left">
            🎯 Pronostici
          </button>

          <button onClick={() => goTo("#")} className="block text-left">
            ⚽ Live
          </button>

          <button onClick={() => goTo("#")} className="block text-left">
            🏆 Classifiche
          </button>

          <button onClick={() => goTo("#")} className="block text-left">
            📅 Calendario
          </button>

          <button onClick={() => goTo("#")} className="block text-left">
            👥 La mia Lega
          </button>

          <div className="my-5 border-t border-gray-700" />

          <button onClick={() => goTo("/club")} className="block text-left">
            🏟 Il Mio Club
          </button>

          <button onClick={() => goTo("#")} className="block text-left">
            🏛 Hall of Fame
          </button>

          {role === "owner" && (
            <>
              <div className="my-5 border-t border-gray-700" />

              <button onClick={() => goTo("#")} className="block text-left">
                ⚙️ Impostazioni Lega
              </button>
            </>
          )}

          <div className="my-5 border-t border-gray-700" />

          <button onClick={() => goTo("#")} className="block text-left">
            ❓ Supporto
          </button>

          <button
            type="button"
            onClick={logout}
            className="block text-left text-red-400"
          >
            🚪 Esci da FantaGol
          </button>
        </nav>
      </aside>
    </div>
  );
}