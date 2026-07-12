"use client";

type SubmissionModalProps = {
  open: boolean;
  title: string;
  description: string;
  primaryLabel?: string;
  secondaryLabel?: string;
  onPrimary?: () => void;
  onSecondary?: () => void;
  onClose: () => void;
};

export default function SubmissionModal({
  open,
  title,
  description,
  primaryLabel,
  secondaryLabel,
  onPrimary,
  onSecondary,
  onClose,
}: SubmissionModalProps) {
  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-[120] flex items-center justify-center bg-black/75 px-4 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-labelledby="submission-modal-title"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div className="w-full max-w-md rounded-[2rem] border border-[#A6E824]/30 bg-[#0b1419] p-5 shadow-[0_24px_90px_rgba(0,0,0,0.75)] sm:p-6">
        <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full border border-[#A6E824]/40 bg-[#A6E824]/15 text-2xl text-[#A6E824]">
          ✓
        </div>

        <h2
          id="submission-modal-title"
          className="mt-4 text-center text-xl font-black uppercase text-white sm:text-2xl"
        >
          {title}
        </h2>

        <p className="mx-auto mt-3 max-w-sm whitespace-pre-line text-center text-sm font-semibold leading-6 text-gray-300">
          {description}
        </p>

        <div className="mt-6 space-y-2">
          {primaryLabel && onPrimary && (
            <button
              type="button"
              onClick={onPrimary}
              className="w-full rounded-2xl bg-[#A6E824] px-4 py-3 text-sm font-black uppercase text-[#071015] transition hover:brightness-110"
            >
              {primaryLabel}
            </button>
          )}

          {secondaryLabel && onSecondary && (
            <button
              type="button"
              onClick={onSecondary}
              className="w-full rounded-2xl border border-white/15 bg-white/[0.04] px-4 py-3 text-sm font-black uppercase text-white transition hover:border-[#A6E824]/50 hover:bg-white/[0.07]"
            >
              {secondaryLabel}
            </button>
          )}

          <button
            type="button"
            onClick={onClose}
            className="w-full px-4 py-2 text-xs font-black uppercase tracking-[0.14em] text-gray-500 transition hover:text-white"
          >
            Chiudi
          </button>
        </div>
      </div>
    </div>
  );
}
