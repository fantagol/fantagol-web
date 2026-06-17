import FantaGolLogo from "./FantaGolLogo";

export default function Header() {
  return (
    <header className="border-b border-gray-800">
      <div className="max-w-6xl mx-auto px-6 h-24 flex items-center justify-between overflow-visible">
        <a
          href="/"
          aria-label="Vai alla home FantaGol"
          className="block translate-y-6 md:-translate-x-24"
        >
          <FantaGolLogo />
        </a>

        <nav className="hidden md:flex gap-8 text-gray-300">
          <a href="/#funziona">Come Funziona</a>
          <a href="/#modalita">Modalità</a>
          <a href="/#perche">Perché FantaGol</a>
          <a href="/regolamento">Regolamento</a>
          <a href="/play">Play Online</a>
          <a href="/download">Download</a>
        </nav>
      </div>
    </header>
  );
}