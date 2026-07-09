type BottomNavProps = {
  onMenuClick: () => void;
};

export default function BottomNav({ onMenuClick }: BottomNavProps) {
  return (
    <nav className="fixed bottom-0 left-0 right-0 z-50 border-t border-gray-800 bg-[#111417] px-4 py-3">
      <div className="mx-auto flex max-w-5xl justify-around text-xs text-gray-300">
        <span>🏠<br />Home</span>
        <span>⚽<br />Live</span>
        <span>🏆<br />Classifiche</span>
        <span>📅<br />Calendario</span>
        <button type="button" onClick={onMenuClick}>
          ☰<br />Menu
        </button>
      </div>
    </nav>
  );
}
