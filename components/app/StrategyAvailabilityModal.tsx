"use client";

type StrategyAvailabilityModalProps = {
  open: boolean;
  onClose: () => void;
};

export default function StrategyAvailabilityModal({
  open,
  onClose,
}: StrategyAvailabilityModalProps) {
  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-[120] flex items-center justify-center bg-black/75 px-4 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-labelledby="strategy-availability-title"
      onClick={onClose}
    >
      <div
        className="w-full max-w-md rounded-3xl border border-[#A6E824]/35 bg-[#111417] p-6 shadow-2xl shadow-black/80 sm:p-8"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full border border-[#A6E824]/40 bg-[#A6E824]/10 text-2xl">
          ⏳
        </div>

        <h2
          id="strategy-availability-title"
          className="mt-5 text-center text-2xl font-black text-white"
        >
          Strategia non ancora disponibile
        </h2>

        <p className="mt-4 text-center text-sm font-semibold leading-6 text-gray-300">
          Potrai comporre e inviare la strategia dopo la chiusura delle
          iscrizioni, quando saranno definiti calendario, avversario ed
          eventuale turno di riposo.
        </p>

        <button
          type="button"
          onClick={onClose}
          className="mt-7 w-full rounded-2xl bg-[#A6E824] px-5 py-4 text-sm font-black uppercase text-black transition hover:brightness-110"
        >
          Ho capito
        </button>
      </div>
    </div>
  );
}