"use client";

/* eslint-disable @next/next/no-img-element -- Local screenshot preview uses an object URL selected by the user. */

import {
  ChangeEvent,
  FormEvent,
  useEffect,
  useRef,
  useState,
} from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import Header from "../../components/Header";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";

const LAST_LEAGUE_STORAGE_KEY = "fantagol:last-league-id";
const MAX_ORIGINAL_SCREENSHOT_SIZE = 10 * 1024 * 1024;
const MAX_OPTIMIZED_SCREENSHOT_SIZE = 1 * 1024 * 1024;
const MAX_SCREENSHOT_DIMENSION = 1600;
const SCREENSHOT_WEBP_QUALITY = 0.82;

type DrawerLeague = {
  id: string;
  name: string;
  inviteCode: string;
  displayName: string;
  role: string;
};

type MyLeagueRpcRow = {
  league_id: string;
  league_name?: string | null;
  invite_code?: string | null;
  display_name?: string | null;
  role?: string | null;
  status?: string | null;
};

type SupportCategory =
  | "account_access"
  | "league_invite"
  | "predictions"
  | "scores_rankings"
  | "public_leagues"
  | "premium_pass"
  | "app_website"
  | "other";

const CATEGORY_OPTIONS: Array<{
  value: SupportCategory;
  label: string;
}> = [
  {
    value: "account_access",
    label: "Account e accesso",
  },
  {
    value: "league_invite",
    label: "Leghe, inviti e codici",
  },
  {
    value: "predictions",
    label: "Pronostici",
  },
  {
    value: "scores_rankings",
    label: "Punteggi e classifiche",
  },
  {
    value: "public_leagues",
    label: "Leghe pubbliche",
  },
  {
    value: "premium_pass",
    label: "Premium Pass e Control Room",
  },
  {
    value: "app_website",
    label: "Problema tecnico app o sito",
  },
  {
    value: "other",
    label: "Altro",
  },
];

const FAQ_ITEMS = [
  {
    title: "Non riesco ad accedere al mio account",
    content:
      "Controlla che l’indirizzo email sia corretto e prova nuovamente la password. Se non la ricordi, utilizza la procedura di recupero dalla pagina di accesso. Verifica inoltre che il browser non stia bloccando cookie o finestre necessarie all’autenticazione.",
  },
  {
    title: "Non ho ricevuto l’email di conferma o recupero",
    content:
      "Controlla le cartelle Spam, Promozioni e Posta indesiderata. Attendi qualche minuto prima di richiedere una nuova email. Assicurati che la casella non sia piena e che l’indirizzo inserito non contenga errori.",
  },
  {
    title: "Il link o il codice di invito non funziona",
    content:
      "Verifica di aver copiato il link completo oppure soltanto il codice, senza spazi aggiuntivi. Potresti essere già membro della lega oppure le iscrizioni potrebbero essere state chiuse dall’amministratore.",
  },
  {
    title: "Non riesco a entrare in una lega pubblica",
    content:
      "La lega potrebbe essere piena, chiusa o non più disponibile per la giornata corrente. Aggiorna il catalogo delle leghe pubbliche e controlla lo stato mostrato sulla relativa scheda.",
  },
  {
    title: "Non posso modificare i pronostici",
    content:
      "I pronostici possono essere modificati soltanto prima del blocco previsto per la giornata. Dopo il lock non possono più essere cambiati. Controlla anche di avere completato tutti i risultati richiesti.",
  },
  {
    title: "I pronostici sembrano non essere stati salvati",
    content:
      "Riapri la giornata e verifica i valori mostrati. Evita di chiudere la pagina durante un salvataggio in corso. Se il problema continua, allega uno screenshot indicando la lega e la giornata interessata.",
  },
  {
    title: "Punteggi o classifiche sembrano errati",
    content:
      "Durante le partite e subito dopo la loro conclusione i dati possono essere ancora provvisori. FantaGol pubblica i risultati definitivi dopo la certificazione delle partite e della giornata.",
  },
  {
    title: "Non vedo il mio Premium Pass",
    content:
      "Aggiorna la pagina e controlla nuovamente il saldo. Se il Pass deriva da un acquisto o da una ricompensa recente, indica nella segnalazione il momento dell’operazione e allega uno screenshot.",
  },
  {
    title: "Il sito o l’app mostrano una pagina bloccata",
    content:
      "Aggiorna la pagina, verifica la connessione e prova a chiudere e riaprire il browser o l’app. Se il problema rimane, indica esattamente la pagina coinvolta e allega uno screenshot.",
  },
  {
    title: "Come posso inviare una segnalazione utile?",
    content:
      "Scegli la categoria corretta, descrivi cosa stavi facendo, cosa ti aspettavi e cosa è successo. Quando possibile allega uno screenshot che non contenga password, codici di sicurezza o altri dati sensibili.",
  },
];

function createImageFromFile(file: File) {
  return new Promise<HTMLImageElement>((resolve, reject) => {
    const image = new Image();
    const objectUrl = URL.createObjectURL(file);

    image.onload = () => {
      URL.revokeObjectURL(objectUrl);
      resolve(image);
    };

    image.onerror = () => {
      URL.revokeObjectURL(objectUrl);
      reject(new Error("Impossibile leggere lo screenshot."));
    };

    image.src = objectUrl;
  });
}

function canvasToWebpBlob(
  canvas: HTMLCanvasElement,
  quality: number,
) {
  return new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        if (!blob) {
          reject(
            new Error("Impossibile ottimizzare lo screenshot."),
          );
          return;
        }

        resolve(blob);
      },
      "image/webp",
      quality,
    );
  });
}

async function optimizeScreenshot(file: File) {
  const image = await createImageFromFile(file);

  const longestSide = Math.max(
    image.naturalWidth,
    image.naturalHeight,
  );

  const scale =
    longestSide > MAX_SCREENSHOT_DIMENSION
      ? MAX_SCREENSHOT_DIMENSION / longestSide
      : 1;

  const width = Math.max(
    1,
    Math.round(image.naturalWidth * scale),
  );

  const height = Math.max(
    1,
    Math.round(image.naturalHeight * scale),
  );

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;

  const context = canvas.getContext("2d");

  if (!context) {
    throw new Error("Impossibile preparare lo screenshot.");
  }

  context.drawImage(image, 0, 0, width, height);

  let quality = SCREENSHOT_WEBP_QUALITY;
  let blob = await canvasToWebpBlob(canvas, quality);

  while (
    blob.size > MAX_OPTIMIZED_SCREENSHOT_SIZE &&
    quality > 0.5
  ) {
    quality = Math.max(0.5, quality - 0.08);
    blob = await canvasToWebpBlob(canvas, quality);
  }

  if (blob.size > MAX_OPTIMIZED_SCREENSHOT_SIZE) {
    throw new Error(
      "Non è stato possibile ridurre lo screenshot sotto 1 MB.",
    );
  }

  return new File(
    [blob],
    `screenshot-${Date.now()}.webp`,
    {
      type: "image/webp",
      lastModified: Date.now(),
    },
  );
}

function getErrorMessage(error: unknown) {
  if (error instanceof Error) {
    return error.message;
  }

  return "Impossibile inviare la segnalazione.";
}

export default function SupportoPage() {
  const [authResolved, setAuthResolved] = useState(false);
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [userId, setUserId] = useState("");
  const [userEmail, setUserEmail] = useState("");
  const [league, setLeague] = useState<DrawerLeague | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);

  const [category, setCategory] =
    useState<SupportCategory>("app_website");
  const [subject, setSubject] = useState("");
  const [description, setDescription] = useState("");

  const [screenshot, setScreenshot] = useState<File | null>(null);
  const [screenshotPreview, setScreenshotPreview] =
    useState<string | null>(null);
  const screenshotPreviewRef = useRef<string | null>(null);
  const screenshotInputRef = useRef<HTMLInputElement | null>(null);

  const [submitting, setSubmitting] = useState(false);
  const [successRequestId, setSuccessRequestId] = useState("");
  const [errorMessage, setErrorMessage] = useState("");

  useEffect(() => {
    let active = true;

    async function loadPageContext() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!active) return;

      if (!session?.user) {
        setAuthResolved(true);
        setIsAuthenticated(false);
        return;
      }

      setIsAuthenticated(true);
      setUserId(session.user.id);
      setUserEmail(session.user.email || "");

      const { data, error } = await supabase.rpc("get_my_leagues_rpc");

      if (!active) return;

      if (!error) {
        const rows = ((data || []) as MyLeagueRpcRow[]).filter(
          (row) => row.status === "active" || !row.status,
        );

        const storedLeagueId = window.localStorage.getItem(
          LAST_LEAGUE_STORAGE_KEY,
        );

        const current =
          rows.find((row) => row.league_id === storedLeagueId) || rows[0];

        if (current) {
          window.localStorage.setItem(
            LAST_LEAGUE_STORAGE_KEY,
            current.league_id,
          );

          setLeague({
            id: current.league_id,
            name: current.league_name || "Lega FantaGol",
            inviteCode:
              current.invite_code || current.league_id || "",
            displayName:
              current.display_name || "Giocatore",
            role: current.role || "member",
          });
        }
      }

      setAuthResolved(true);
    }

    void loadPageContext();

    return () => {
      active = false;

      if (screenshotPreviewRef.current) {
        URL.revokeObjectURL(screenshotPreviewRef.current);
      }
    };
  }, []);

  function clearScreenshot() {
    if (screenshotPreviewRef.current) {
      URL.revokeObjectURL(screenshotPreviewRef.current);
      screenshotPreviewRef.current = null;
    }

    setScreenshot(null);
    setScreenshotPreview(null);

    if (screenshotInputRef.current) {
      screenshotInputRef.current.value = "";
    }
  }

  async function handleScreenshotChange(
    event: ChangeEvent<HTMLInputElement>,
  ) {
    setErrorMessage("");
    setSuccessRequestId("");

    const input = event.target;
    const file = input.files?.[0];

    if (!file) {
      clearScreenshot();
      return;
    }

    const allowedTypes = [
      "image/jpeg",
      "image/png",
      "image/webp",
    ];

    if (!allowedTypes.includes(file.type)) {
      setErrorMessage(
        "Lo screenshot deve essere in formato JPG, PNG o WebP.",
      );
      input.value = "";
      return;
    }

    if (file.size > MAX_ORIGINAL_SCREENSHOT_SIZE) {
      setErrorMessage(
        "L’immagine originale non può superare 10 MB.",
      );
      input.value = "";
      return;
    }

    try {
      const optimizedFile = await optimizeScreenshot(file);

      if (screenshotPreviewRef.current) {
        URL.revokeObjectURL(
          screenshotPreviewRef.current,
        );
      }

      const previewUrl = URL.createObjectURL(optimizedFile);
      screenshotPreviewRef.current = previewUrl;

      setScreenshot(optimizedFile);
      setScreenshotPreview(previewUrl);
    } catch (error: unknown) {
      clearScreenshot();
      setErrorMessage(getErrorMessage(error));
    }
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (submitting || !userId) return;

    setErrorMessage("");
    setSuccessRequestId("");

    const cleanSubject = subject.trim();
    const cleanDescription = description.trim();

    if (cleanSubject.length < 3) {
      setErrorMessage(
        "Inserisci un oggetto di almeno 3 caratteri.",
      );
      return;
    }

    if (cleanDescription.length < 10) {
      setErrorMessage(
        "Descrivi il problema utilizzando almeno 10 caratteri.",
      );
      return;
    }

    setSubmitting(true);

    const requestId = crypto.randomUUID();
    let uploadedPath: string | null = null;

    try {
      if (screenshot) {
        uploadedPath =
          `${userId}/${requestId}/screenshot.webp`;

        const { error: uploadError } = await supabase.storage
          .from("support-screenshots")
          .upload(uploadedPath, screenshot, {
            cacheControl: "3600",
            contentType: screenshot.type,
            upsert: false,
          });

        if (uploadError) {
          throw uploadError;
        }
      }

      const { error: insertError } = await supabase
        .from("support_requests")
        .insert({
          id: requestId,
          user_id: userId,
          league_id: league?.id || null,
          category,
          subject: cleanSubject,
          description: cleanDescription,
          screenshot_path: uploadedPath,
          source_page: window.location.href.slice(0, 1000),
          user_agent: navigator.userAgent.slice(0, 1000),
          locale: navigator.language.slice(0, 40),
          status: "new",
        });

      if (insertError) {
        throw insertError;
      }

      setSuccessRequestId(requestId);
      setSubject("");
      setDescription("");
      setCategory("app_website");
      clearScreenshot();
    } catch (error: unknown) {
      if (uploadedPath) {
        await supabase.storage
          .from("support-screenshots")
          .remove([uploadedPath]);
      }

      setErrorMessage(getErrorMessage(error));
    } finally {
      setSubmitting(false);
    }
  }

  const authenticatedHeader =
    isAuthenticated && league ? (
      <>
        <HamburgerDrawer
          open={menuOpen}
          leagueName={league.name}
          displayName={league.displayName}
          inviteCode={league.inviteCode}
          role={league.role}
          onClose={() => setMenuOpen(false)}
        />

        <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
          <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
            <a
              href={`/leghe/${league.id}`}
              className="relative z-10 block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6"
            >
              <FantaGolLogo />
            </a>

            <button
              type="button"
              onClick={() => setMenuOpen(true)}
              aria-label="Apri menu lega"
              className="rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
            >
              ☰
            </button>
          </div>
        </header>
      </>
    ) : null;

  return (
    <main className="min-h-screen bg-black text-white">
      {authResolved && !isAuthenticated && <Header />}
      {authenticatedHeader}

      <div
        className={`mx-auto max-w-5xl px-5 pb-20 ${
          authResolved ? "pt-24" : "pt-10"
        }`}
      >
        <section className="rounded-3xl border border-white/10 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-6 shadow-2xl shadow-black/70 md:p-10">
          <p className="text-sm font-black uppercase tracking-[0.25em] text-[#A6E824]">
            Supporto FantaGol
          </p>

          <h1 className="mt-4 text-4xl font-black md:text-5xl">
            Come possiamo aiutarti?
          </h1>

          <p className="mt-4 max-w-3xl text-base leading-7 text-gray-400">
            Consulta le soluzioni ai problemi più comuni. Se non trovi
            la risposta, inviaci una segnalazione dettagliata e allega
            uno screenshot.
          </p>
        </section>

        <section className="mt-10">
          <div>
            <p className="text-sm font-black uppercase tracking-[0.2em] text-[#A6E824]">
              Risoluzione problemi
            </p>

            <h2 className="mt-2 text-3xl font-black">
              Problemi frequenti
            </h2>
          </div>

          <div className="mt-6 space-y-3">
            {FAQ_ITEMS.map((item) => (
              <details
                key={item.title}
                className="group rounded-2xl border border-white/10 bg-[#111417] open:border-[#A6E824]/40"
              >
                <summary className="flex cursor-pointer list-none items-center justify-between gap-4 px-5 py-5 font-black text-white">
                  <span>{item.title}</span>

                  <span className="shrink-0 text-xl text-[#A6E824] transition group-open:rotate-45">
                    +
                  </span>
                </summary>

                <div className="border-t border-white/10 px-5 py-5 text-sm leading-7 text-gray-300">
                  {item.content}
                </div>
              </details>
            ))}
          </div>
        </section>

        <section
          id="contattaci"
          className="mt-12 rounded-3xl border border-white/10 bg-[#111417] p-6 shadow-2xl shadow-black/60 md:p-8"
        >
          <p className="text-sm font-black uppercase tracking-[0.2em] text-[#A6E824]">
            Contattaci
          </p>

          <h2 className="mt-2 text-3xl font-black">
            Invia una segnalazione o un suggerimento
          </h2>

          <p className="mt-3 text-sm leading-6 text-gray-400">
            Non inserire password, codici di sicurezza, dati bancari o
            altre informazioni sensibili nello screenshot o nella
            descrizione.
          </p>

          {!authResolved && (
            <div className="mt-8 flex items-center gap-3 rounded-2xl border border-white/10 bg-black/30 px-5 py-4">
              <div className="h-6 w-6 animate-spin rounded-full border-2 border-white/15 border-t-[#A6E824]" />
              <span className="text-sm font-bold text-gray-300">
                Verifica della sessione...
              </span>
            </div>
          )}

          {authResolved && !isAuthenticated && (
            <div className="mt-8 rounded-2xl border border-[#A6E824]/30 bg-[#A6E824]/10 p-5">
              <h3 className="text-xl font-black">
                Accedi per inviare una segnalazione
              </h3>

              <p className="mt-2 text-sm leading-6 text-gray-300">
                Le guide restano disponibili a tutti. Per allegare uno
                screenshot e inviare una richiesta è necessario accedere
                al proprio account.
              </p>

              <a
                href="/login?returnTo=%2Fsupporto%23contattaci"
                className="mt-5 inline-flex rounded-xl bg-[#A6E824] px-5 py-3 text-sm font-black text-black transition hover:brightness-110"
              >
                Accedi a FantaGol
              </a>
            </div>
          )}

          {authResolved && isAuthenticated && (
            <form
              onSubmit={handleSubmit}
              className="mt-8 space-y-6"
            >
              <div className="grid gap-6 md:grid-cols-2">
                <label className="block">
                  <span className="text-sm font-bold text-gray-300">
                    Categoria
                  </span>

                  <select
                    value={category}
                    onChange={(event) =>
                      setCategory(
                        event.target.value as SupportCategory,
                      )
                    }
                    className="mt-2 w-full rounded-xl border border-gray-700 bg-black px-4 py-3 text-white outline-none transition focus:border-[#A6E824]"
                  >
                    {CATEGORY_OPTIONS.map((option) => (
                      <option
                        key={option.value}
                        value={option.value}
                      >
                        {option.label}
                      </option>
                    ))}
                  </select>
                </label>

                <label className="block">
                  <span className="text-sm font-bold text-gray-300">
                    Email account
                  </span>

                  <input
                    type="email"
                    value={userEmail}
                    readOnly
                    className="mt-2 w-full rounded-xl border border-gray-800 bg-black/50 px-4 py-3 text-gray-400 outline-none"
                  />
                </label>
              </div>

              {league && (
                <div className="rounded-xl border border-white/10 bg-black/30 px-4 py-3 text-sm text-gray-400">
                  Lega associata automaticamente:{" "}
                  <strong className="text-white">
                    {league.name}
                  </strong>
                </div>
              )}

              <label className="block">
                <span className="text-sm font-bold text-gray-300">
                  Oggetto
                </span>

                <input
                  type="text"
                  required
                  minLength={3}
                  maxLength={120}
                  value={subject}
                  onChange={(event) => {
                    setSubject(event.target.value);
                    setErrorMessage("");
                    setSuccessRequestId("");
                  }}
                  placeholder="Descrivi brevemente il problema"
                  className="mt-2 w-full rounded-xl border border-gray-700 bg-black px-4 py-3 text-white outline-none transition placeholder:text-gray-600 focus:border-[#A6E824]"
                />

                <span className="mt-2 block text-right text-xs text-gray-500">
                  {subject.length}/120
                </span>
              </label>

              <label className="block">
                <span className="text-sm font-bold text-gray-300">
                  Descrizione
                </span>

                <textarea
                  required
                  minLength={10}
                  maxLength={4000}
                  rows={8}
                  value={description}
                  onChange={(event) => {
                    setDescription(event.target.value);
                    setErrorMessage("");
                    setSuccessRequestId("");
                  }}
                  placeholder="Spiega cosa stavi facendo, cosa ti aspettavi e cosa è successo."
                  className="mt-2 w-full resize-y rounded-xl border border-gray-700 bg-black px-4 py-3 text-white outline-none transition placeholder:text-gray-600 focus:border-[#A6E824]"
                />

                <span className="mt-2 block text-right text-xs text-gray-500">
                  {description.length}/4000
                </span>
              </label>

              <div>
                <span className="text-sm font-bold text-gray-300">
                  Screenshot facoltativo
                </span>

                {!screenshotPreview ? (
                  <label className="mt-2 flex cursor-pointer flex-col items-center justify-center rounded-2xl border border-dashed border-gray-600 bg-black/40 px-5 py-8 text-center transition hover:border-[#A6E824]">
                    <span className="text-3xl text-[#A6E824]">＋</span>

                    <span className="mt-2 font-black text-white">
                      Allega uno screenshot
                    </span>

                    <span className="mt-2 text-xs leading-5 text-gray-500">
                      JPG, PNG o WebP — ottimizzazione automatica
                    </span>

                    <input
                      ref={screenshotInputRef}
                      type="file"
                      accept="image/jpeg,image/png,image/webp"
                      onChange={handleScreenshotChange}
                      className="hidden"
                    />
                  </label>
                ) : (
                  <div className="mt-2 overflow-hidden rounded-2xl border border-white/10 bg-black/40">
                    <div className="flex max-h-[420px] items-center justify-center bg-black p-3">
                      <img
                        src={screenshotPreview}
                        alt="Anteprima screenshot"
                        className="max-h-[390px] max-w-full rounded-xl object-contain"
                      />
                    </div>

                    <div className="flex flex-col gap-3 border-t border-white/10 p-4 sm:flex-row sm:items-center sm:justify-between">
                      <div className="min-w-0">
                        <p className="truncate text-sm font-black text-white">
                          {screenshot?.name}
                        </p>

                        <p className="mt-1 text-xs text-gray-500">
                          {screenshot
                            ? `${(screenshot.size / 1024 / 1024).toFixed(2)} MB`
                            : ""}
                        </p>
                      </div>

                      <button
                        type="button"
                        onClick={clearScreenshot}
                        className="rounded-xl border border-red-500/40 px-4 py-2 text-sm font-black text-red-300 transition hover:bg-red-500/10"
                      >
                        Rimuovi
                      </button>
                    </div>
                  </div>
                )}
              </div>

              {errorMessage && (
                <div
                  role="alert"
                  className="rounded-xl border border-red-500/40 bg-red-500/10 px-4 py-3 text-sm leading-6 text-red-200"
                >
                  {errorMessage}
                </div>
              )}

              {successRequestId && (
                <div
                  role="status"
                  className="rounded-xl border border-[#A6E824]/40 bg-[#A6E824]/10 px-4 py-4 text-sm leading-6 text-[#D8FF86]"
                >
                  <strong className="block text-white">
                    Segnalazione inviata correttamente.
                  </strong>

                  <span className="mt-1 block">
                    Codice richiesta: {successRequestId}
                  </span>
                </div>
              )}

              <button
                type="submit"
                disabled={submitting}
                className="w-full rounded-xl bg-[#A6E824] px-5 py-4 font-black text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
              >
                {submitting
                  ? "Invio in corso..."
                  : "Invia segnalazione"}
              </button>
            </form>
          )}
        </section>
      </div>
    </main>
  );
}