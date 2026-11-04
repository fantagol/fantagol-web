"use client";

import { supabase } from "@/lib/supabaseClient";
import WebPushActivation from "@/components/push/WebPushActivation";

/** Web-only entry. Parent drawer excludes native Capacitor app. */
export default function WebPushDrawerEntry() {
  return (
    <section className="rounded-2xl border border-[#A6E824]/30 bg-[#A6E824]/[0.06] p-3">
      <div className="mb-2 text-sm font-bold text-white">Notifiche FantaGol</div>
      <p className="mb-3 text-xs leading-5 text-gray-300">
        Ricevi gli avvisi anche quando il sito non e aperto. Su iPhone aggiungi
        prima FantaGol alla schermata Home.
      </p>
      <div className="space-y-2 [&_button]:w-full [&_button]:rounded-xl [&_button]:bg-[#A6E824] [&_button]:px-3 [&_button]:py-2.5 [&_button]:text-sm [&_button]:font-bold [&_button]:text-black [&_button:disabled]:opacity-50 [&_p]:mt-2 [&_p]:text-xs [&_p]:leading-5 [&_p]:text-gray-200">
        <WebPushActivation
          getAccessToken={async () => {
            const { data, error } = await supabase.auth.getSession();
            if (error) return null;
            return data.session?.access_token ?? null;
          }}
        />
      </div>
    </section>
  );
}
