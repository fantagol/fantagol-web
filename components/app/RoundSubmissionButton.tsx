"use client";

type RoundSubmissionButtonProps = {
  locked: boolean;
  isViewingSelf: boolean;
  hasOfficialSubmission: boolean;
  hasUnconfirmedChanges: boolean;
  submitting?: boolean;
  disabled?: boolean;
  onClick: () => void;
};

export default function RoundSubmissionButton({
  locked,
  isViewingSelf,
  hasOfficialSubmission,
  hasUnconfirmedChanges,
  submitting = false,
  disabled = false,
  onClick,
}: RoundSubmissionButtonProps) {
  const isConfirmed = hasOfficialSubmission && !hasUnconfirmedChanges;
  const isDisabled =
    disabled ||
    locked ||
    submitting ||
    !isViewingSelf ||
    isConfirmed;

  return (
    <button
      type="button"
      onClick={onClick}
      disabled={isDisabled}
      className={`w-full max-w-2xl rounded-2xl px-6 py-4 text-base font-black uppercase text-white shadow-lg transition sm:py-5 sm:text-lg ${
        isDisabled
          ? "cursor-not-allowed bg-gray-700 text-gray-300 shadow-black/20"
          : "bg-[#8cc91e] shadow-[#A6E824]/20 hover:brightness-110"
      }`}
    >
      {!isViewingSelf ? (
        "Pronostici visibili dal live"
      ) : locked ? (
        "🔒 Pronostici bloccati"
      ) : submitting ? (
        "Invio in corso..."
      ) : hasOfficialSubmission && hasUnconfirmedChanges ? (
        <span className="flex flex-col items-center">
          <span>✎ Reinvia i pronostici</span>
          <span className="mt-1 text-[10px] font-bold normal-case opacity-80 sm:text-xs">
            Hai modifiche non confermate
          </span>
        </span>
      ) : hasOfficialSubmission ? (
        "✓ Pronostici inviati"
      ) : (
        "✈ Invia i pronostici"
      )}
    </button>
  );
}
