type LeagueTopBarProps = {
  leagueName: string;
  seasonName?: string;
  onMenuClick: () => void;
};

export default function LeagueTopBar({
  leagueName,
  seasonName = "Serie A 2026/27",
  onMenuClick,
}: LeagueTopBarProps) {
  return (
    <header className="sticky top-0 z-50 border-b border-[#A6E824]/20 bg-[#101315]/95 backdrop-blur">
      <div className="mx-auto flex h-16 max-w-5xl items-center justify-between px-4">
        <button
          type="button"
          onClick={onMenuClick}
          className="rounded-xl border border-gray-700 bg-[#1b2023] px-3 py-2 text-xl"
        >
          ☰
        </button>

        <div className="text-center">
          <div className="text-lg font-black text-[#A6E824]">
            🏆 {leagueName}
          </div>
          <div className="text-xs text-gray-400">{seasonName}</div>
        </div>

        <button
          type="button"
          className="rounded-xl border border-gray-700 bg-[#1b2023] px-3 py-2"
        >
          🔔
        </button>
      </div>
    </header>
  );
}