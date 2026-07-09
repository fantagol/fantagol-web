"use client";

import { useEffect } from "react";
import { supabase } from "../../../lib/supabaseClient";

export default function AuthCallbackPage() {
  useEffect(() => {
    async function finishLogin() {
      await supabase.auth.getSession();
      window.location.href = "/leghe";
    }

    finishLogin();
  }, []);

  return (
    <main className="min-h-screen bg-black text-white flex items-center justify-center">
      Accesso in corso...
    </main>
  );
}
